// The drawing for foreman's "show": the pictures some commands print on a terminal, made of
// block characters in foreman's palette. foreman-ui.sh decides whether to show one and at what
// colour tier and width; this file draws it.
//
//   node foreman-draw.cjs SCENE --tier 16|256|24 --cols N     facts on stdin, the picture on stdout
//   const { draw } = require('./foreman-draw.cjs');           draw(scene, facts, { tier, cols })
//
// Exit status: 0 drawn, 2 bad arguments or an unknown scene, 3 the width is below the scene's
// minimum (nothing is printed — the caller prints its plain text). The facts are lines of
// `key<TAB>value`, which a shell can write without escaping; a key that repeats is a list.
//
// A scene is a function from facts to ROWS. A row is a list of RUNS, `{ t, style }`: the text and
// how it is painted, where a style is `{ fg, bg, bold }` and a colour is a palette name (`sun`)
// or a hex (`#0a0908`) for a shade the art works out itself. One encoder turns rows into SGR at
// the tier: 24 bits as 38;2;r;g;b, 256 colours as 38;5;n, and at 16 the colour folded onto the
// nearest palette name's 16-colour code.
//
// THE PALETTE is not written here. It is read from the `_UI_PALETTE` table in foreman-ui.sh,
// which is where the shell paints from, so the two cannot drift.

'use strict';

const fs = require('fs');
const path = require('path');

const ESC = '\x1b';

// --- the palette ---------------------------------------------------------------------------

// Reads the table out of foreman-ui.sh: one `name hex idx code` row per colour between
// `_UI_PALETTE='` and the closing quote. `idx` is `-` for a colour with no 256 shade (null here).
function loadPalette(file = path.join(__dirname, 'foreman-ui.sh')) {
  const text = fs.readFileSync(file, 'utf8');
  const table = /^_UI_PALETTE='\r?\n([\s\S]*?)^'/m.exec(text);
  if (!table) throw new Error(`no _UI_PALETTE in ${file}`);
  const palette = {};
  for (const line of table[1].split(/\r?\n/)) {
    if (!line.trim()) continue;
    const [name, hex, idx, code] = line.trim().split(/\s+/);
    if (!/^#[0-9a-f]{6}$/.test(hex || '') || !/^(\d+|-)$/.test(idx || '') || !/^\d+$/.test(code || '')) {
      throw new Error(`bad _UI_PALETTE row in ${file}: ${line.trim()}`);
    }
    palette[name] = {
      hex,
      rgb: [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16)),
      x256: idx === '-' ? null : Number(idx),
      sgr16: Number(code),
    };
  }
  return palette;
}

let defaultPalette = null;
const thePalette = () => (defaultPalette = defaultPalette || loadPalette());

const hexRgb = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
const sqDist = (a, b) => (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2;

// A colour as { rgb, x256, sgr16 }: a palette name as the table has it, or a hex worked out here.
function resolve(colour, palette) {
  if (palette[colour]) return { name: colour, ...palette[colour] };
  if (!/^#[0-9a-f]{6}$/.test(colour)) throw new Error(`unknown colour '${colour}'`);
  const rgb = hexRgb(colour);
  return { name: nearestName(rgb, palette), rgb, x256: nearest256(rgb), sgr16: null };
}

// The xterm-256 colour nearest to rgb: the 6x6x6 cube and the 24 greys, by squared distance.
function nearest256(rgb) {
  const level = [0, 95, 135, 175, 215, 255];
  let best = 16;
  let bestDist = Infinity;
  for (let i = 16; i < 256; i++) {
    const c = i < 232
      ? [level[Math.floor((i - 16) / 36)], level[Math.floor((i - 16) / 6) % 6], level[(i - 16) % 6]]
      : Array(3).fill(8 + 10 * (i - 232));
    const d = sqDist(rgb, c);
    if (d < bestDist) { bestDist = d; best = i; }
  }
  return best;
}

// The palette name nearest to rgb: how a shade the art works out folds onto 16 colours.
function nearestName(rgb, palette) {
  let best = null;
  let bestDist = Infinity;
  for (const [name, c] of Object.entries(palette)) {
    const d = sqDist(rgb, c.rgb);
    if (d < bestDist) { bestDist = d; best = name; }
  }
  return best;
}

// --- the encoder ---------------------------------------------------------------------------

// The SGR parameters for a style at a tier, in the order 0 (reset), bold, foreground, background.
// At 16 a colour is its nearest name's code; `2` (dim) is an attribute, so it can be written as
// a foreground but there is no such thing as a dim background, and `0` (the terminal's own text
// colour) is no code at all. At 256 a colour with no shade (text) is the terminal's own too.
function sgr(style, tier, palette) {
  const codes = [];
  if (style.bold) codes.push('1');
  for (const [which, base] of [['fg', 38], ['bg', 48]]) {
    if (!style[which]) continue;
    const c = resolve(style[which], palette);
    if (tier === 24) {
      codes.push(`${base};2;${c.rgb.join(';')}`);
    } else if (tier === 256) {
      if (c.x256 !== null) codes.push(`${base};5;${c.x256}`);
    } else {
      const code = palette[c.name].sgr16;
      if (code >= 30 && code <= 37) codes.push(String(which === 'fg' ? code : code + 10));
      else if (code === 2 && which === 'fg') codes.push('2');
    }
  }
  return codes.join(';');
}

// Rows of runs to text at a tier: a line each, and every line ends by dropping whatever style is
// still on, so a drawing can be followed by anything.
function encode(rows, tier, palette = thePalette()) {
  let out = '';
  for (const row of rows) {
    let open = false;
    for (const run of row) {
      if (run.style) {
        const codes = sgr(run.style, tier, palette);
        out += `${ESC}[0${codes ? ';' + codes : ''}m${run.t}`;
        open = true;
      } else {
        if (open) out += `${ESC}[0m`;
        out += run.t;
        open = false;
      }
    }
    out += `${ESC}[0m\n`;
  }
  return out;
}

// --- block art -----------------------------------------------------------------------------

// A grid of pixels (a colour, or null for none), two to a character cell: the upper half is the
// foreground of a `▀` and the lower the background, which is how a half-block cell holds two
// differently coloured pixels. Equal halves are a `█`, a lone half a `▀` or `▄`, none a space.
//
// At 16 colours there are only yellow, red and black to draw with; the palette's darker shades
// (the ground, the rim of a dome) fold to dim, and dim cannot be a block. They are the terminal's
// own background instead, which is what they were standing in for.
function halfBlocks(pixels, tier, palette = thePalette()) {
  const fold = (colour) => {
    if (colour === null || tier !== 16) return colour;
    const name = resolve(colour, palette).name;
    return palette[name].sgr16 === 2 ? null : name;
  };
  const rows = [];
  for (let y = 0; y < pixels.length; y += 2) {
    const runs = [];
    for (let x = 0; x < pixels[y].length; x++) {
      const top = fold(pixels[y][x]);
      const bottom = fold(pixels[y + 1] ? pixels[y + 1][x] : null);
      let t = ' ';
      let style = null;
      if (top !== null && top === bottom) { t = '█'; style = { fg: top }; }
      else if (top === null && bottom !== null) { t = '▄'; style = { fg: bottom }; }
      else if (top !== null && bottom === null) { t = '▀'; style = { fg: top }; }
      else if (top !== null) { t = '▀'; style = { fg: top, bg: bottom }; }
      const last = runs[runs.length - 1];
      if (last && JSON.stringify(last.style) === JSON.stringify(style)) last.t += t;
      else runs.push({ t, style });
    }
    // Blanks at the end of a row are not drawn: they only make it wrap in a narrow window.
    const end = runs[runs.length - 1];
    if (end && !end.style) { end.t = end.t.trimEnd(); if (!end.t) runs.pop(); }
    rows.push(runs);
  }
  return rows;
}

// --- the figure and the sun ---------------------------------------------------------------

// The foreman: a head and hard hat, a body, and his legs, as the canvas drew them (`#` is the
// silhouette), and the arm raised in a salute as a list of [column, row] cells.
const FIGURE_TOP = [
  '.......####.......',
  '......######......',
  '.....########.....',
  '..##############..',
  '......######......',
  '......######......',
  '.......####.......',
  '.......####.......',
  '.....########.....',
  '....##########....',
  '...###########....',
  '...###########....',
  '...###########....',
  '..##.#########....',
  '..##.#########....',
  '..##.#########....',
  '..##.#########....',
  '...#.#########....',
  '.....#########....',
];
const FIGURE_LEGS = ['.....####.####....', '.....####..####...', '.....###....###...', '.....###....###...', '.....###.....###..', '....####.....####.'];
const FIGURE_SALUTE = [[13, 4], [14, 4], [15, 4], [14, 5], [15, 5], [15, 6], [16, 6], [15, 7], [16, 7], [14, 8], [15, 8], [13, 9], [14, 9]];

// The silhouette's colour is darker than anything in the palette, and does not need to be: at 16
// colours it folds to ink, which is black.
const SILHOUETTE = '#0a0908';

// The sun at the horizon with the figure in front of it, as a grid of pixels. The grid is 64
// wide and 36 tall with the horizon on row 30; the sun has radius r around column cx and rises
// by s (0 is set, 1 is full), and the figure's left edge is column fx. Inside the sun's disc the
// colour goes from sun to amber to rust by distance from the centre, then a ring of earth and one
// of shade, and below the horizon the ground (night), with a stripe of post for the reflection.
function sunPixels({ r, cx, s = 1, fx }) {
  const w = 64, h = 36, horizon = 30;
  const cy = horizon + r * (1 - s);
  const pixels = Array.from({ length: h }, () => Array(w).fill(null));
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (y >= horizon) {
        const k = y - horizon;
        pixels[y][x] = s > 0.4 && k % 2 === 1 && Math.abs(x - cx) < r * s - k * 4 ? 'post' : 'night';
        continue;
      }
      const d = Math.hypot(x - cx, y - cy);
      if (d < r) pixels[y][x] = d / r < 0.55 ? 'sun' : d / r < 0.85 ? 'amber' : 'rust';
      else if (d < r + 2) pixels[y][x] = 'earth';
      else if (d < r + 3) pixels[y][x] = 'shade';
    }
  }
  const top = horizon - 25;
  FIGURE_TOP.concat(FIGURE_LEGS).forEach((row, j) => {
    Array.from(row).forEach((ch, i) => { if (ch === '#') pixels[top + j][fx + i] = SILHOUETTE; });
  });
  for (const [i, j] of FIGURE_SALUTE) pixels[top + j][fx + i] = SILHOUETTE;
  return pixels;
}

// --- the scenes ----------------------------------------------------------------------------

// Each scene has the width it needs (below it the caller prints plain text) and a function from
// facts and { tier, cols } to rows. The shell checks `min` against the terminal before it starts
// node, so the number is also in bin/foreman, and a smoke case holds the two together.
const SCENES = {
  // `foreman help`: the big sun with the whole figure inside it, over a blank line, then the help.
  help: {
    min: 64,
    rows: (facts, { tier }) => [...halfBlocks(sunPixels({ r: 28, cx: 32, fx: 21 }), tier), []],
  },
};

// --- the entry points ----------------------------------------------------------------------

// `key<TAB>value` lines to an object; a key that repeats is a list, in order. A line with no tab
// is a key with no value, and a blank line is nothing.
function parseFacts(text) {
  const facts = {};
  for (const line of String(text).split(/\r?\n/)) {
    if (!line) continue;
    const tab = line.indexOf('\t');
    const key = tab < 0 ? line : line.slice(0, tab);
    const value = tab < 0 ? '' : line.slice(tab + 1);
    if (!(key in facts)) facts[key] = value;
    else facts[key] = [].concat(facts[key], value);
  }
  return facts;
}

// The scene drawn at a tier (16, 256 or 24) and width, or '' when the width is below its minimum.
function draw(scene, facts, { tier, cols }) {
  const s = SCENES[scene];
  if (!s) throw new Error(`unknown scene '${scene}'`);
  if (cols < s.min) return '';
  return encode(s.rows(facts, { tier, cols }), tier);
}

function main(argv) {
  const usage = (msg) => { process.stderr.write(`foreman-draw: ${msg}\n`); return 2; };
  let scene = null, tier = null, cols = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--tier') tier = argv[++i];
    else if (argv[i] === '--cols') cols = argv[++i];
    else if (argv[i].startsWith('-') || scene !== null) return usage(`unexpected argument '${argv[i]}'`);
    else scene = argv[i];
  }
  if (scene === null) return usage('usage: foreman-draw.cjs SCENE --tier 16|256|24 --cols N');
  if (!Object.hasOwn(SCENES, scene)) return usage(`unknown scene '${scene}'`);
  if (!['16', '256', '24'].includes(tier)) return usage('--tier must be 16, 256 or 24');
  if (!/^[0-9]+$/.test(cols || '') || Number(cols) < 1) return usage('--cols must be a width in columns');

  // A terminal on stdin means no one piped facts in; reading it would wait for a person.
  let text = '';
  if (!process.stdin.isTTY) {
    try { text = fs.readFileSync(0, 'utf8'); } catch { /* closed or empty: no facts */ }
  }
  const out = draw(scene, parseFacts(text), { tier: Number(tier), cols: Number(cols) });
  if (!out) {
    process.stderr.write(`foreman-draw: ${cols} columns is too narrow for '${scene}' (needs ${SCENES[scene].min})\n`);
    return 3;
  }
  process.stdout.on('error', () => {});    // a reader that left early (| head) is not our error
  process.stdout.write(out);
  return 0;
}

module.exports = { loadPalette, encode, sgr, halfBlocks, parseFacts, draw, SCENES };

if (require.main === module) process.exitCode = main(process.argv.slice(2));
