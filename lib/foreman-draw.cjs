// The drawing for foreman's "show": the pictures some commands print on a terminal, made of
// block characters in foreman's palette. foreman-ui.sh decides whether to show one and at what
// colour tier and width; this file draws it.
//
//   node foreman-draw.cjs SCENE --tier 16|256|24 --cols N [--frame N]   facts on stdin, the picture on stdout
//   node foreman-draw.cjs SCENE --tier 16|256|24 --cols N --play [--step MS]   its frames, in place (70ms apart)
//   const { draw } = require('./foreman-draw.cjs');           draw(scene, facts, { tier, cols, frame })
//
// Exit status: 0 drawn, 2 bad arguments or an unknown scene, 3 the width is below the scene's
// minimum (nothing is printed — the caller prints its plain text), 4 `--play` with nowhere to play
// it (stdin or stdout is not a terminal, or the terminal is too short: also nothing printed). The
// facts are lines of `key<TAB>value`, which a shell can write without escaping; a key that repeats
// is a list.
//
// A scene with more than one FRAME is an animation: `--frame N` draws frame N alone, and `--play`
// draws them one over the last on a timer, with the cursor hidden, any key skipping to the last
// frame, and the terminal put back however it ends. The last frame is left on screen.
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
// still on, so a drawing can be followed by anything. With `erase` (a width in columns) a row
// shorter than that also clears the rest of its line, which is what drawing over a previous frame
// needs; a row as wide as the terminal does not, as the cursor is waiting to wrap there and a clear
// would take the last cell with it.
function encode(rows, tier, palette = thePalette(), { erase = 0 } = {}) {
  let out = '';
  for (const row of rows) {
    let open = false;
    let width = 0;
    for (const run of row) {
      width += Array.from(run.t).length;
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
    out += `${ESC}[0m${width < erase ? `${ESC}[K` : ''}\n`;
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
//
// `texts` are words written over the art, `{ x, y, t, bold }` with x and y in pixels: each letter
// takes a whole cell, in the silhouette's colour on whatever the cell held.
function halfBlocks(pixels, tier, palette = thePalette(), texts = []) {
  const fold = (colour) => {
    if (colour === null || tier !== 16) return colour;
    const name = resolve(colour, palette).name;
    return palette[name].sgr16 === 2 ? null : name;
  };
  const rows = [];
  for (let y = 0; y < pixels.length; y += 2) {
    const cells = [];
    for (let x = 0; x < pixels[y].length; x++) {
      const top = fold(pixels[y][x]);
      const bottom = fold(pixels[y + 1] ? pixels[y + 1][x] : null);
      let t = ' ';
      let style = null;
      if (top !== null && top === bottom) { t = '█'; style = { fg: top }; }
      else if (top === null && bottom !== null) { t = '▄'; style = { fg: bottom }; }
      else if (top !== null && bottom === null) { t = '▀'; style = { fg: top }; }
      else if (top !== null) { t = '▀'; style = { fg: top, bg: bottom }; }
      cells.push({ t, style });
    }
    for (const word of texts) {
      if (Math.floor(word.y / 2) !== y / 2) continue;
      Array.from(word.t).forEach((t, k) => {
        const x = word.x + k;
        if (x < 0 || x >= cells.length) return;
        const bg = fold(pixels[y][x] || (pixels[y + 1] && pixels[y + 1][x]) || null);
        const style = { fg: SILHOUETTE };
        if (bg !== null) style.bg = bg;
        if (word.bold) style.bold = true;
        cells[x] = { t, style };
      });
    }
    const runs = [];
    for (const cell of cells) {
      const last = runs[runs.length - 1];
      if (last && JSON.stringify(last.style) === JSON.stringify(cell.style)) last.t += cell.t;
      else runs.push({ t: cell.t, style: cell.style });
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
const ARMS = {
  salute: [[13, 4], [14, 4], [15, 4], [14, 5], [15, 5], [15, 6], [16, 6], [15, 7], [16, 7], [14, 8], [15, 8], [13, 9], [14, 9]],
  down: [[14, 9], [15, 9], [15, 10], [15, 11], [15, 12], [15, 13], [15, 14], [15, 15], [15, 16], [15, 17], [16, 11], [16, 12], [16, 13], [16, 14], [16, 15], [16, 16]],
  mid: [[14, 9], [15, 9], [15, 10], [16, 10], [16, 11], [16, 9], [16, 8], [15, 8], [15, 7], [14, 7]],
};

// The silhouette's colour is darker than anything in the palette, and does not need to be: at 16
// colours it folds to ink, which is black.
const SILHOUETTE = '#0a0908';

// The sky of the sunrise as a grid of pixels (a colour, or null for none): w wide and 36 tall with
// the horizon on row 30. The sun has radius r around column cx and rises by s (0 is set, 1 is
// full). Inside its disc the colour goes from sun to amber to rust by distance from the centre,
// then a ring of earth and one of shade, and below the horizon the ground (night), with a stripe of
// post for the reflection.
const HORIZON = 30;
function skyPixels({ w, r, cx, s = 1 }) {
  const h = 36;
  const cy = HORIZON + r * (1 - s);
  const pixels = Array.from({ length: h }, () => Array(w).fill(null));
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (y >= HORIZON) {
        const k = y - HORIZON;
        pixels[y][x] = s > 0.4 && k % 2 === 1 && Math.abs(x - cx) < r * s - k * 4 ? 'post' : 'night';
        continue;
      }
      const d = Math.hypot(x - cx, y - cy);
      if (d < r) pixels[y][x] = d / r < 0.55 ? 'sun' : d / r < 0.85 ? 'amber' : 'rust';
      else if (d < r + 2) pixels[y][x] = 'earth';
      else if (d < r + 3) pixels[y][x] = 'shade';
    }
  }
  return pixels;
}

// Puts a figure on a grid: its left edge at column fx, its feet on the horizon. `body` is a list of
// strings (`#` is silhouette) and `arms` a list of [column, row] cells, both relative to the
// figure; what falls outside the grid is not drawn.
function putFigure(pixels, fx, body, arms, colour = SILHOUETTE) {
  const top = HORIZON - 25;
  const dot = (i, j, value) => {
    const x = fx + i, y = top + j;
    if (y >= 0 && y < pixels.length && x >= 0 && x < pixels[y].length) pixels[y][x] = value;
  };
  body.forEach((row, j) => Array.from(row).forEach((ch, i) => { if (ch === '#') dot(i, j, colour); }));
  for (const [i, j] of arms) dot(i, j, colour);
  return dot;
}

// The sun at the horizon with the figure in front of it, saluting.
function sunPixels({ r, cx, s = 1, fx }) {
  const pixels = skyPixels({ w: 64, r, cx, s });
  putFigure(pixels, fx, FIGURE_TOP.concat(FIGURE_LEGS), ARMS.salute);
  return pixels;
}

// --- the intro -----------------------------------------------------------------------------

// Intro3: the sun comes up, the foreman walks in from the left, drives a stake into the ground
// with a hammer (three blows, the last one flush with the ground), turns to face the sun and
// shades his eyes. The last frame is the help's sunrise, so the help text goes on below it.
//
// Poses are drawn on the same 25-row sprite as the standing figure. The walk is side-on, facing
// right; the turn is two in-between steps.
const SIDE_TOP = [
  '.......####.......',
  '......######......',
  '......#######.....',
  '....###########...',
  '.......#####......',
  '.......######.....',
  '.......#####......',
  '........###.......',
  '.......#####......',
  '......#######.....',
  '......#######.....',
  '......#######.....',
  '......#######.....',
  '......#######.....',
  '......#######.....',
  '......#######.....',
  '......#######.....',
  '......#######.....',
  '......#######.....',
];
const SIDE_LEGS = {
  stride: ['......#######.....', '.....###...###....', '....###.....###...', '...###.......###..', '..###.........###.', '.####.........####'],
  half: ['......#######.....', '......###.###.....', '.....###...###....', '.....###....###...', '....###.....###...', '...####.....####..'],
  pass: ['......#######.....', '.......#####......', '.......#####......', '.......###.##.....', '.......###.##.....', '.......#####......'],
  stop: ['......#######.....', '.......##.###.....', '.......##.###.....', '.......##.###.....', '.......##.###.....', '.......#########..'],
};
const SIDE_ARMS = {
  stride: [[13, 10], [13, 11], [14, 11], [14, 12], [14, 13], [15, 13], [15, 14], [15, 15], [5, 10], [5, 11], [4, 11], [4, 12], [4, 13], [3, 13], [3, 14], [3, 15]],
  half: [[13, 11], [13, 12], [13, 13], [14, 14], [5, 11], [5, 12], [5, 13], [4, 14]],
  pass: [],
  stop: [],
};
// the turn, a quarter round and then three quarters, a row taller than the standing sprite
const QUARTER = [
  '.......####.......',
  '......######......',
  '......#######.....',
  '....############..',
  '.......######.....',
  '.......######.....',
  '.......#####......',
  '........####......',
  '......########....',
  '.....#########....',
  '.....########.....',
  '.....########.....',
  '.....########.....',
  '.....########.....',
  '.....########.....',
  '.....########.....',
  '.....########.....',
  '.....########.....',
  '.....########.....',
  '.....########.....',
  '......##..###.....',
  '......##..###.....',
  '......###..###....',
  '......###..###....',
  '.....####.#####...',
];
const THREE_Q = [
  '.......####.......',
  '......######......',
  '.....#######......',
  '...#############..',
  '......######......',
  '......######......',
  '.......####.......',
  '.......####.......',
  '.....#########....',
  '....###########...',
  '....##########....',
  '....##########....',
  '....##########....',
  '...#.#########....',
  '...#.#########....',
  '...#.#########....',
  '...#.#########....',
  '...#.#########....',
  '.....#########....',
  '.....#########....',
  '.....####.####....',
  '.....###...###....',
  '.....###....###...',
  '.....###....###...',
  '....####....####..',
];

// A thin line of cells from one point to another (thick doubles it sideways), and a filled block.
function line(x1, y1, x2, y2, thick) {
  const cells = [];
  const n = Math.max(Math.abs(x2 - x1), Math.abs(y2 - y1), 1);
  for (let k = 0; k <= n; k++) {
    const x = Math.round(x1 + (x2 - x1) * k / n), y = Math.round(y1 + (y2 - y1) * k / n);
    cells.push([x, y]);
    if (thick) cells.push([x + 1, y]);
  }
  return cells;
}
function block(x, y, w, h) {
  const cells = [];
  for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) cells.push([x + i, y + j]);
  return cells;
}
// Hammer poses, in sprite cells (row 25 is the ground); the stake stands at columns 15-16.
const HAMMER = {
  hold: () => line(10, 9, 12, 16, true).concat(line(13, 16, 13, 19), block(11, 19, 4, 2)),
  lift: () => line(10, 9, 14, 10, true).concat(line(15, 10, 15, 5), block(13, 3, 5, 2)),
  up: () => line(10, 9, 10, 2, true).concat(line(10, 2, 9, -2), block(7, -4, 5, 2)),
  back: () => line(10, 9, 8, 3, true).concat(line(8, 3, 5, 0), block(2, -2, 3, 4)),
  swing: () => line(10, 9, 15, 6, true).concat(line(16, 6, 19, 5), block(19, 3, 2, 5)),
  strike: (top) => line(10, 9, 13, 14, true).concat(line(14, 14, 15, top - 3), block(14, top - 2, 4, 2)),
  rebound: (top) => line(10, 9, 13, 13, true).concat(line(14, 13, 15, top - 7), block(14, top - 6, 4, 2)),
};
const STAKE_X = 15;
// Sparks at the moment of the hit, then the same sparks flung further out a frame later.
function sparks(top, big) {
  const near = [[12, top - 2], [19, top - 3], [18, top - 5]];
  return big ? near.concat([[11, top - 5], [21, top - 2], [16, top - 7], [20, top - 7], [13, top - 8], [22, top - 5]]) : near;
}
function sparksOut(top, big) {
  const far = [[10, top - 3], [21, top - 4], [20, top - 8]];
  return big ? far.concat([[8, top - 7], [24, top - 2], [17, top - 10], [23, top - 9], [12, top - 11]]) : far;
}

const INTRO_W = 66, INTRO_CX = 32, INTRO_R = 28, INTRO_FX = 21;
const SPARK = '#fff8e8';

// One picture of the intro as a grid and its words. `o` is { s: how far up the sun is, x: the
// figure's left edge, body, arms, stake: how high the stake stands, sparks, sound: { t, at, bold } }.
function introPixels(o) {
  const fx = o.x ?? INTRO_FX;
  const pixels = skyPixels({ w: INTRO_W, r: INTRO_R, cx: INTRO_CX, s: o.s ?? 1 });
  const dot = putFigure(pixels, fx, o.body || FIGURE_TOP.concat(FIGURE_LEGS), o.arms || []);
  // the stake stays put in the ground; it does not move with the walker
  if (o.stake) {
    for (let y = HORIZON - o.stake; y < HORIZON; y++) {
      pixels[y][INTRO_FX + STAKE_X] = SILHOUETTE;
      pixels[y][INTRO_FX + STAKE_X + 1] = SILHOUETTE;
    }
  }
  for (const [i, j] of o.sparks || []) dot(i, j, SPARK);
  const texts = o.sound ? [{ x: fx + o.sound.at[0], y: HORIZON - 25 + o.sound.at[1], t: o.sound.t, bold: o.sound.bold }] : [];
  return { pixels, texts };
}

const ease = (t) => 1 - Math.pow(1 - Math.min(1, t), 2);
const side = (phase, extra) => Object.assign({ body: SIDE_TOP.concat(SIDE_LEGS[phase]), arms: SIDE_ARMS[phase] }, extra);
const strike = (height, big, word) => side('stop', {
  arms: HAMMER.strike(25 - height),
  stake: height,
  sparks: sparks(25 - height, big),
  sound: { t: word, at: [big ? 20 : 19, 25 - height - (big ? 9 : 6)], bold: big },
});
const WALK = [-3, 0, 3, 6, 9, 12, 15, 18, 21];

// The thirty-six takes, each a label (what the design calls it) and what to draw.
const INTRO = [
  { label: 'first light', o: { s: 0.2, stake: 6 } },
  { label: 'the sun comes up', o: { s: 0.4, stake: 6 } },
  ...WALK.map((x, i) => ({
    label: i < 4 ? 'walks in' : 'walks into the light',
    o: side(['stride', 'half', 'pass', 'half'][i % 4], { x, s: 0.5 + 0.5 * ease((i + 1) / WALK.length), stake: 6 }),
  })),
  { label: 'stops at the stake', o: side('stop', { stake: 6 }) },
  { label: 'takes the hammer', o: side('stop', { arms: HAMMER.hold(), stake: 6 }) },
  { label: 'lifts it', o: side('stop', { arms: HAMMER.lift(), stake: 6 }) },
  { label: 'hammer up', o: side('stop', { arms: HAMMER.up(), stake: 6 }) },
  { label: 'swings', o: side('stop', { arms: HAMMER.swing(), stake: 6 }) },
  { label: 'tink', o: strike(4, false, 'tink') },
  { label: 'bounces off', o: side('stop', { arms: HAMMER.rebound(21), stake: 4, sparks: sparksOut(21, false) }) },
  { label: 'hammer up', o: side('stop', { arms: HAMMER.up(), stake: 4 }) },
  { label: 'swings', o: side('stop', { arms: HAMMER.swing(), stake: 4 }) },
  { label: 'tink', o: strike(2, false, 'tink') },
  { label: 'bounces off', o: side('stop', { arms: HAMMER.rebound(23), stake: 2, sparks: sparksOut(23, false) }) },
  { label: 'hammer up', o: side('stop', { arms: HAMMER.up(), stake: 2 }) },
  { label: 'winds right back', o: side('stop', { arms: HAMMER.back(), stake: 2 }) },
  { label: 'swings hard', o: side('stop', { arms: HAMMER.swing(), stake: 2 }) },
  { label: 'TONK, flush with the ground', o: strike(0, true, 'TONK') },
  { label: 'sparks fly', o: side('stop', { arms: HAMMER.strike(25), sparks: sparksOut(25, true) }) },
  { label: 'lets it rest', o: side('stop', { arms: HAMMER.rebound(25) }) },
  { label: 'puts the hammer away', o: side('stop', { arms: HAMMER.hold() }) },
  { label: 'starts to turn', o: side('stop') },
  { label: 'turns a quarter', o: { body: QUARTER } },
  { label: 'turns three quarters', o: { body: THREE_Q } },
  { label: 'faces the sun', o: { arms: ARMS.down } },
  { label: 'lifts a hand', o: { arms: ARMS.mid } },
  { label: 'shades the eyes', o: { arms: ARMS.salute } },
  { label: 'looks to the horizon', o: { arms: ARMS.salute } },
];

// --- the mark and the lines beside it ------------------------------------------------------

// The mark that heads init, report and version: a hard hat against the low sun, twenty columns of
// twelve pixels (six rows of text). `.` is nothing; the letters are colours, as MARK_COLOURS says.
const MARK = [
  '......sss###sss.....',
  '....ssee#####eess...',
  '...seee#######eees..',
  '..seeerrr##rrrreees.',
  '.seeerraa##aaarreees',
  'seeerraa####aaarreee',
  'seerraa######aaarree',
  'eerraaaa####yaaaarre',
  'eeraaaay####yyaaaare',
  'eeraaayy#yy#yyyaaare',
  'eeraaayy#yy#yyyaaare',
  'nnnnnnnnnnnnnnnnnnnn',
];
const MARK_COLOURS = { s: 'shade', e: 'earth', '#': SILHOUETTE, r: 'rust', a: 'amber', y: 'sun', n: 'night' };
const MARK_WIDTH = 20;
// The words beside the mark start here, whatever width the row of the mark above them has.
const TEXT_COLUMN = 23;

function mark(tier, palette = thePalette()) {
  const pixels = MARK.map((row) => Array.from(row, (ch) => (ch === '.' ? null : MARK_COLOURS[ch])));
  return halfBlocks(pixels, tier, palette);
}

// The mark with a line of words beside each of its rows: `beside[i]` is the runs for row i (null or
// missing for none). A line past the mark's last row goes on below it, from the left.
function withMark(tier, beside, palette = thePalette()) {
  const art = mark(tier, palette);
  const rows = [];
  for (let i = 0; i < Math.max(art.length, beside.length); i++) {
    const row = i < art.length ? art[i].slice() : [];
    const words = beside[i];
    if (words && words.length) {
      const width = row.reduce((n, r) => n + Array.from(r.t).length, 0);
      if (i < art.length) row.push({ t: ' '.repeat(Math.max(1, TEXT_COLUMN - width)), style: null });
      row.push(...words);
    }
    rows.push(row);
  }
  return rows;
}

// A run of text: plain, or in a palette colour, or bold.
const word = (t, fg, bold) => ({ t, style: fg || bold ? { ...(fg && { fg }), ...(bold && { bold: true }) } : null });
const RULE_WIDTH = 96;
const rule = (cols) => [word('▔'.repeat(Math.min(cols, RULE_WIDTH)), 'earth')];
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
const listOf = (v) => (v === undefined ? [] : [].concat(v));

// A ticket's short name from its path: the number in front of the first hyphen, with a letter
// after it for a followup (07, 07a); otherwise the file's name without `.md`.
function ticketId(file) {
  const base = String(file).replace(/^.*[\\/]/, '').replace(/\.md$/i, '');
  const m = /^(\d+[a-z]?)(?=-|$)/i.exec(base);
  return m ? m[1] : base;
}

// How many tickets an ordering moved: those not in the longest run that kept its relative order,
// so one ticket taken to the front is one moved, not all that it passed. A ticket the agent
// dropped or added is neither.
function movedCount(before, after) {
  const kept = new Set(after);
  const a = before.filter((t) => kept.has(t));
  const had = new Set(before);
  const b = after.filter((t) => had.has(t));
  let prev = Array(b.length + 1).fill(0);
  for (const x of a) {
    const row = [0];
    for (let j = 0; j < b.length; j++) row.push(x === b[j] ? prev[j] + 1 : Math.max(prev[j + 1], row[j]));
    prev = row;
  }
  return a.length - prev[b.length];
}

// --- init ----------------------------------------------------------------------------------

// `foreman init` is drawn in two goes, because the agent's ordering takes as long as it takes:
// `init` is the header and the files written, drawn as soon as they are; `init-done` is how the
// ordering went and the steps to take, drawn when it is over.
const INIT_MIN = 64;
const FILE_COLUMN = 16;    // a file's description starts this far in from its name, at least

function initHead(facts, { tier, cols }) {
  const tickets = Number(facts.tickets) || 0;
  const dirs = Math.max(Number(facts.dirs) || 0, 1);
  const found = tickets === 0 ? 'no tickets yet' : `${plural(tickets, 'ticket', 'tickets')} in ${plural(dirs, 'issue directory', 'issue directories')}`;
  const rows = [[], ...withMark(tier, [
    null,
    [word('FOREMAN', 'amber', true), word('  '), word('breaks ground', 'muted')],
    [word('batch ', 'muted'), word(` ${facts.batch ?? ''}`)],
    [word('found ', 'muted'), word(` ${found}`)],
  ]), rule(cols), []];
  const files = listOf(facts.file).map((f) => f.split('\t'));
  const nameWidth = Math.max(FILE_COLUMN, ...files.map(([, name]) => Array.from(name).length + 4));
  for (const [state, name, desc = '', hint] of files) {
    const kept = state === 'kept';
    const row = [word('  '), word(kept ? '=' : '+', kept ? 'amber' : 'ok', true), word(' '), word(name, null, true),
      word(' '.repeat(nameWidth - Array.from(name).length)), word(desc, 'muted')];
    if (state === 'replaced') row.push(word('  ·  ', 'muted'), word('replaced', 'amber'));
    rows.push(row);
    if (hint) rows.push([word('    '), word('rename it:', 'muted'), word(`  ${hint}`)]);
  }
  rows.push([]);
  return rows;
}

const ORDER_COLUMN = 26;    // the ordering result's figures start this far in from the start of its label

// "3 moved", "07 is yours, 07a checks it", "31s", "$0.08": what the ordering did, as far as the
// facts say.
function orderFigures(facts) {
  const parts = [];
  const was = listOf(facts.was), now = listOf(facts.now);
  if (was.length && now.length) {
    const moved = movedCount(was, now);
    parts.push(moved === 0 ? 'none moved' : `${moved} moved`);
  }
  const humans = listOf(facts.human);
  const checks = listOf(facts.check).map((c) => c.split('\t'));
  const tied = new Set();
  const people = [];
  for (const h of humans) {
    people.push(`${ticketId(h)} is yours`);
    for (const [c, target] of checks) {
      if (target === h) { people.push(`${ticketId(c)} checks it`); tied.add(c); }
    }
  }
  for (const [c, target] of checks) {
    if (!tied.has(c) && target) people.push(`${ticketId(c)} checks ${ticketId(target)}`);
  }
  if (people.length) parts.push(people.join(', '));
  parts.push(...elapsedAndCost(facts));
  return parts;
}

function elapsedAndCost(facts) {
  const parts = [];
  if (facts.seconds !== undefined && facts.seconds !== '') {
    const s = Number(facts.seconds);
    parts.push(s >= 60 ? `${Math.floor(s / 60)}m${s % 60}s` : `${s}s`);
  }
  if (facts.cost !== undefined && facts.cost !== '') parts.push(`$${Number(facts.cost).toFixed(2)}`);
  return parts;
}

// The ordering result, which is a ✓ line and its caution, a ✗ or ▲ line and what to do, or nothing
// at all when there was no ordering (--no-order, or an order.md that was kept).
function orderRows(facts) {
  const indent = word('    ');
  const note = (t) => [indent, word(t, 'muted')];
  const batch = facts.batch ?? '';
  const invoke = facts.invoke ?? 'foreman';
  const tick = (mark, colour, label, figures) => {
    const row = [word('  '), word(mark, colour), word(` ${label}`)];
    if (figures.length) row.push(word(' '.repeat(Math.max(2, ORDER_COLUMN - Array.from(label).length))), word(figures.join('  ·  '), 'muted'));
    return row;
  };
  const rows = [];
  if (facts.result === 'ordered') {
    rows.push(tick('✓', 'ok', 'ordered by the agent', orderFigures(facts)));
    rows.push(note('a first pass, not a guarantee — look it over'));
  } else if (facts.result === 'failed') {
    rows.push(tick('✗', 'error', 'not ordered', ['the agent call failed', ...elapsedAndCost(facts)]));
    if (facts.said) rows.push(note(`claude said: ${facts.said}`));
    if (facts.auth === '1') rows.push(note(`your claude login has expired — run \`claude /login\`, then re-run \`${invoke} order ${batch}\``));
    rows.push(note(`order.md is in filename order — ${invoke} order ${batch} tries again`));
  } else if (facts.result === 'skipped') {
    rows.push(tick('▲', 'amber', 'not ordered', [facts.said || 'the agent did not run']));
    rows.push(note(`order.md is in filename order — ${invoke} order ${batch} once it is`));
  } else {
    return rows;
  }
  for (const w of listOf(facts.warning)) rows.push([word('  '), word('▲', 'amber'), word(` ${w}`)]);
  rows.push([]);
  return rows;
}

function initDone(facts) {
  const batch = facts.batch ?? '';
  const invoke = facts.invoke ?? 'foreman';
  if (facts.wrote === '0') {
    return [[word('  '), word('=', 'amber', true), word(' already marked out — nothing changed. --force writes the three files again.', 'muted')]];
  }
  const step = (n, ...rest) => [word('  '), word(String(n), 'amber', true), word('  '), ...rest];
  const gap = (a, width) => word(' '.repeat(width - Array.from(a).length));
  const dry = `${invoke} dry-run ${batch}`, run = `${invoke} run ${batch}`;
  const cmd = Math.max(Array.from(dry).length, Array.from(run).length) + 3;
  return [
    ...orderRows(facts),
    [word('NEXT', 'amber', true)],
    step(1, word('edit    '), word(`${batch}/foreman.conf`), word('   '), word('FOREMAN_CHECK_CMD and FOREMAN_TEST_CMD at least', 'muted')),
    step(2, word('review  '), word(`${batch}/order.md`)),
    step(3, word(dry, 'amber'), gap(dry, cmd), word('free  ·  prints the exact prompt', 'muted')),
    step(4, word(run, 'amber'), gap(run, cmd), word('one iteration, then look', 'muted')),
  ];
}

// --- the scenes ----------------------------------------------------------------------------

// Each scene has the width it needs (below it the caller prints plain text), how many frames it
// has (an animation has more than one; the last is where it rests), and a function from facts and
// { tier, cols, frame } to rows. The shell checks `min` against the terminal before it starts
// node, so the number is also in bin/foreman, and a smoke case holds the two together.
const SCENES = {
  // `foreman help`: the big sun with the whole figure inside it, over a blank line, then the help.
  help: {
    min: 64,
    frames: 1,
    rows: (facts, { tier }) => [...halfBlocks(sunPixels({ r: 28, cx: 32, fx: 21 }), tier), []],
  },
  // `foreman init`, in two parts: the header and the files written, then the ordering and NEXT.
  init: { min: INIT_MIN, frames: 1, rows: (facts, o) => initHead(facts, o) },
  'init-done': { min: INIT_MIN, frames: 1, rows: (facts) => initDone(facts) },
  // The intro to `foreman help`: the same picture, at the end of a short film, and the same blank
  // line, so that when it has played the help text goes on where the help's own picture would end.
  intro: {
    min: INTRO_W,
    frames: INTRO.length,
    rows: (facts, { tier, frame }) => {
      const { pixels, texts } = introPixels(INTRO[frame].o);
      return [...halfBlocks(pixels, tier, thePalette(), texts), []];
    },
  },
};

// --- the entry points ----------------------------------------------------------------------

// `key<TAB>value` lines to an object; a key that repeats is a list, in order. A line with no tab
// is a key with no value, and a blank line is nothing.
function parseFacts(text) {
  const facts = Object.create(null);    // a fact may be named anything, `constructor` included
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

function sceneNamed(scene) {
  if (!Object.hasOwn(SCENES, scene)) throw new Error(`unknown scene '${scene}'`);
  return SCENES[scene];
}

// One frame of a scene (the last, where it rests, unless told) at a tier (16, 256 or 24) and
// width, or '' when the width is below the scene's minimum.
function draw(scene, facts, { tier, cols, frame }) {
  const s = sceneNamed(scene);
  if (cols < s.min) return '';
  const at = frame ?? s.frames - 1;
  if (!Number.isInteger(at) || at < 0 || at >= s.frames) throw new Error(`no frame ${frame} in '${scene}' (0 to ${s.frames - 1})`);
  return encode(s.rows(facts, { tier, cols, frame: at }), tier);
}

// Every frame of a scene, ready to be played one over the last: each row clears the rest of its
// line, and none of them is a row too wide to clear. An empty list below the scene's minimum.
function drawFrames(scene, facts, { tier, cols }) {
  const s = sceneNamed(scene);
  if (cols < s.min) return [];
  return Array.from({ length: s.frames }, (_, frame) =>
    encode(s.rows(facts, { tier, cols, frame }), tier, thePalette(), { erase: cols }));
}

// --- playing -------------------------------------------------------------------------------

const HIDE_CURSOR = `${ESC}[?25l`;
const SHOW_CURSOR = `${ESC}[?25h`;
const STOP_SIGNALS = ['SIGINT', 'SIGTERM', 'SIGHUP'];
const CTRL_C = 0x03;

// Plays frames (strings of whole lines) in place on `out`: the first where the cursor is, each next
// one over the last by moving up its height. The cursor is hidden while it plays. Resolves with how
// it ended — 'done', 'skipped' (any key on `input`: the last frame is drawn at once), or
// 'interrupted' (Ctrl-C, which a raw terminal delivers as a byte, or a signal: where it stood is
// left as it is) — after the cursor is shown, the input is back as it was and nothing is listening.
// It rejects with whatever went wrong writing, after the same.
//
// `input` is put in raw mode only while this plays (so a key needs no Enter), and only if there is
// one; it may be null. `signals` is where SIGINT and friends arrive, the process by default.
function play(frames, { out, input = null, stepMs = 70, signals = process }) {
  return new Promise((resolve, reject) => {
    const height = (frame) => frame.split('\n').length - 1;
    let drawn = -1;          // the index of the frame on screen
    let hidden = false;
    let raw = false;
    let timer = null;
    let started = 0;
    let settled = false;

    const show = (index) => {
      out.write((drawn >= 0 ? `${ESC}[${height(frames[drawn])}A` : '') + frames[index]);
      drawn = index;
    };
    const finish = (how, error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      for (const sig of STOP_SIGNALS) signals.removeListener(sig, onSignal);
      if (input) {
        input.removeListener('data', onKey);
        if (raw) { try { input.setRawMode(false); } catch { /* the terminal went away */ } }
        input.pause();
      }
      if (hidden) { try { out.write(SHOW_CURSOR); } catch { /* nowhere to write to */ } }
      if (error) reject(error); else resolve(how);
    };
    const attempt = (fn) => { try { fn(); } catch (e) { finish(null, e); } };
    function onSignal() { finish('interrupted'); }
    function onKey(chunk) {
      if (settled) return;
      if (Buffer.from(chunk).includes(CTRL_C)) return finish('interrupted');
      attempt(() => {
        if (drawn < frames.length - 1) show(frames.length - 1);
        finish('skipped');
      });
    }
    const tick = () => {
      if (settled) return;
      attempt(() => {
        show(drawn + 1);
        if (drawn === frames.length - 1) finish('done');
        // on the clock rather than a step after the last draw, so a slow write does not stretch the whole
        else timer = setTimeout(tick, Math.max(0, started + (drawn + 1) * stepMs - Date.now()));
      });
    };

    if (frames.length === 0) return resolve('done');
    for (const sig of STOP_SIGNALS) signals.on(sig, onSignal);
    attempt(() => {
      if (input) {
        input.setRawMode(true);
        raw = true;
        input.on('data', onKey);
        input.resume();
      }
      hidden = true;
      out.write(HIDE_CURSOR);
      started = Date.now();
      tick();
    });
  });
}

// --- the command line ----------------------------------------------------------------------

// Whether `--play` has a terminal to play on. The picture is drawn in place, so it needs both
// ends (a pipe has no cursor to move, and without a terminal on stdin no key could skip it) and
// room for the whole frame, or moving up would not reach the top of it.
function canPlay(frameHeight) {
  if (!process.stdin.isTTY || !process.stdout.isTTY) return false;
  return !(process.stdout.rows && process.stdout.rows <= frameHeight);
}

async function playScene(scene, tier, cols, stepMs) {
  const frames = drawFrames(scene, {}, { tier, cols });
  if (!canPlay(frames[0].split('\n').length - 1)) return 4;
  process.stdout.on('error', () => {});
  let how;
  try {
    how = await play(frames, { out: process.stdout, input: process.stdin, stepMs });
  } catch (e) {
    process.stderr.write(`foreman-draw: ${e.message}\n`);
    return 1;
  }
  return how === 'interrupted' ? 130 : 0;
}

function main(argv) {
  const usage = (msg) => { process.stderr.write(`foreman-draw: ${msg}\n`); return 2; };
  let scene = null, tier = null, cols = null, frame = null, step = null, playing = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--tier') tier = argv[++i];
    else if (argv[i] === '--cols') cols = argv[++i];
    else if (argv[i] === '--frame') frame = argv[++i] ?? '';
    else if (argv[i] === '--step') step = argv[++i];
    else if (argv[i] === '--play') playing = true;
    else if (argv[i].startsWith('-') || scene !== null) return usage(`unexpected argument '${argv[i]}'`);
    else scene = argv[i];
  }
  if (scene === null) return usage('usage: foreman-draw.cjs SCENE --tier 16|256|24 --cols N [--frame N | --play]');
  if (!Object.hasOwn(SCENES, scene)) return usage(`unknown scene '${scene}'`);
  if (!['16', '256', '24'].includes(tier)) return usage('--tier must be 16, 256 or 24');
  if (!/^[0-9]+$/.test(cols || '') || Number(cols) < 1) return usage('--cols must be a width in columns');
  const { frames } = SCENES[scene];
  if (frame !== null && (!/^[0-9]+$/.test(frame) || Number(frame) >= frames)) {
    return usage(`--frame must be a frame number, 0 to ${frames - 1} for '${scene}' (got '${frame}')`);
  }
  if (step !== null && !/^[0-9]+$/.test(step)) return usage('--step must be a number of milliseconds');
  if (playing && frame !== null) return usage('--play and --frame are alternatives');
  if (Number(cols) < SCENES[scene].min) {
    process.stderr.write(`foreman-draw: ${cols} columns is too narrow for '${scene}' (needs ${SCENES[scene].min})\n`);
    return 3;
  }

  if (playing) return playScene(scene, Number(tier), Number(cols), step === null ? 70 : Number(step));

  // A terminal on stdin means no one piped facts in; reading it would wait for a person.
  let text = '';
  if (!process.stdin.isTTY) {
    try { text = fs.readFileSync(0, 'utf8'); } catch { /* closed or empty: no facts */ }
  }
  const out = draw(scene, parseFacts(text), { tier: Number(tier), cols: Number(cols), frame: frame === null ? undefined : Number(frame) });
  process.stdout.on('error', () => {});    // a reader that left early (| head) is not our error
  process.stdout.write(out);
  return 0;
}

module.exports = {
  loadPalette, encode, sgr, halfBlocks, parseFacts, draw, drawFrames, play, SCENES,
  mark, withMark, MARK_WIDTH, TEXT_COLUMN, rule, ticketId, movedCount,
};

if (require.main === module) {
  Promise.resolve(main(process.argv.slice(2))).then((code) => { process.exitCode = code; });
}
