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
//
// THE SPLIT. Whether to draw at all is not decided here. foreman-ui.sh (`ui_show`, `ui_cols`) says
// whether this call gets the show or its plain text, at which colour tier and how wide, and the
// command checks its scene's width below; only then is this file started, with the facts the shell
// already has. Plain output starts no node. If a picture cannot be made (no node, a scene that
// throws, a row too wide) the caller prints its plain text, so a failing renderer costs the
// picture and nothing else. README.md, "Terminal output", is the reader's side of this.
//
// HOW TO ADD A SCENE.
//   1. Design it: a page in .scratch/DONE_terminal-design/designs/source/ and its two renderings in
//      designs/, NN-name.ans (the picture, with colour) and NN-name.txt (the same without).
//   2. Write `fooRows(facts, { tier, cols })` in this file and register it in SCENES with its
//      `min` width and `frames` (1 for a picture). Facts are numbers and short words; the scene
//      does the wording, so the shell never has to know how a line is laid out.
//   3. In the command, keep today's output as it is. Ask `ui_show 1 TIER && ui_cols COLS 1` and
//      compare COLS with `_foo_min_cols`, the same number as `min` (a smoke case holds the two
//      together), then pipe the facts to `node foreman-draw.cjs foo --tier $TIER --cols $COLS`.
//      Print the plain text when that fails.
//   4. Test it: the scene against its .ans cell for cell (test/ans-cells.cjs reads one), the plain
//      output byte for byte in every environment that is not the show, and a forced show with
//      FOREMAN_SHOW=always FOREMAN_COLOR=truecolor COLUMNS=120. Then add the command to
//      test/demo.sh, and a row to the width table in README.md.
//   5. Name it in THE SCENES below. A smoke case fails for a scene that is missing there.
//
// THE SCENES. Each is one entry: the command it draws, the facts it takes (`key` is one line of the
// facts, `key*` a list that repeats), and the design it was made from, in
// .scratch/DONE_terminal-design/designs/ (the .ans and .txt of that name; `source:` is the page in
// designs/source/ that the design was drawn in).
//
//   help         `foreman help` and bare `foreman`: the sunrise, then the help text
//      facts: none
//      design: 01-help-d1
//      source: SunrisePicks.dc.html
//   intro        the film that plays before it on a terminal, 36 frames (`--play`, or `--frame N`)
//      facts: none
//      design: 02-intro3-frames
//      source: Intro3.dc.html
//   init         `foreman init`, the first part: the mark, the batch, the files written
//      facts: batch, tickets, dirs, file* (state<TAB>name<TAB>description[<TAB>hint])
//      design: 07a-init
//      source: InitTakes.dc.html
//   init-done    `foreman init`, the second part: how ordering went, then NEXT
//      facts: batch, invoke, wrote, and what 'order' takes (result, said, auth, warning*)
//      design: 07a-init
//      source: InitTakes.dc.html
//   status       `foreman status`: the dome whose sun climbs with the tickets done, the list
//      facts: batch, name, done, total, spent, humans, sentback, stop, until, handoff, invoke,
//             ticket* (as for 'next'), warning*
//      design: 04a-status
//      source: StatusTakes.dc.html
//   dryrun       `foreman dry-run`: the low sun, the settings, the prompt that would be sent
//      facts: batch, name, done, total, model, effort, exec, perms, iterations, cost, time, live,
//             stop, handoff, promptfor, screen, logs*, ticket*, warning*, prompt*
//      design: 11a-dry-run
//      source: DryRunTakes.dc.html
//   run          `foreman run`: the figure and the dome, again a step higher as each ticket lands
//      facts: batch, name, runid, started, model, exec, done, total, landed, iterations, minutes,
//             cost, human
//      design: 03a-run-live-steps, 03a-run-quiet-steps
//      source: RunSunrise.dc.html
//   order-head   `foreman order`, the header drawn before the agent starts
//      facts: batch, model, tickets
//      design: 08b-order
//      source: OrderTakes.dc.html
//   order        `foreman order`, the new order on a stake line once the agent is done
//      facts: batch, invoke, seconds, cost, was*, now*, human*, check*, warning*
//      design: 08b-order
//      source: OrderTakes.dc.html
//   next         `foreman next --all`: a stake for each ticket, the one that is next standing tall
//      facts: ticket* (state<TAB>file<TAB>human<TAB>checks)
//      design: 09b-next
//      source: NextTakes.dc.html
//   next-count   `foreman next --count`: the same sum on one line
//      facts: done, total
//      design: 09b-next
//      source: NextTakes.dc.html
//   doctor       `foreman doctor`: the box of checks and its verdict; `--t N` is one tick of the
//                inspector, `--stream` draws it live as checks arrive, `--plain` is the box alone
//      facts: repo, home, date, rev, expect, check* (section<TAB>state<TAB>text[<TAB>detail]),
//             advice* (label<TAB>command)
//      design: 05b-doctor-good-frames, 05b-doctor-issues-frames
//      source: DoctorInspect.dc.html
//   version      `foreman version`: the mark beside the build
//      facts: rev, path, home
//      design: 13a-version
//      source: VersionTakes.dc.html
//   report       `foreman report`: the mark beside the bill, the outcomes, the ledger of runs
//      facts: batch, command, mode, runs, iterations, minutes, cost, turns, landed, progressed,
//             stalled, unproductive, input, output, cache-read, cache-write, checkpoints,
//             limit-hits, unreadable, run* (id<TAB>iterations<TAB>landed<TAB>minutes<TAB>cost),
//             table* (head|text<TAB>words)
//      design: 10a-report
//      source: ReportTakes.dc.html
//   convert      `foreman convert`: the sign repainted from RALPH to FOREMAN, then what changed
//      facts: project, home, dry, rename*, rewrite*, delete*, blocked*, own*, credit, mention*,
//             envfile, var*, sandbox*, windows
//      design: 12a-convert
//      source: ConvertTakes.dc.html
//
// Each scene's own comment, below, says what its facts mean.

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

// The SGR parameters for a style at a tier, in the order 0 (reset), bold, strike-through (9), foreground,
// background. A terminal that does not know 9 draws the words without it.
// At 16 a colour is its nearest name's code; `2` (dim) is an attribute, so it can be written as
// a foreground but there is no such thing as a dim background, and `0` (the terminal's own text
// colour) is no code at all. At 256 a colour with no shade (text) is the terminal's own too.
function sgr(style, tier, palette) {
  const codes = [];
  if (style.bold) codes.push('1');
  if (style.strike) codes.push('9');
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

// Rows of runs to text at a tier (0 for none: the words alone): a line each, and every line ends by
// dropping whatever style is still on, so a drawing can be followed by anything. With `erase` (a width in columns) a row
// shorter than that also clears the rest of its line, which is what drawing over a previous frame
// needs; a row as wide as the terminal does not, as the cursor is waiting to wrap there and a clear
// would take the last cell with it.
function encode(rows, tier, palette = thePalette(), { erase = 0 } = {}) {
  let out = '';
  if (tier === 0) {    // plain: the words, and no escape in them
    for (const row of rows) out += `${row.map((run) => run.t).join('')}\n`;
    return out;
  }
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
// `texts` are words written over the art, `{ x, y, t, bold, fg, bg }` with x and y in pixels: each
// letter takes a whole cell, in the silhouette's colour on whatever the cell held, or in `fg` on `bg`.
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
        // A word that names its own colours is painted in them on that and nothing else; one that
        // does not is in the silhouette's colour on whatever the cell held.
        const style = word.fg ? { fg: word.fg, ...(word.bg && { bg: word.bg }) } : { fg: SILHOUETTE, ...(bg !== null && { bg }) };
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

// The sky of the sunrise as a grid of pixels (a colour, or null for none): w wide and `h` tall (36)
// with the horizon on row `horizon` (30). The sun has radius r around column cx and rises by s (0
// is set, 1 is full). Inside its disc the colour goes from sun to amber to rust by distance from
// the centre, then a ring of earth and one of shade, and below the horizon the ground (night), with
// a stripe of post for the reflection.
const HORIZON = 30;
function skyPixels({ w, r, cx, s = 1, horizon = HORIZON, h = 36 }) {
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

// --- version -------------------------------------------------------------------------------

// The text column plus the longest of the three lines beside the mark, which is the description.
const VERSION_DESCRIPTION = 'one ticket per iteration, until the batch is done';
const VERSION_MIN = TEXT_COLUMN + Array.from(VERSION_DESCRIPTION).length;

// PATH with the home directory it is under written as `~`, as a person says it. Only whole
// directories count (`/home/you2` is not under `/home/you`), and a home of `/` or nothing is not
// worth a `~`.
function tilde(file, home) {
  if (file === undefined) return '';
  const base = String(home ?? '').replace(/\/+$/, '');
  if (!base) return file;
  if (file === base) return '~';
  return file.startsWith(`${base}/`) ? `~${file.slice(base.length)}` : file;
}

// `foreman version`: the mark, and beside it the name and build, where it is installed, and what
// it is for. The facts are `rev`, `path` and `home`; the path is shortened here, so the plain text
// the shell prints keeps the whole of it.
function versionRows(facts, { tier }) {
  return [[], ...withMark(tier, [
    null,
    [word('FOREMAN', 'amber', true), word('  '), word(facts.rev ?? '', null, true)],
    [word('installed at', 'muted'), word(` ${tilde(facts.path, facts.home)}`)],
    [word(VERSION_DESCRIPTION, 'muted')],
  ]), []];
}

// --- the dome and status -------------------------------------------------------------------

// The dome is status's (and the run header's): the sunrise's sky, 34 across, with the sun a little
// higher for every ticket done. At 6 of 10 it is the 4a design to the cell (radius 13 around column
// 17, the sun 0.6 of the way up); the radius never changes, only how far up the sun is, so the dome
// is as tall as the sun is high. It is never shorter than the design's five rows of sky, so the
// words beside it stay where the design has them, and has a blank row above it and the ground
// under it.
const DOME_W = 34, DOME_R = 13, DOME_CX = 17;
const DOME_MIN_SKY = 5;

function dome(done, total, tier, palette = thePalette()) {
  const s = total > 0 ? Math.min(Math.max(done, 0), total) / total : 0;
  const at = (horizon, h) => skyPixels({ w: DOME_W, r: DOME_R, cx: DOME_CX, s, horizon, h });
  // How many rows of sky this sun needs: drawn once on a tall grid, to see where it starts.
  const probe = at(30, 32).slice(0, 30);
  const top = probe.findIndex((row) => row.some((c) => c !== null));
  const sky = Math.max(DOME_MIN_SKY, Math.ceil((30 - top) / 2));
  const horizon = 2 * (sky + 1);
  return halfBlocks(at(horizon, horizon + 2), tier, palette);
}

// `foreman status`: the dome, and beside it the batch, how many are done and what was spent, and how
// far up the sun is; under it every ticket in order (✓ done, ▶ next), then what to do about it. The
// words start at STATUS_TEXT, where the design has them, and the scene needs 35 columns for them
// after that (a count of three digits with a spend of four figures).
const STATUS_TEXT = 37;
const STATUS_MIN = STATUS_TEXT + 35;
const ID_WIDTH = 3;    // the number of a ticket, padded to this at least: `07a` is the longest the design has

const runsWidth = (runs) => runs.reduce((n, r) => n + Array.from(r.t).length, 0);

// A ticket fact is `state<TAB>file<TAB>human<TAB>checks`: done, next or todo; the file's name; `human`
// for a ticket only a person can do; the ticket a followup checks.
function statusTicket(fact) {
  const [state, file = '', human = '', checks = ''] = fact.split('\t');
  const base = file.replace(/^.*[\\/]/, '').replace(/\.md$/i, '');
  const id = ticketId(file);
  const numbered = id !== base;
  const name = numbered ? base.slice(id.length).replace(/^-/, '') : '';
  return { state, id, name, numbered, human: human === 'human', checks: checks ? ticketId(checks) : '' };
}

// The facts, from foreman-loop.sh: `batch` and its `name`, `done` of `total`, `spent` (left out when
// there is no run log), `humans` still to do, `invoke` (how to spell the command), a `ticket` for
// each in order, and for the loop's note `until` (how many it will run) and `stop` (the human
// ticket it stops at), or for a human ticket next its `handoff` file and who it was `sentback` by;
// and each `warning`.
function statusRows(facts, { tier }) {
  const done = Number(facts.done) || 0;
  const total = Number(facts.total) || 0;
  const percent = total > 0 ? Math.floor((100 * Math.min(done, total)) / total) : 0;
  const invoke = facts.invoke ?? 'foreman';
  const batch = facts.batch ?? '';
  const tickets = listOf(facts.ticket).map(statusTicket);
  const next = tickets.find((t) => t.state === 'next');
  const humans = Number(facts.humans) || 0;
  const beside = (...runs) => [word(' '.repeat(STATUS_TEXT)), ...runs];

  const art = dome(done, total, tier);
  const words = new Map([
    [art.length - 5, [word(facts.name ? `${batch} (${facts.name})` : batch, 'amber', true)]],
    [art.length - 3, [
      word(`${done} of ${total}`, 'sun', true),
      word(` done${facts.spent !== undefined && facts.spent !== '' ? `  ·  $${Number(facts.spent || 0).toFixed(2)} spent` : ''}`, 'muted'),
    ]],
    [art.length - 2, [word(`the sun is ${percent}% up`, 'muted')]],
  ]);
  const rows = [[]];
  art.forEach((row, i) => {
    if (!words.has(i)) { rows.push(row); return; }
    rows.push([...row, word(' '.repeat(Math.max(1, STATUS_TEXT - runsWidth(row)))), ...words.get(i)]);
  });
  // The one thing today's text says that the design has no place for goes in the gap under the ground.
  rows.push(humans > 0 ? beside(word(plural(humans, 'human ticket', 'human tickets') + ' remaining', 'muted')) : []);

  const idWidth = Math.max(ID_WIDTH, ...tickets.filter((t) => t.numbered).map((t) => Array.from(t.id).length));
  const nameWidth = Math.max(0, ...tickets.map((t) => Array.from(t.name).length));
  for (const t of tickets) {
    const label = t.numbered ? `${t.id.padEnd(idWidth)} ${t.name}` : t.id;
    const mark = t.state === 'done' ? word('✓', 'ok') : t.state === 'next' ? word('▶', 'amber') : word(' ');
    const row = [word('  '), mark, word(' ')];
    if (t.state === 'done') row.push(word(label, 'muted'));
    else row.push(word(label, null, t.state === 'next'));
    if (t.human) {
      row.push(word(' '.repeat(3)), { t: ' HUMAN ', style: { fg: 'ink', bg: 'amber', bold: true } });
    }
    if (t.checks) {
      const pad = t.human ? 2 : Math.max(2, nameWidth - Array.from(t.name).length);
      row.push(word(' '.repeat(pad)), word(`after ${t.checks}`, 'muted'));
    }
    rows.push(row);
  }

  const close = [];
  if (next && next.human) {
    const handoff = facts.handoff ? ', fill in its handoff' : '';
    if (facts.sentback) close.push([word(`↩ sent back by ${facts.sentback}: read '## Sent back by ${facts.sentback}' at the bottom of the ticket`, 'amber')]);
    close.push([word('next up is yours.', 'amber', true), word(` Do ticket ${next.id}${handoff}, then `), word(`${invoke} run ${batch}`, 'amber'), word('.')]);
    if (facts.handoff) close.push([word(facts.handoff, 'muted')]);
  } else if (next && facts.stop) {
    close.push([word(`The loop will run ${plural(Number(facts.until) || 0, 'ticket', 'tickets')}, then stop at ${facts.stop} for a human.`)]);
  } else if (!next && total > 0) {
    close.push([word('Nothing left — every ticket in this batch is done.')]);
  }
  if (close.length) rows.push([], ...close);
  const warnings = listOf(facts.warning);
  if (warnings.length) rows.push([], ...warnings.map((w) => [word('▲', 'amber'), word(` ${w}`)]));
  rows.push([]);
  return rows;
}

// --- dry-run -------------------------------------------------------------------------------

// `foreman dry-run`: a walk round before the work starts. The sun is barely up (a quarter of the
// way, 11a's own: radius 9 around column 10 of 20, three rows of text), the words above and beside
// it say what this is; under it the tickets that would run, the settings in two columns, and the
// prompt that would be sent, numbered, and folded to the screen with a ⋮ when it is longer.
const DRYRUN_SUBTITLE = 'a walk round before work starts: no prompt is sent, no sandbox starts';
const DRYRUN_MIN = TEXT_COLUMN + Array.from(DRYRUN_SUBTITLE).length;
const DRYRUN_CLOSING = 'nothing was sent; no sandbox was started';
const SETTINGS_INDENT = 11;    // the second and later rows of SETTINGS start under its first value's label
const SETTINGS_LABEL = 9;      // a label and the space after it, at least
const SETTINGS_VALUE = 22;     // a first column's value and the space after it, at least; three, if it is longer
const PROMPT_ROWS_MIN = 9;     // rows of the prompt however short the screen: it is not worth showing fewer
const PROMPT_TAIL = 2;         // lines kept at the end when the prompt is folded
const DEFAULT_SCREEN = 24;     // lines, when the caller does not know

const lowSun = (tier) => halfBlocks(skyPixels({ w: 20, r: 9, cx: 10, s: 0.25, horizon: 5, h: 6 }), tier);

// A tag after a ticket's name: HUMAN for a ticket only a person can do, CHECK for one that checks another.
const tagRuns = (t) => {
  const runs = [];
  if (t.human) runs.push({ t: ' HUMAN ', style: { fg: 'ink', bg: 'amber', bold: true } });
  if (t.checks) runs.push(...(runs.length ? [word(' ')] : []), { t: ' CHECK ', style: { bg: 'dim', bold: true } });
  return runs;
};

// One row of SETTINGS: a label and value in the first column, and a label and value in the second,
// each value being runs. The second column starts at a fixed place, or three spaces on from a value
// that went past it, as the design's does.
function settingsRow(heading, first, second) {
  const row = [heading ? word('SETTINGS', 'amber', true) : word(' '.repeat(8)), word(' '.repeat(SETTINGS_INDENT - 8))];
  const put = ([label, value]) => {
    row.push(word(label, 'muted'), word(' '.repeat(Math.max(1, SETTINGS_LABEL - Array.from(label).length))), ...value);
  };
  put(first);
  if (second) {
    row.push(word(' '.repeat(Math.max(3, SETTINGS_VALUE - runsWidth(first[1])))));
    put(second);
  }
  return row;
}

// The prompt's lines, as the rows to draw: [number, text] for a line, null for the fold. `room` is
// how many rows it may take; a prompt that fits is whole, and one that does not keeps its first
// lines, the fold, and the last PROMPT_TAIL.
function foldPrompt(lines, room) {
  const all = lines.map((text, i) => [i + 1, text]);
  if (all.length <= room) return all;
  const head = room - 1 - PROMPT_TAIL;
  return [...all.slice(0, head), null, ...all.slice(all.length - PROMPT_TAIL)];
}

// How a line of the prompt is picked out: its first line, the `@` that names the ticket, in amber;
// a heading bold; a line that is only a tag, muted. Anything else is as it is.
function promptLine(text) {
  if (text.startsWith('@')) return word(text, 'amber');
  if (/^#{1,6} /.test(text)) return word(text, 'sun', true);
  if (/^<\/?[A-Za-z][\w-]*>$/.test(text)) return word(text, 'muted');
  return word(text);
}

// The facts, from foreman-loop.sh: `batch` and its `name`, `done` of `total`, a `ticket` for each
// that would run (as in status, the first being `next`), the settings (`exec`, `perms`, `model`,
// `effort`, `live` on or off, the three budgets as the loop labels them — `$25`, `90m`, `unlimited`
// — and the two `logs`), each `warning`, the `screen`'s height in lines, and either the prompt (the
// ticket it is `promptfor`, and a `prompt` fact for each of its lines) or, when the next ticket is a
// human one, the `stop` it would make there and the `handoff` file.
function dryrunRows(facts, { tier }) {
  const done = Number(facts.done) || 0;
  const total = Number(facts.total) || 0;
  const tickets = listOf(facts.ticket).map(statusTicket);
  const art = lowSun(tier);
  const beside = new Map([[0, [
    word(`${done} of ${total} done`, 'ok'),
    word(`  ·  ${tickets.length} would run`, 'muted'),
  ]]]);
  const rows = [
    [], [],
    [word(' '.repeat(TEXT_COLUMN)), word('FOREMAN', 'amber', true), word('  '), word('dry run', 'muted'),
      word(`  ${facts.batch ?? ''}`), ...(facts.name ? [word(` (${facts.name})`, 'muted')] : [])],
    [word(' '.repeat(TEXT_COLUMN)), word(DRYRUN_SUBTITLE, 'muted')],
  ];
  art.forEach((row, i) => {
    const words = beside.get(i);
    rows.push(words ? [...row, word(' '.repeat(Math.max(1, TEXT_COLUMN - runsWidth(row)))), ...words] : row);
  });
  rows.push(rule(RULE_WIDTH), [word('WOULD RUN', 'amber', true)]);

  const idWidth = Math.max(ID_WIDTH, ...tickets.filter((t) => t.numbered).map((t) => Array.from(t.id).length));
  const nameWidth = Math.max(0, ...tickets.map((t) => Array.from(t.name).length));
  for (const t of tickets) {
    const label = t.numbered ? `${t.id.padEnd(idWidth)} ${t.name}` : t.id;
    const mark = t.state === 'next' ? word('▶', 'amber') : word(' ');
    const row = [mark, word(' ')];
    if (t.numbered) row.push(word(t.id.padEnd(idWidth), t.state === 'next' ? 'sun' : null, t.state === 'next'), word(' '), word(t.name, null, t.state === 'next'));
    else row.push(word(label, null, t.state === 'next'));
    const tags = tagRuns(t);
    if (tags.length) row.push(word(' '.repeat(Math.max(2, nameWidth - Array.from(t.name).length + 10))), ...tags);
    rows.push(row);
  }
  const warnings = listOf(facts.warning);
  if (warnings.length) rows.push([], ...warnings.map((w) => [word('▲', 'amber'), word(` ${w}`)]));

  const live = facts.live === 'on'
    ? [word('on '), word('— file writes and shell commands drawn to stderr', 'muted')]
    : [word('off '), word('— add --live to watch', 'muted')];
  const dot = word('  ·  ', 'muted');
  const unlimited = (v, what) => (String(v).startsWith('$') || /m$/.test(String(v)) ? [word(v)] : [word(`${what} ${v}`)]);
  const [jsonl, log] = listOf(facts.logs);
  const sameDir = jsonl !== undefined && log !== undefined && jsonl.replace(/[^/\\]*$/, '') === log.replace(/[^/\\]*$/, '');
  rows.push(
    [],
    settingsRow(true, ['exec', [word(facts.exec ?? '')]], ['perms', [word(facts.perms ?? '')]]),
    settingsRow(false, ['model', [word(facts.model ?? '')]], ['effort', [word(facts.effort ?? '')]]),
    settingsRow(false, ['live', live], ['budgets', [
      ...unlimited(facts.cost ?? 'unlimited', 'cost'), dot, ...unlimited(facts.time ?? 'unlimited', 'time'), dot,
      word(`iterations ${facts.iterations ?? 'unlimited'}`),
    ]]),
    [word(' '.repeat(SETTINGS_INDENT)), word('logs', 'muted'), word(' '.repeat(SETTINGS_LABEL - 4)), word(jsonl ?? ''),
      ...(log === undefined ? [] : [word('  '), word('and', 'muted'), word('  '), word(sameDir ? log.replace(/^.*[\\/]/, '') : log)])],
    [],
  );

  const closing = [word('───', 'dim'), word(' '), word(DRYRUN_CLOSING, 'ok'), word(' '), word('─'.repeat(40), 'dim')];
  if (facts.stop !== undefined) {
    const stop = statusTicket(`todo\t${facts.stop}\thuman\t`);
    rows.push([
      word('■', 'error'), word(' would stop before ', 'muted'), word(stop.id, null, true), word(' '), ...tagRuns({ human: true }),
      word('  — no prompt would be sent' + (facts.handoff ? '; the handoff is ' : ''), 'muted'), ...(facts.handoff ? [word(facts.handoff)] : []),
    ], [], closing);
    return rows;
  }

  const lines = listOf(facts.prompt).map((l) => l.replace(/[\x00-\x08\x0a-\x1f\x7f]/g, '·'));
  rows.push([word('PROMPT', 'amber', true), word(' '), word(`for ${ticketId(facts.promptfor ?? '')}  ·  ${plural(lines.length, 'line', 'lines')}`, 'muted')]);
  const screen = Number(facts.screen) > 0 ? Number(facts.screen) : DEFAULT_SCREEN;
  const room = Math.max(PROMPT_ROWS_MIN, screen - rows.length - 2);
  const numberWidth = String(lines.length).length;
  for (const line of foldPrompt(lines, room)) {
    if (line === null) { rows.push([word(`${'⋮'.padStart(numberWidth)} │`, 'dim')]); continue; }
    const [n, text] = line;
    rows.push([word(`${String(n).padStart(numberWidth)} │ `, 'dim'), ...(text ? [promptLine(text)] : [])]);
  }
  rows.push(closing);
  return rows;
}

// --- run -----------------------------------------------------------------------------------

// `foreman run`'s header (3a): the figure standing by the dome at the left, the run's facts at the
// right, a rule under both. It is drawn when the run starts and again, a step higher, when a ticket
// lands. The figure is the design's own sprite. The dome is the sunrise's sky on a small grid
// (radius 8 around column 23 of 34, the horizon on pixel row 14) and the sun's height is a straight
// line through the three heights the design shows (4, 5 and 6 of 10), which is `2.25 f - 0.125` for
// a share f of the tickets done: it is below the horizon at the start and clear of it, whole, from
// 6 of 10 on.
const RUN_TEXT = 37;                // the facts start here, as the design has them
const RUN_MIN = RUN_TEXT + 49;      // room for `4 of 10 done  ·  6 to go  ·  07 is a HUMAN ticket`
const RUN_W = 34, RUN_R = 8, RUN_CX = 23, RUN_HORIZON = 14;
const RUN_RULE = 92;                // the design's rule is this wide, which is not the other scenes'
const RUN_FIGURE_COLOUR = '#3a2f26';
const RUN_FIGURE = [
  '............',
  '....FFr.....',
  '..FFFFFFr...',
  '....FFr.F...',
  '....FFr.Fr..',
  '.....F..F...',
  '...FFFFFr...',
  '..FFFFFFr...',
  '..F.FFFr....',
  '..F.FFFr....',
  '....FFFr....',
  '....F..F....',
  '....F..F....',
  '...Fr..Fr...',
];

// The figure and the dome with `done` of `total` tickets landed: eight rows of cells, the last of
// them the ground.
function runDome(done, total, tier, palette = thePalette()) {
  const share = total > 0 ? Math.min(Math.max(done, 0), total) / total : 0;
  const pixels = skyPixels({ w: RUN_W, r: RUN_R, cx: RUN_CX, s: 2.25 * share - 0.125, horizon: RUN_HORIZON, h: RUN_HORIZON });
  RUN_FIGURE.forEach((row, y) => Array.from(row).forEach((ch, x) => {
    if (ch !== '.') pixels[y][x] = ch === 'F' ? RUN_FIGURE_COLOUR : 'rust';
  }));
  pixels.push(Array(RUN_W).fill('earth'), Array(RUN_W).fill('night'));
  return halfBlocks(pixels, tier, palette);
}

// The facts, from foreman-loop.sh: `runid` and when it `started`, the `batch` (and its `name`), the
// `model` and `exec`, the budget as `iterations`, `cost` and `minutes` (each a number, or `unlimited`;
// `minutes` is left out when there is no time budget), `done` of `total`, the first `human` ticket
// still to do, and the ticket that has `landed` just now.
function runRows(facts, { tier, cols }) {
  const done = Number(facts.done) || 0;
  const total = Number(facts.total) || 0;
  const batch = facts.batch ?? '';
  const unlimited = (v) => v === undefined || v === '' || v === 'unlimited';
  const label = (name) => word(name.padEnd(6), 'muted');
  const dot = word('·', 'muted');

  const budget = [word(` ${unlimited(facts.iterations) ? 'unlimited iterations' : plural(Number(facts.iterations), 'iteration', 'iterations')}  `), dot];
  budget.push(word(`  ${unlimited(facts.cost) ? 'no cost limit' : `$${Number(facts.cost).toFixed(2)}`}`));
  if (!unlimited(facts.minutes)) budget.push(word('  '), dot, word(`  ${facts.minutes} min`));

  const count = [word(`${done} of ${total} done`, 'sun', true), word('  '), word(`·  ${Math.max(total - done, 0)} to go${facts.human ? '  ·' : ''}`, 'muted')];
  if (facts.human) count.push(word('  '), word(`${ticketId(facts.human)} is a HUMAN ticket`, 'amber'));

  const art = runDome(done, total, tier);
  const words = new Map([
    [0, [label('batch'), word(` ${facts.name ? `${batch} (${facts.name})` : batch}`)]],
    [1, [label('model'), word(` ${facts.model ?? ''}  `), word('·  exec', 'muted'), word(` ${facts.exec ?? ''}`)]],
    [2, [label('budget'), ...budget]],
    [4, count],
  ]);
  if (facts.landed) {
    words.set(5, [word(`↑ ${ticketId(facts.landed)} landed`, 'sun', true), word(`  ·  the sun climbs to ${done} of ${total}`, 'sun')]);
  }

  const head = [word('FOREMAN', 'amber', true), word('  '), ...(facts.runid ? [word(`run ${facts.runid}${facts.started ? `  ·  started ${facts.started}` : ''}`, 'muted')] : [])];
  const rows = [[], [word(' '.repeat(RUN_TEXT)), ...head]];
  art.forEach((row, i) => {
    if (!words.has(i)) { rows.push(row); return; }
    rows.push([...row, word(' '.repeat(Math.max(1, RUN_TEXT - runsWidth(row)))), ...words.get(i)]);
  });
  rows.push([word('▔'.repeat(Math.min(cols, RUN_RULE)), 'earth')]);
  return rows;
}

// --- order ---------------------------------------------------------------------------------

// `foreman order` is drawn in two goes, as init is, because the agent takes as long as it takes:
// `order-head` is the header, drawn before it starts (the spinner goes under it, in the shell), and
// `order` is what the agent left, drawn when it is done.
const ORDER_MIN = 80;
const ORDER_MOVED = 'moved';
const ORDER_LABEL_MIN = 12;    // a ticket's number and name are cut to this at the least, however narrow the screen

// The tickets of `after` that changed place. A ticket stayed if every longest run of tickets that
// both orders keep in the same relative order has it in; so a swapped pair are both moved (either
// could be the one that stayed), while a ticket taken to the front is moved alone, not everything it
// passed. A ticket that is in only one of the orders was added or dropped, and is not moved.
function movedTickets(before, after) {
  const had = new Set(before);
  const kept = new Set(after);
  const a = before.filter((t) => kept.has(t));
  const b = after.filter((t) => had.has(t));
  const lcs = (x, y) => {
    let prev = Array(y.length + 1).fill(0);
    for (const u of x) {
      const row = [0];
      for (let j = 0; j < y.length; j++) row.push(u === y[j] ? prev[j] + 1 : Math.max(prev[j + 1], row[j]));
      prev = row;
    }
    return prev[y.length];
  };
  const total = lcs(a, b);
  return b.filter((t) => lcs(a.filter((u) => u !== t), b.filter((u) => u !== t)) === total);
}

// The header: the small mark, the command, and what is being ordered and by which model. The
// `tickets` and the `model` are left out when the facts do not have them.
function orderHeadRows(facts) {
  const figures = [];
  if (facts.tickets !== undefined && Number.isFinite(Number(facts.tickets))) figures.push(plural(Number(facts.tickets), 'ticket', 'tickets'));
  if (facts.model) figures.push(facts.model);
  return [[], [
    word('▄█▄', 'amber'), word(' '), word('foreman order', null, true), word(' '), word('·', 'muted'), word(` ${facts.batch ?? ''}`),
    ...(figures.length ? [word(' '), word(`·  ${figures.join('  ·  ')}`, 'muted')] : []),
  ], []];
}

// The agent's ordering: how it went, one numbered line for each ticket in the order it left (the
// glyphs are a stake with a line down it; `moved` beside a ticket that changed place, HUMAN beside
// one a person does, and the loop stops there, CHECK beside one that checks another), the batch's
// warnings, and what to do next. The facts are the ones foreman-order.sh leaves for `foreman init`
// (`was`, `now`, `human`, `check`, `warning`, `cost`) and, to say how long it took, `seconds`, and
// for the next command the `batch` and how to `invoke` foreman.
function stakeRows(facts, { cols }) {
  const batch = facts.batch ?? '';
  const invoke = facts.invoke ?? 'foreman';
  const now = listOf(facts.now);
  const moved = new Set(movedTickets(listOf(facts.was), now));
  const humans = new Set(listOf(facts.human));
  const checks = new Map(listOf(facts.check).map((c) => c.split('\t')));

  const took = [];
  if (facts.seconds !== undefined && facts.seconds !== '') took.push(`in ${elapsedAndCost({ seconds: facts.seconds })[0]}`);
  if (facts.cost !== undefined && facts.cost !== '') took.push(`for ${elapsedAndCost({ cost: facts.cost })[0]}`);
  const rows = [[word('order.md', null, true), word('  '), word(['·  ordered', ...took].join(' '), 'muted')], []];

  const tickets = now.map((file) => ({ file, ...statusTicket(`todo\t${file}\t${humans.has(file) ? 'human' : ''}\t${checks.get(file) ?? ''}`), moved: moved.has(file) }));
  if (tickets.length) {
    const idWidth = Math.max(ID_WIDTH, ...tickets.filter((t) => t.numbered).map((t) => Array.from(t.id).length));
    const posWidth = Math.max(2, String(tickets.length).length);
    const labelOf = (t) => Array.from(t.numbered ? `${t.id.padEnd(idWidth)} ${t.name}` : t.id);
    // What follows a tag: the HUMAN or CHECK, and what it means for the loop.
    const tagsOf = (t) => {
      const said = [...(t.human ? ['the loop stops here'] : []), ...(t.checks ? [`checks ${t.checks}`] : [])];
      const tags = tagRuns(t);
      return tags.length ? [...tags, word('  '), word(said.join('  ·  '), 'muted')] : [];
    };
    const tagged = tickets.map(tagsOf);
    const tagWidth = Math.max(0, ...tagged.map(runsWidth));
    const start = 2 + 1 + 1 + posWidth + 2;    // where the number of a ticket starts
    const room = Math.max(ORDER_LABEL_MIN, cols - 1 - start - 2 - ORDER_MOVED.length - (tagWidth ? 2 + tagWidth : 0));
    const labels = tickets.map((t) => {
      const label = labelOf(t);
      return (label.length > room ? [...label.slice(0, room - 1), '…'] : label).join('');
    });
    const labelWidth = Math.max(...labels.map((l) => Array.from(l).length));
    tickets.forEach((t, i) => {
      const glyph = tickets.length === 1 ? '─' : i === 0 ? '┬' : i === tickets.length - 1 ? '└' : '├';
      const row = [word('  '), word(glyph, 'dim'), word(' '), word(String(i + 1).padStart(posWidth), 'muted'), word('  '), word(labels[i], null, t.moved)];
      if (t.moved || tagged[i].length) {
        row.push(word(' '.repeat(labelWidth - Array.from(labels[i]).length + 2)));
        row.push(t.moved ? word(ORDER_MOVED, 'muted') : word(' '.repeat(ORDER_MOVED.length)));
      }
      if (tagged[i].length) row.push(word('  '), ...tagged[i]);
      rows.push(row);
    });
    rows.push([]);
  }
  const warnings = listOf(facts.warning);
  if (warnings.length) rows.push(...warnings.map((w) => [word('▲', 'amber'), word(` ${w}`)]), []);
  rows.push([word('review it, then', 'muted'), word(' '), word(`${invoke} dry-run ${batch}`, 'amber')]);
  return rows;
}

// --- next ----------------------------------------------------------------------------------

// `foreman next --all`: a stake for each ticket along a row of ground, the one that is next standing
// tall, the labels under them, then the list (✓ done, ▶ next) and how it adds up. The stakes are
// where the work is driven in; a ticket not yet reached has a label and no stake. A batch wider than
// the screen wraps onto another row of stakes. `--count` is the same sum on one line.
const NEXT_PITCH = 6;        // columns from one stake to the next; the label under a stake is at most one short
const NEXT_MIN = 40;         // six stakes, which is as few as a row of them is cut to
const NEXT_LABEL_MIN = 12;   // a ticket's number and name are cut to this at the least, however narrow the screen
const NEXT_WORD = 'next';

// Runs set down at their columns (0-based), with blanks between.
function placed(parts) {
  const row = [];
  let at = 0;
  for (const [col, run] of parts) {
    if (col > at) row.push(word(' '.repeat(col - at)));
    row.push(run);
    at = col + Array.from(run.t).length;
  }
  return row;
}

// The rows of stakes for one run of tickets: the tall one's cap and two more rows if it is here, the
// stakes, the ground and the labels.
function stakeRowsFor(tickets) {
  const col = (i) => 2 + NEXT_PITCH * i;
  const colourOf = (t) => (t.state === 'done' ? 'amber' : 'rust');
  const staked = tickets.map((t, i) => [t, i]).filter(([t]) => t.state === 'done' || t.state === 'next');
  const rows = [];
  const tall = tickets.findIndex((t) => t.state === 'next');
  if (tall >= 0) {
    rows.push(placed([[col(tall) - 1, word('▄▄▄▄', 'rust')]]));
    rows.push(placed([[col(tall), word('██', 'rust')]]), placed([[col(tall), word('██', 'rust')]]));
  }
  rows.push(placed(staked.map(([t, i]) => [col(i), word('██', colourOf(t))])));
  rows.push([word('▀'.repeat(NEXT_PITCH * tickets.length + 2), 'earth')]);
  rows.push(placed(tickets.map((t, i) => [col(i), word(Array.from(t.id).slice(0, NEXT_PITCH - 1).join(''),
    t.state === 'done' ? 'ok' : t.state === 'next' ? 'rust' : 'muted')])));
  return rows;
}

function nextRows(facts, { cols }) {
  const tickets = listOf(facts.ticket).map(statusTicket);
  const yours = tickets.filter((t) => t.state !== 'done' && t.human).length;
  const driven = tickets.filter((t) => t.state === 'done').length;
  const rows = [[]];

  const perRow = Math.max(1, Math.floor((cols - 2) / NEXT_PITCH));
  for (let i = 0; i < tickets.length; i += perRow) rows.push(...stakeRowsFor(tickets.slice(i, i + perRow)), []);

  // The list. The tags (and `next` after them) stand in a column of their own, after the longest label.
  const idWidth = Math.max(ID_WIDTH, ...tickets.filter((t) => t.numbered).map((t) => Array.from(t.id).length));
  const labelOf = (t) => (t.numbered ? `${t.id.padEnd(idWidth)} ${t.name}` : t.id);
  const tagged = tickets.map((t) => {
    const tags = tagRuns(t);
    return t.state === 'next' ? [...tags, ...(tags.length ? [word('  ')] : []), word(NEXT_WORD, 'muted')] : tags;
  });
  const tagWidth = Math.max(0, ...tagged.map(runsWidth));
  const start = 2 + 1 + 1;    // where a label starts
  const room = Math.max(NEXT_LABEL_MIN, cols - 1 - start - (tagWidth ? 2 + tagWidth : 0));
  const labels = tickets.map((t) => {
    const label = Array.from(labelOf(t));
    return (label.length > room ? [...label.slice(0, room - 1), '…'] : label).join('');
  });
  const labelWidth = Math.max(0, ...labels.map((l) => Array.from(l).length));
  tickets.forEach((t, i) => {
    const mark = t.state === 'done' ? word('✓', 'ok') : t.state === 'next' ? word('▶', 'amber') : word(' ');
    const row = [word('  '), mark, word(' ')];
    if (t.state === 'done') row.push(word(labels[i], 'dim'));
    else if (t.state === 'next' && t.numbered) {
      row.push(word(labels[i].slice(0, idWidth), 'sun', true), word(labels[i].slice(idWidth), null, true));
    } else row.push(word(labels[i], null, t.state === 'next'));
    if (tagged[i].length) row.push(word(' '.repeat(labelWidth - Array.from(labels[i]).length + 2)), ...tagged[i]);
    rows.push(row);
  });
  if (tickets.length) rows.push([]);

  rows.push([
    word('  '), word(`${driven} driven`, 'ok'), word('  '), word('·', 'muted'), word('  '),
    ...(yours ? [word(`${yours} yours`, 'rust'), word('  '), word('·', 'muted'), word('  ')] : []),
    word(`${tickets.length - driven - yours} to go`),
  ], []);
  return rows;
}

// `foreman next --count`: how far along, on one line. The facts are `done` and `total`.
function nextCountRows(facts) {
  const done = Number(facts.done) || 0;
  const total = Number(facts.total) || 0;
  return [[
    word(String(done), null, true), word(' '), word('of', 'muted'), word(' '), word(String(total), null, true),
    word('  '), word('·', 'muted'), word('  '), word(`${done} driven`, 'ok'),
    word('  '), word('·', 'muted'), word('  '), word(`${Math.max(0, total - done)} to go`),
  ]];
}

// --- report --------------------------------------------------------------------------------

// `foreman report`: the bill up top (the mark beside the total cost, the counts, and a bar of how the
// iterations came out), then the ledger. The facts are numbers, which the scene words:
//   batch, command   the batch's name for the title; what to type to run another view (default
//                    `foreman report`, with the batch in it when the person named one)
//   mode             by-run (the default), by-ticket or failures
//   runs, iterations, minutes, cost, turns          the totals; no `runs` is a batch with none
//   landed, progressed, stalled, unproductive       the outcomes of the iterations
//   input, output, cache-read, cache-write          tokens
//   checkpoints, limit-hits, unreadable             what the totals also hold or leave out
//   run     id<TAB>iterations<TAB>landed<TAB>minutes<TAB>cost, one for each run
//   table   head|text<TAB>words, the tables of by-ticket and failures, which are words as they are
const REPORT_MIN = 84;
const REPORT_BAR = 28;        // the outcome bar's width, in cells
const REPORT_COST_BAR = 16;   // the widest cost bar's, for the dearest run
const REPORT_LABEL = 31;      // the ledger's first column, at least
const EIGHTHS = ' ▏▎▍▌▋▊▉█';

const whole = (v) => { const x = Math.round(Number(v)); return Number.isFinite(x) && x > 0 ? x : 0; };
const amount = (v) => { const x = Number(v); return Number.isFinite(x) && x > 0 ? x : 0; };
const money = (v) => `$${amount(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

// 41200 as 41.2k, 388000 as 388k, 12400000 as 12.4M: three digits, or two and a decimal below 100.
function compact(v) {
  const x = amount(v);
  const units = ['', 'k', 'M', 'G'];
  let unit = 0;
  let scaled = x;
  const rounded = (n) => (n < 100 ? Math.round(n * 10) / 10 : Math.round(n));
  while (unit < units.length - 1 && (unit === 0 ? scaled >= 1000 : rounded(scaled) >= 1000)) { scaled /= 1000; unit++; }
  return unit === 0 ? String(Math.round(scaled)) : `${rounded(scaled)}${units[unit]}`;
}

// Cells for each count, in proportion, summing to `cells`: the largest remainders take what the
// whole numbers leave, and an outcome that happened is never rounded away to nothing.
function apportion(counts, cells) {
  const total = counts.reduce((a, b) => a + b, 0);
  if (total <= 0) return counts.map(() => 0);
  const exact = counts.map((c) => (c * cells) / total);
  const out = exact.map(Math.floor);
  const order = exact.map((e, i) => [e - out[i], i]).sort((a, b) => b[0] - a[0] || a[1] - b[1]);
  for (let left = cells - out.reduce((a, b) => a + b, 0), k = 0; left > 0; left--, k++) out[order[k % order.length][1]]++;
  counts.forEach((c, i) => {
    if (c > 0 && out[i] === 0) { out[out.indexOf(Math.max(...out))]--; out[i] = 1; }
  });
  return out;
}

// A bar `value / most` of `width` cells long, to the eighth of a cell; at least an eighth for any cost.
function costBar(value, most, width) {
  if (!(value > 0) || !(most > 0)) return '';
  const eighths = Math.max(1, Math.floor((value / most) * width * 8));
  return '█'.repeat(Math.floor(eighths / 8)) + (eighths % 8 ? EIGHTHS[eighths % 8] : '');
}

const countOf = (n, one, many) => (n === 1 ? `1 ${one}` : `${n} ${many}`);
const rightAt = (text, width) => ' '.repeat(Math.max(0, width - chars(text))) + text;

function reportHead(facts, { tier, cols }) {
  const runs = whole(facts.runs);
  const iterations = whole(facts.iterations);
  const outcomes = [
    ['landed', whole(facts.landed), 'ok'], ['progressed', whole(facts.progressed), 'amber'],
    ['stalled', whole(facts.stalled), 'rust'], ['unproductive', whole(facts.unproductive), 'error'],
  ];
  // The title is the one line that can be longer than there is room for, by a long path: its front is cut.
  const lead = 'FOREMAN  what it cost  ';
  const room = Math.max(8, cols - TEXT_COLUMN - lead.length);
  const batch = Array.from(String(facts.batch ?? ''));
  const named = batch.length > room ? `…${batch.slice(batch.length - room + 1).join('')}` : batch.join('');
  const beside = [null, [word('FOREMAN', 'amber', true), word('  '), word('what it cost', 'muted'), word('  '), word(named)]];
  if (runs > 0) {
    const minutes = amount(facts.minutes).toFixed(1);
    beside.push([word(money(facts.cost), 'sun', true), word('  '),
      word(`over ${countOf(runs, 'run', 'runs')}  ·  ${countOf(iterations, 'iteration', 'iterations')}  ·  ${minutes} model-minutes`, 'muted')]);
    const cells = apportion(outcomes.map((o) => o[1]), REPORT_BAR);
    beside.push(cells.some((c) => c > 0)
      ? outcomes.map(([, , colour], i) => word('█'.repeat(cells[i]), colour)).filter((r) => r.t)
      : null);
    const legend = [];
    outcomes.forEach(([name, n, colour], i) => {
      if (n === 0 && (i === 1 || i === 2)) return;    // landed and unproductive are always said; the others only when they happened
      if (legend.length) legend.push(word('  '));
      legend.push(word(`${n} ${name}`, colour));
    });
    beside.push(legend);
  }
  return [[], ...withMark(tier, beside), rule(cols), []];
}

function reportTotal(facts) {
  const iterations = whole(facts.iterations);
  const label = (name) => [word('  '), word(name.padEnd(11), 'muted')];
  const billed = whole(facts.input) + whole(facts.output);
  const rows = [
    [word('TOTAL', 'amber', true)],
    [...label('tokens'), word(`in ${compact(facts.input)}  out ${compact(facts.output)}  cache-read ${compact(facts['cache-read'])}  cache-write ${compact(facts['cache-write'])}`)],
    [...label('billed'), word(`${compact(billed)} tokens`), word('  ·  ', 'muted'), word(`${whole(facts.turns).toLocaleString('en-US')} turns`)],
  ];
  if (iterations > 0) {
    rows.push([...label('average'), word(`${money(amount(facts.cost) / iterations)} and ${compact(billed / iterations)} billed tokens per iteration`)]);
  }
  const also = [];
  const checkpoints = whole(facts.checkpoints);
  const limits = whole(facts['limit-hits']);
  if (checkpoints) also.push(countOf(checkpoints, 'checkpoint turn', 'checkpoint turns'));
  if (limits) also.push(countOf(limits, 'limit hit', 'limit hits'));
  if (also.length) rows.push([...label('also'), word(also.join('  ·  '))]);
  const unreadable = whole(facts.unreadable);
  if (unreadable) rows.push([...label('skipped'), word(`${countOf(unreadable, 'unreadable line', 'unreadable lines')} in the run log`, 'amber')]);
  return rows;
}

// BY RUN, a row for each run with a bar of its cost, the dearest run's the longest.
function reportLedger(facts) {
  const runs = listOf(facts.run).map((r) => r.split('\t'));
  const label = Math.max(REPORT_LABEL, ...runs.map(([id]) => chars(id) + 4));
  const columns = (a, b, c, d) => `${rightAt(a, 5)}${rightAt(b, 8)}${rightAt(c, 10)}${rightAt(d, 10)}`;
  const rows = [[word('BY RUN'.padEnd(label), 'amber', true), word(columns('iters', 'landed', 'minutes', 'cost'), 'muted')]];
  const most = Math.max(0, ...runs.map((r) => amount(r[4])));
  for (const [id, iterations, landed, minutes, cost] of runs) {
    const bar = costBar(amount(cost), most, REPORT_COST_BAR);
    const row = [word(`  ${id}`.padEnd(label) + columns(String(whole(iterations)), String(whole(landed)), amount(minutes).toFixed(1), money(cost)))];
    if (bar) row.push(word('   '), word(bar, 'rust'));
    rows.push(row);
  }
  return rows;
}

// The other two views and how to ask for them, on a line, or a line each when they do not fit together.
function reportHint(facts, cols) {
  const command = facts.command || 'foreman report';
  const views = { 'by-run': ['by run', ''], 'by-ticket': ['by ticket', ' --by-ticket'], failures: ['what went wrong', ' --failures'] };
  const others = Object.keys(views).filter((m) => m !== (facts.mode || 'by-run')).map((m) => views[m]);
  const one = ([name, flag]) => [word(`${name}:`, 'muted'), word(` ${command}${flag}`)];
  const together = [...one(others[0]), word('   '), word('·   ', 'muted'), ...one(others[1])];
  return runsWidth(together) <= cols ? [together] : others.map(one);
}

function reportRows(facts, o) {
  const rows = reportHead(facts, o);
  if (whole(facts.runs) === 0) return rows;
  rows.push(...reportTotal(facts), []);
  if ((facts.mode || 'by-run') === 'by-run') rows.push(...reportLedger(facts));
  else for (const entry of listOf(facts.table)) {
    const tab = entry.indexOf('\t');
    const [kind, text] = tab < 0 ? [entry, ''] : [entry.slice(0, tab), entry.slice(tab + 1)];
    rows.push(kind === 'head' ? [word(text, 'amber', true)] : text === '' ? [] : [word(text)]);
  }
  rows.push([], ...reportHint(facts, o.cols), []);
  return rows;
}

// --- convert -------------------------------------------------------------------------------

// `foreman convert`: the sign repainted from RALPH to FOREMAN, then what changed. The sign is 22 cells
// wide with its posts at 4 and 17, and the tag the names are painted on is 20 of them; the words beside
// it start where the design puts them (23 on the tag's row, 25 beside the feet, 21 beside the posts).
//
// The facts are `project` and `home` (for the title), `dry` when nothing is being changed, and lists:
//   rename   from<TAB>to        a file renamed (or, in a dry run, to be): the new name is said by its name
//   rewrite  file<TAB>changes   a file whose text was (or would be) rewritten; the first three are named
//   delete   file               a file deleted
//   blocked  from<TAB>to        a rename that could not be done, `to` being there already
//   own      path               a file of the project's own with ralph in its name, kept
//   credit   N                  the lines kept as credit to the technique
//   mention  where<TAB>text     any other line that still says ralph
//   envfile  copied | exists    the credentials file: copied (or to be), or the new one was there already
//   var      OLD<TAB>NEW        a variable of the old name in the environment
//   sandbox  NAME               the old sandbox that may be left
//   windows  1                  to say how a variable is renamed there
// A project with none of rename, rewrite, delete or blocked has nothing to repaint.
const CONVERT_SIGN = 22;
const CONVERT_TAG = 20;
const CONVERT_POSTS = [4, 17];
const CONVERT_MIN = 86;       // the dry run's counts line is the widest the design's facts make
const CONVERT_LIST = 10;      // the most files, mentions and the like listed; the rest are counted
const CONVERT_MENTIONS = 5;

// The sign, five rows: its top edge, the tag with the names, its feet, its posts, its underside.
// `name` is what the tag says: RALPH struck through with FOREMAN painted on (`repainted`), RALPH as
// it still is (`unpainted`), or FOREMAN alone (`current`).
function convertSign(kind, tier) {
  const ink = { bold: true, fg: 'ink', bg: 'amber' };
  const cell = (t, fg, bg) => ({ t, style: { fg, ...(bg && { bg }) } });
  const tag = kind === 'repainted'
    ? [{ t: ' ', style: ink }, { t: 'RALPH', style: { ...ink, strike: true, fg: 'post' } }, { t: '   FOREMAN    ', style: ink }]
    : [{ t: ` ${kind === 'current' ? 'FOREMAN' : 'RALPH'}`.padEnd(CONVERT_TAG), style: ink }];
  const [a, b] = CONVERT_POSTS;
  return [
    [cell('▄'.repeat(CONVERT_SIGN), 'amber')],
    tag,
    [cell('▀'.repeat(a), 'amber'), cell('▄', 'post', 'amber'), cell('▀'.repeat(b - a - 1), 'amber'),
      cell('▄', 'post', 'amber'), cell('▀'.repeat(CONVERT_SIGN - b - 1), 'amber')],
    [word(' '.repeat(a)), cell('█', 'post'), word(' '.repeat(b - a - 1)), cell('█', 'post')],
    // 16 colours have no dark shade to draw the underside in: dim cannot be a block.
    tier === 16 ? [word(' '.repeat(CONVERT_SIGN))] : [cell('▀'.repeat(CONVERT_SIGN), 'earth')],
  ];
}

// Every list entry is two fields; the second may hold any text, tabs included (they are spaces here).
const convertPairs = (v) => listOf(v).map((e) => {
  const tab = e.indexOf('\t');
  return tab < 0 ? [e] : [e.slice(0, tab), e.slice(tab + 1).replace(/\t/g, ' ')];
});
const baseName = (f) => f.slice(f.lastIndexOf('/') + 1);

// A block of rows under a label (bold amber, padded to `width`); the rows after the first are indented.
function convertBlock(label, width, rows) {
  return rows.map((row, i) => [i === 0 ? word(label.padEnd(width), 'amber', true) : word(' '.repeat(width)), ...row]);
}

// `1 mention`, `4 mentions`; a number and what it counts.
const mentions = (n) => `${countOf(n, 'mention', 'mentions')} of the Ralph loop`;

function convertRows(facts, { tier, cols }) {
  const dry = facts.dry !== undefined && facts.dry !== '0';
  const renames = convertPairs(facts.rename);
  const rewrites = convertPairs(facts.rewrite).map(([f, n]) => [f, whole(n)]);
  const deletes = listOf(facts.delete);
  const blocked = convertPairs(facts.blocked);
  const own = listOf(facts.own);
  const credit = whole(facts.credit);
  const others = convertPairs(facts.mention);
  const vars = convertPairs(facts.var);
  const sandboxes = listOf(facts.sandbox);
  const env = facts.envfile;
  const done = renames.length + rewrites.length + deletes.length;
  const forYou = vars.length + sandboxes.length + blocked.length + (env === 'exists' ? 1 : 0);
  const repaint = done + blocked.length > 0;
  const width = dry ? 15 : 10;
  const more = (n) => [word(`… and ${n} more`, 'muted')];
  // The files, up to the most there is room for, and how many were left out.
  const listed = (entries, row) => [...entries.slice(0, CONVERT_LIST).map(row), ...(entries.length > CONVERT_LIST ? [more(entries.length - CONVERT_LIST)] : [])];
  const dot = [word('  '), word('·', 'muted'), word('  ')];

  // The sign and the words beside it.
  const sign = convertSign(!repaint ? 'current' : dry ? 'unpainted' : 'repainted', tier);
  const counts = [];
  if (repaint) {
    const parts = [
      [renames.length, dry ? (n) => `${n} to rename` : (n) => `${n} renamed`, 'ok'],
      [rewrites.length, dry ? (n) => `${plural(n, 'file', 'files')} to rewrite` : (n) => `${plural(n, 'file', 'files')} rewritten`, 'ok'],
      [deletes.length, dry ? (n) => `${n} to delete` : (n) => `${n} deleted`, 'ok'],
      [forYou, (n) => `${n} for you`, 'amber'],
    ].filter(([n]) => n > 0);
    parts.forEach(([n, say, colour], i) => counts.push(...(i ? dot : []), word(say(n), colour)));
  } else if (forYou > 0) {
    counts.push(word(`${forYou} for you`, 'amber'));
  }
  // The title is the one row that is long by the project's path alone: its front is cut when there is no room.
  const says = !repaint ? 'nothing to repaint' : dry ? 'would repaint the sign' : 'repaints the sign';
  const project = Array.from(tilde(facts.project, facts.home));
  const room = Math.max(8, cols - CONVERT_TAG - 3 - chars(`FOREMAN  ${says}  `));
  const title = [word('FOREMAN', 'amber', true), word('  '), word(says, 'muted'), word('  '),
    word(project.length > room ? `…${project.slice(project.length - room + 1).join('')}` : project.join(''))];
  const second = repaint ? 'ralph → foreman, in this repository and on this machine' : 'the project already speaks foreman';
  const beside = [null, [word(' '.repeat(23 - CONVERT_TAG)), ...title], [word('   '), word(second, 'muted')], counts.length ? [word('   '), ...counts] : null, null];
  const rows = [[], ...sign.map((row, i) => (beside[i] ? [...row, ...beside[i]] : row)), []];

  // What was done: renamed, rewritten, deleted, and the renames that could not be.
  const blocks = [];
  const changed = [];
  if (renames.length) {
    changed.push(...convertBlock(dry ? 'WOULD RENAME' : 'RENAMED', width, listed(renames, ([from, to]) => {
      const dir = from.slice(0, from.lastIndexOf('/') + 1);
      return [word(dir), word(baseName(from), 'dim'), word(' '), word('→', 'muted'), word(' '), word(baseName(to), 'ok')];
    })));
  }
  if (rewrites.length) {
    // The first three files are named, in the order given (the busiest first is the caller's to say),
    // fewer when the line would be longer than the screen; the others are counted, with all the changes.
    const total = rewrites.reduce((n, [, c]) => n + c, 0);
    const between = [word('  ·  ')];
    const row = (shown) => {
      const out = [];
      rewrites.slice(0, shown).forEach(([f, c], i) => out.push(...(i ? between : []), word(f), word(' '), word(String(c), 'muted')));
      if (shown < rewrites.length) out.push(...between, word(`${rewrites.length - shown} more, ${plural(total, 'change', 'changes')}`, 'muted'));
      return out;
    };
    let shown = Math.min(3, rewrites.length);
    while (shown > 1 && width + runsWidth(row(shown)) > cols) shown--;
    changed.push(...convertBlock(dry ? 'WOULD REWRITE' : 'REWROTE', width, [row(shown)]));
  }
  if (deletes.length) {
    changed.push(...convertBlock(dry ? 'WOULD DELETE' : 'DELETED', width, listed(deletes, (f) => [word(f), word('  '), word('rebuilt on the next iteration', 'muted')])));
  }
  if (blocked.length) {
    changed.push(...convertBlock('LEFT', width, listed(blocked, ([from, to]) =>
      [word(from), word('  '), word(`${baseName(to)} is already there — merge the two by hand, then delete the old one`, 'amber')])));
  }
  if (changed.length) blocks.push(changed);

  // What is kept: credit to the technique and the project's own files, then any other mention to look over.
  if (own.length || credit || others.length) {
    const things = [credit && 'credit to the technique', own.length && 'your own files named ralph'].filter(Boolean);
    const heading = things.length ? things.join(', and ') : 'mentions to look over';
    const room = (where) => Math.max(8, cols - width - chars(where) - 2);
    const lines = [[word(`${heading}:`, 'muted')]];
    own.slice(0, CONVERT_LIST).forEach((f, i) => lines.push(i === 0
      ? [word(f), word('  '), word('·', 'muted'), word('  rename with git mv if you want to', 'muted')]
      : [word(f)]));
    if (own.length > CONVERT_LIST) lines.push(more(own.length - CONVERT_LIST));
    if (credit) lines.push([word(mentions(credit), 'muted')]);
    if (others.length && things.length) lines.push([word('mentions to look over:', 'muted')]);
    others.slice(0, CONVERT_MENTIONS).forEach(([where, text = '']) => {
      const t = Array.from(text);
      lines.push([word(where, 'muted'), word('  '), word(t.length > room(where) ? `${t.slice(0, room(where) - 1).join('')}…` : text)]);
    });
    if (others.length > CONVERT_MENTIONS) lines.push(more(others.length - CONVERT_MENTIONS));
    blocks.push(convertBlock(dry ? 'WOULD KEEP' : 'KEPT', width, lines));
  }

  // This machine: the credentials copied, and what only the person can do.
  const machine = [];
  // A row with a ▲, and under it, when it has more to say than fits beside the mark, the rest.
  const todo = (text, then) => {
    machine.push([word('  '), word('▲', 'amber'), word(' '), word(text)]);
    if (then) machine.push([word('    '), word(then)]);
  };
  if (env === 'copied') {
    machine.push([word('  '), word('✓', 'ok'), word(' '), word(`${dry ? 'would copy ' : ''}~/.config/ralph/env `), word('→', 'muted'),
      word(' ~/.config/foreman/env  '), word('(the old one stays)', 'muted')]);
  } else if (env === 'exists') {
    todo('~/.config/ralph/env is no longer read (~/.config/foreman/env is)', 'delete it once nothing in it is missing from the new one');
  }
  for (const [old, neu = old] of vars) {
    if (facts.windows === undefined) todo(`${old} is set in your shell — rename it to ${neu}`);
    else todo(`${old} is set in your environment`, `setx ${neu} "<its value>", then reg delete HKCU\\Environment /v ${old} /f`);
  }
  for (const name of sandboxes) todo(`the old sandbox ${name} may be left — sbx rm ${name}`);
  if (machine.length) blocks.push([[word('THIS MACHINE', 'amber', true)], ...machine]);

  if (repaint && done > 0) {
    blocks.push([dry
      ? [word('nothing was changed.  run it without ', 'muted'), word('--dry-run', 'amber'), word(' to make these changes.', 'muted')]
      : [word('nothing is committed.', 'muted'), word('  '), word('git diff', 'amber'), word(', then commit.', 'muted')]]);
  }

  if (blocks.length) {
    rows.push(rule(cols), []);
    blocks.forEach((block, i) => rows.push(...block, ...(i < blocks.length - 1 ? [[]] : [])));
    rows.push([]);
  }
  return rows;
}

// --- the scenes ----------------------------------------------------------------------------

// --- doctor --------------------------------------------------------------------------------

// `foreman doctor`: the site inspection. A box of what was checked, and on a terminal an inspector
// who runs across a track above it while the checks come in, then blows a whistle and plants a red
// sign, or hops and gives a thumbs up beside a big green check.
//
// The facts are `repo`, `home`, `date` and `rev` for the title, `expect` (how many checks the shell
// thinks there are, for the bar), a `check` for each check, in the order it finished, and the
// `advice` for after the verdict. A `check` is `section<TAB>state<TAB>text[<TAB>detail]`:
//   section  machine, repository, skill, batches or rename
//   state    ok, miss (needs you), fix (a miss that `doctor --fix` writes), stale (worth a look, not a
//            failure), info (a line with no mark) or note (more words for the check before it)
//   detail   what goes in the column after a batch's name
// and an `advice` is `label<TAB>command`.
const DOCTOR_W = 80;
const DOCTOR_MIN = DOCTOR_W;
const DOCTOR_LEFT = 38;       // the inner width of the left column; the right takes the rest
const DOCTOR_DETAIL = 32;     // a detail starts this far in from its text, at least
const DOCTOR_EXPECT = 12;     // the checks the design has, when the shell has not said how many
const DOCTOR_SIGN = 17;       // the verdict's sign: its width, borders included
const DOCTOR_SIGN_AT = 55;    // and where it starts, in the box's inner width
const DOCTOR_BAR = 24;
const DOCTOR_MARKS = { ok: ['■', 'ok'], fix: ['▲', 'amber'], miss: ['✗', 'error'], stale: ['!', 'amber'] };
const DOCTOR_HEADS = {
  machine: 'MACHINE', repository: 'REPOSITORY', skill: 'SKILL', batches: 'BATCHES', rename: 'FROM BEFORE THE RENAME TO FOREMAN',
};

const chars = (t) => Array.from(t).length;

// Words to lines of at most `width` characters: broken at spaces (not those inside double quotes),
// and in a word longer than a line after a `/` or where the line ends. Always at least one line.
function wrapWords(text, width) {
  const lines = [];
  let line = '';
  // (a space inside double quotes does not break the line: a quoted argument is copied whole)
  for (const piece of text.split(/ (?=(?:[^"]*"[^"]*")*[^"]*$)/)) {
    let rest = Array.from(piece);
    if (line !== '' && chars(line) + 1 + rest.length <= width) { line += ` ${piece}`; continue; }
    if (line !== '') { lines.push(line); line = ''; }
    while (rest.length > width) {
      // after a `/` in the second half of the line, if there is one: a path breaks between its names
      const slash = rest.slice(0, width).lastIndexOf('/');
      const at = slash >= width / 2 ? slash + 1 : width;
      lines.push(rest.slice(0, at).join(''));
      rest = rest.slice(at);
    }
    line = rest.join('');
  }
  lines.push(line);
  return lines;
}

// The checks in a facts object, each with the notes that follow it.
function doctorChecks(facts) {
  const checks = [];
  for (const fact of listOf(facts.check)) {
    const [section = '', state = '', text = '', detail = ''] = fact.split('\t');
    if (state === 'note') {
      if (checks.length) checks[checks.length - 1].notes.push(text);
      continue;
    }
    checks.push({ section, state, text, detail, notes: [] });
  }
  return checks;
}

// A check as the rows of a cell `width` wide: the mark and the first line of its words, then what
// does not fit on it and its notes, under the words. Only the mark is coloured.
function checkRows(check, width) {
  const room = width - 2;
  const own = [];
  if (check.detail) {
    const gap = Math.max(2, DOCTOR_DETAIL - chars(check.text));
    if (chars(check.text) + gap + chars(check.detail) <= room) own.push(check.text + ' '.repeat(gap) + check.detail);
    else own.push(...wrapWords(check.text, room), ...wrapWords(check.detail, room));
  } else {
    own.push(...wrapWords(check.text, room));
  }
  const mark = DOCTOR_MARKS[check.state];
  const rows = own.map((t, i) => (i === 0 && mark ? [word(mark[0], mark[1]), word(' '), word(t)] : [word('  '), word(t)]));
  for (const note of check.notes) for (const t of wrapWords(note, room)) rows.push([word('  '), word(t)]);
  return rows;
}

const padded = (runs, width) => [...runs, word(' '.repeat(Math.max(0, width - runsWidth(runs))))];

// What the title says after the name: which repository, when and which build. The place is cut at
// its left end if it does not fit.
function doctorMeta(facts) {
  const sep = '  ·  ';
  const tail = [facts.date, facts.rev ? `foreman ${facts.rev}` : ''].filter((t) => t);
  const room = DOCTOR_W - 2 - 2 - chars('SITE INSPECTION') - 3 - 1 - chars(tail.map((t) => sep + t).join(''));
  const where = tilde(facts.repo, facts.home) || '';
  const place = chars(where) <= room ? where : `…${Array.from(where).slice(-(room - 1)).join('')}`;
  return [place, ...tail].filter((t) => t !== '').join(sep);
}

// The verdict's sign: a box in the verdict's colour, four rows high.
function doctorSign(good, second) {
  const inner = DOCTOR_SIGN - 2;
  const lines = good ? ['PASSED', 'ready to run'] : ['NOT PASSED', second];
  const fit = (t, i) => (good || i === 0 ? ' '.repeat(Math.floor((inner - chars(t)) / 2)) + t : `  ${t}`).padEnd(inner);
  const sign = (t) => [word(t, good ? 'ok' : 'error', true)];
  return [
    sign(`┌${'─'.repeat(inner)}┐`), sign(`│${fit(lines[0], 0)}│`), sign(`│${fit(lines[1], 1)}│`), sign(`└${'─'.repeat(inner)}┘`),
  ];
}

// The box for the checks so far. While the inspection goes on its last rows are the bar; `final`
// replaces them with the verdict.
function doctorBox(facts, checks, { final }) {
  const border = (t) => word(t, 'amber');
  const inner = DOCTOR_W - 2;
  const rightW = inner - DOCTOR_LEFT - 1;
  const line = (runs) => [border('║'), ...padded(runs, inner), border('║')];
  const rule = (open, mid, close) => [border(`${open}${'─'.repeat(DOCTOR_LEFT)}${mid}${'─'.repeat(rightW)}${close}`)];
  const across = [border(`╟${'─'.repeat(inner)}╢`)];
  const inSection = (name) => checks.filter((c) => c.section === name);
  // Words stop a column short of the border, which is what the design's longest line does too.
  const cell = (name, width) => [[word(DOCTOR_HEADS[name], 'muted')], ...inSection(name).flatMap((c) => checkRows(c, width - 3))];

  const rows = [[border(`╔${'═'.repeat(inner)}╗`)]];
  rows.push(line([word('  '), word('SITE INSPECTION', 'amber', true), word('   '), word(doctorMeta(facts), 'muted')]));
  rows.push(rule('╟', '┬', '╢'));
  const left = cell('machine', DOCTOR_LEFT);
  const right = cell('repository', rightW);
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    rows.push([
      border('║'), word('  '), ...padded(left[i] || [], DOCTOR_LEFT - 2), border('│'), word('  '), ...padded(right[i] || [], rightW - 2), border('║'),
    ]);
  }
  rows.push(rule('╟', '┴', '╢'));
  const wide = (name) => {
    for (const r of cell(name, inner - 2)) rows.push(line([word('  '), ...r]));
    rows.push(across);
  };
  if (inSection('skill').length) wide('skill');
  wide('batches');
  if (inSection('rename').length) wide('rename');

  const real = checks.filter((c) => c.state !== 'info');
  if (!final) {
    const expect = Math.max(Number(facts.expect) || DOCTOR_EXPECT, real.length);
    const filled = Math.floor((DOCTOR_BAR * real.length) / expect);
    rows.push(line([]));
    rows.push(line([
      word('  '), word('inspecting', 'sun', true), word('  '), word(`${String(real.length).padStart(String(expect).length)} of ${expect}`, 'muted'),
      word('   '), word('█'.repeat(filled), 'amber'), word('░'.repeat(DOCTOR_BAR - filled), 'dim'),
    ]));
    rows.push(line([]), line([]));
  } else {
    const count = (state) => real.filter((c) => c.state === state).length;
    const [fixable, needed, stale] = [count('fix'), count('miss'), count('stale')];
    const good = fixable + needed === 0;
    const legend = [];
    if (count('ok')) legend.push([word('■', 'ok'), word(' '), word('passed', 'muted')]);
    if (fixable) legend.push([word('▲', 'amber'), word(' '), word('--fix can do it', 'muted')]);
    if (needed) legend.push([word('✗', 'error'), word(' '), word('needs you', 'muted')]);
    if (stale) legend.push([word('!', 'amber'), word(' '), word(good ? 'out of date' : 'stale', 'muted')]);
    const first = good && !stale
      ? [word('■', 'ok'), word(' '), word(`all ${plural(real.length, 'check', 'checks')} passed`, 'muted')]
      : legend.flatMap((l, i) => (i ? [word('  '), ...l] : l));
    const advice = listOf(facts.advice).map((a) => a.split('\t'));
    const side = [first, [], ...advice.map(([label = '', command = '']) => [word(label.padEnd(5), 'muted'), word(` ${command}`)])];
    const sign = doctorSign(good, needed ? plural(needed, 'blocker', 'blockers') : `${fixable} to fix`);
    for (let i = 0; i < 4; i++) {
      rows.push(line([word('  '), ...padded(side[i] || [], DOCTOR_SIGN_AT - 2), ...sign[i]]));
    }
  }
  rows.push([border(`╚${'═'.repeat(inner)}╝`)]);
  return rows;
}

// --- the inspector -------------------------------------------------------------------------

// DoctorInspect's track, ported from the canvas: a ground and an inspector 14 pixels tall, on a grid
// 80 pixels across and 24 high, so twelve rows of text. `t` is the tick, 70ms of it: the run across
// and back takes RUN of them, then two of a breath, then the verdict. H is his hat, F face, B jacket,
// W the pad he carries, P trousers, K boots, E eyes, G the whistle. The side poses are 10 wide and
// face right; the front ones are 12.
const INSPECTOR_BODY = ['...HHH....', '..HHHHH...', '..HHHHHHH.', '...FFF....', '...FFFF...', '....F.....', '..BBBB.WW.', '.BBBBBBWW.', '..BBBB.WW.', '..BBBB....', '..PPPP....'];
const INSPECTOR_WHISTLE = ['...HHH....', '..HHHHH...', '..HHHHHHH.', '...FFF....', '...FFFFGG.', '....F.BB..', '..BBBBB...', 'BBBBBB....', '..BBBB....', '..BBBB....', '..PPPP....'];
const INSPECTOR_PLANT = ['...HHH....', '..HHHHH...', '..HHHHHHH.', '...FFF....', '...FFFF...', '....F...F.', '..BBBBBBB.', '.BBBBB....', '..BBBB....', '..BBBB....', '..PPPP....'];
const INSPECTOR_FRONT = ['....HHHH....', '...HHHHHH...', '..HHHHHHHH..', '...FFFFFF...', '...FEFFEF...', '....FFFF....', '..BBBBBBBB..', '.BBBBBBBBBB.', '.B.BBBBBB.B.', '.F.BBBBBB.F.', '...PPPPPP...'];
const INSPECTOR_THUMB = ['....HHHH....', '...HHHHHH.F.', '..HHHHHHHHF.', '...FFFFFF.FF', '...FEFFEF.FF', '....FEEF..B.', '..BBBBBBBBB.', '.BBBBBBBBB..', '.B.BBBBBB...', '.F.BBBBBB...', '...PPPPPP...'];
const INSPECTOR_LEGS = {
  a: ['.PP..PP...', 'PP....PP..', 'KK.....KK.'],
  b: ['...PPP....', '...P.P....', '..KK.KK...'],
  stand: ['...P.P....', '...P.P....', '..KK.KK...'],
  fstand: ['...PP..PP...', '...PP..PP...', '..KKK..KKK..'],
  ftuck: ['...PPPPPP...', '..PP....PP..', '..KK....KK..'],
};
const INSPECTOR_PAL = { H: 'amber', F: '#e8c9a0', B: 'rust', W: 'text', P: '#7a7268', K: 'post', S: '#9cc7e8', E: '#2a221c', G: 'muted' };
const TRACK_W = 80, TRACK_H = 24, TRACK_GROUND = 22, TRACK_Y0 = TRACK_GROUND - 14;
const RUN = 46;               // ticks to run across and back
const TRACK_SPARK = 'sun';
const TRACK_SIGN = { fill: 'error', edge: '#a84c45', post: 'post', text: ' NOT PASSED ' };
const TRACK_CHECK = { c: 'ok', shade: '#3f6a3f', path: [[53, 13], [59, 19], [73, 5]] };
// The tick the verdict is over on, and he rests on: 22 or 27 ticks after the run, about 1.5s.
const DOCTOR_VERDICT = { issues: 21, good: 26 };

// The pixels of one tick, and the words laid over them.
function trackScene(t, good) {
  const p = Array.from({ length: TRACK_H }, () => Array(TRACK_W).fill(null));
  const texts = [];
  const dot = (x, y, c) => { if (x >= 0 && x < TRACK_W && y >= 0 && y < TRACK_GROUND) p[y][x] = c; };
  // A pose and its legs at (x, y); `lift` raises the hat clear of his head, as a startled cartoon's does.
  const sprite = (top, legs, x, y, flip, lift) => {
    top.concat(INSPECTOR_LEGS[legs]).forEach((row, j) => Array.from(row).forEach((ch, i) => {
      if (ch !== '.') dot(flip ? x + row.length - 1 - i : x + i, y + j - (lift && j < 3 ? lift : 0), INSPECTOR_PAL[ch]);
    }));
  };
  const plus = (x, y, n) => {
    dot(x, y, 'text');
    for (let k = 1; k <= n; k++) for (const [dx, dy] of [[k, 0], [-k, 0], [0, k], [0, -k]]) dot(x + dx, y + dy, TRACK_SPARK);
  };
  const Y0 = TRACK_Y0;
  const e = t - RUN;

  // The run across and back, sweating, then a breath before the verdict.
  const running = () => {
    let x = 35, dir = 1, legs = 'stand';
    if (t < RUN) {
      const back = t >= RUN / 2;
      x = back ? 67 - 3 * (t - RUN / 2) : 1 + 3 * t;
      dir = back ? -1 : 1;
      legs = Math.floor(t / 2) % 2 ? 'a' : 'b';
    }
    sprite(INSPECTOR_BODY, legs, x, Y0, dir < 0);
    const ph = Math.floor(t / 2) % 3, behind = dir > 0 ? x - 1 : x + 10;
    const drops = t < RUN
      ? [[behind - dir * ph, 1 + ph], [behind - dir * (ph + 2), 3 + ph]]
      : [[x + 1 + (ph % 2), ph % 2 ? 0 : 1], [x - 1, 3 + (ph % 2)]];
    for (const [dx, dy] of drops) if (p[Y0 + dy] && !p[Y0 + dy][dx]) dot(dx, Y0 + dy, INSPECTOR_PAL.S);
  };

  // NOT PASSED: a startled whistle, a jump back through the air, then he carries a red sign up and
  // drives it in.
  const JUMP = [2, 4, 5, 6, 6, 5, 3, 1];
  const failed = () => {
    const tweet = (x, y) => {
      const m = y + 4, n = e % 2 ? 2 : 3;
      for (let k = 1; k <= n; k++) { dot(x + 9 + k, m, TRACK_SPARK); dot(x + 9 + k, m - 1 - k, TRACK_SPARK); dot(x + 9 + k, m + 1 + k, TRACK_SPARK); }
      texts.push({ row: m >> 1, col: x + 15, t: 'TWEEEET!', fg: 'sun', bold: true });
    };
    if (e === 2) {
      sprite(INSPECTOR_WHISTLE, 'stand', 35, Y0);
      tweet(35, Y0);
      texts.push({ row: (Y0 >> 1) - 2, col: 39, t: '!', fg: 'error', bold: true });
    } else if (e <= 10) {
      const i = e - 3, x = 34 - i, y = Y0 - JUMP[i];
      sprite(INSPECTOR_WHISTLE, 'a', x, y, false, i >= 2 && i <= 5 ? 1 : 0);
      tweet(x, y);
      for (let k = 0; k < 3; k++) dot(x + 11 + k, y + 13 - k, 'dim');
    } else if (e <= 13) {
      sprite(INSPECTOR_WHISTLE, 'stand', 27, Y0);
      if (e < 13) tweet(27, Y0);
    } else {
      // Carried with the board over his head, two steps forward, then driven down until it stands on its own.
      const x = e < 16 ? 27 + 3 * (e - 14) : 33, px = 42, holding = e < 21;
      const by = e < 18 ? 0 : e === 18 ? 4 : 6, sx = holding ? x + 9 : px;
      for (let y = by + 6; y < TRACK_GROUND && y <= by + 17; y++) dot(sx, y, TRACK_SIGN.post);
      for (let y = by; y < by + 6; y++) for (let xx = sx - 2; xx <= sx + 11; xx++) dot(xx, y, y === by || y === by + 5 ? TRACK_SIGN.edge : TRACK_SIGN.fill);
      texts.push({ row: (by + 2) >> 1, col: sx - 1, t: TRACK_SIGN.text, fg: 'ink', bg: TRACK_SIGN.fill, bold: true });
      if (holding) sprite(INSPECTOR_PLANT, e < 16 ? (e % 2 ? 'b' : 'a') : 'stand', x, Y0);
      else sprite(INSPECTOR_BODY, 'stand', 29, Y0);
      if (e === 19 || e === 20) {
        const s = e - 18;
        for (const dx of [-2 - s, -1 - s, 1 + s, 2 + s]) dot(px + dx, TRACK_GROUND - 1 - (Math.abs(dx) > 2 ? 1 : 0), 'dim');
      }
    }
  };

  // PASSED: he turns to face you, hops, lands with a thumbs up, and a big green check draws itself
  // beside him.
  const HOP = [2, 4, 5, 5, 4, 2];
  const passed = () => {
    if (e === 2) { sprite(INSPECTOR_FRONT, 'fstand', 34, Y0); return; }
    if (e <= 8) { sprite(INSPECTOR_FRONT, 'ftuck', 34, Y0 - HOP[e - 3]); return; }
    sprite(INSPECTOR_THUMB, 'fstand', 34, Y0);
    if (e <= 12) plus(46, Y0 - 1, e === 10 || e === 12 ? 1 : 2);
    const pts = TRACK_CHECK.path, seg = [];
    let total = 0;
    for (let k = 1; k < pts.length; k++) {
      const l = Math.hypot(pts[k][0] - pts[k - 1][0], pts[k][1] - pts[k - 1][1]);
      seg.push(l);
      total += l;
    }
    const want = total * Math.min(1, (e - 8) / 8);
    for (const [c, off] of [[TRACK_CHECK.shade, 1], [TRACK_CHECK.c, 0]]) {
      let gone = 0;
      for (let k = 0; k < seg.length && gone < want; k++) {
        for (let d = 0; d <= Math.min(seg[k], want - gone); d += 0.5) {
          const f = d / seg[k];
          const cx = Math.round(pts[k][0] + (pts[k + 1][0] - pts[k][0]) * f);
          const cy = Math.round(pts[k][1] + (pts[k + 1][1] - pts[k][1]) * f);
          for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) dot(cx + dx + off, cy + dy + off, c);
        }
        gone += seg[k];
      }
    }
    if (e >= 17 && e <= 26) [[77, 3], [49, 8], [76, 15]].forEach(([x, y], k) => { if ((e + k) % 3) plus(x, y, ((e + k) % 3) - 1); });
  };

  if (e < 2) running();
  else if (good) passed();
  else failed();
  for (let x = 0; x < TRACK_W; x++) p[TRACK_GROUND][x] = 'earth';
  return { pixels: p, texts };
}

// The track at tick t, as the twelve rows of text it is.
function trackRows(t, good, tier) {
  const { pixels, texts } = trackScene(t, good);
  return halfBlocks(pixels, tier, thePalette(), texts.map(({ row, col, ...rest }) => ({ x: col, y: row * 2, ...rest })));
}

// The real checks of a facts object: what the bar counts and the verdict is about.
const doctorReal = (checks) => checks.filter((c) => c.state !== 'info');
const doctorGood = (checks) => !doctorReal(checks).some((c) => c.state === 'miss' || c.state === 'fix');

// One frame: the track over the box, and under the box a line saying so while the inspection goes
// on. From the tick after the run's breath the box is the verdict.
function doctorFrame(facts, checks, { t, tier, good = doctorGood(checks) }) {
  const final = t >= RUN + 2;
  return [
    ...trackRows(t, good, tier), [],
    ...doctorBox(facts, checks, { final }),
    final ? [] : [word('inspecting…', 'muted')],
  ];
}

// How many of `total` checks the box has at tick t when they all arrive evenly across the run, which
// is how one frame is asked for with all the facts in hand (`--t`).
const doctorShownAt = (t, total) => (t >= RUN - 2 ? total : Math.min(total, Math.floor((t * total) / (RUN - 2))));

// The frame at tick t of a doctor's facts, all of them in hand: the box has the share of its checks the
// run has got to.
function doctorTickFrame(facts, t, tier) {
  const checks = doctorChecks(facts);
  const real = doctorReal(checks);
  const shown = new Set(real.slice(0, doctorShownAt(t, real.length)));
  return doctorFrame(facts, checks.filter((c) => c.state === 'info' || shown.has(c)), { t, tier, good: doctorGood(checks) });
}

// Where the inspector is on the next tick, given how many checks are in, how many are expected and
// whether that is all. He runs as far as the checks have got (a share of the run each), no more than
// INSPECTOR_STEP ticks at a time, so a batch of checks that finishes at once does not teleport him;
// when they are over he runs on to the end of the run, then takes the breath and the verdict a tick
// at a time. The run lasts as long as the checks, and no shorter than a few ticks.
const INSPECTOR_STEP = 4;
function inspectorStep(t, { done, expect, ended }) {
  const target = ended ? RUN - 1 : Math.min(RUN - 2, Math.floor(((RUN - 2) * done) / Math.max(1, expect)));
  if (t < target) return Math.min(target, t + INSPECTOR_STEP);
  return ended && t >= RUN - 1 ? t + 1 : t;
}

// The doctor's drawing as it happens. Facts arrive on `input` a line at a time, as the shell finishes
// each check; on a terminal the frame is drawn in place on every tick, the inspector running as the
// checks arrive, and when the input ends the verdict plays and the last frame stays. Without a terminal
// to play on (`animate` false), or one too short for the frame, there is no animation: the box is
// drawn once, when the input ends. The cursor is hidden while it plays and shown on every way out.
// Resolves with 'done' or 'interrupted' (a signal: the screen is left as it is).
function playDoctor({ input, out, tier, cols, rows = 0, animate = true, stepMs = 70, signals = process }) {
  return new Promise((resolve, reject) => {
    let text = '';           // what has been read, up to its last whole line
    let partial = '';        // and the start of the next
    let ended = false;
    let settled = false;
    let hidden = false;
    let still = !animate;    // the box alone, when the input ends
    let t = 0, height = 0, ticks = 0, started = 0, timer = null;

    const lines = (s) => s.split('\n').length - 1;
    const finish = (how, error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      for (const sig of STOP_SIGNALS) signals.removeListener(sig, onSignal);
      input.removeListener('data', onData);
      input.removeListener('end', onEnd);
      input.removeListener('error', onEnd);
      if (hidden) { try { out.write(SHOW_CURSOR); } catch { /* nowhere to write to */ } }
      if (error) reject(error); else resolve(how);
    };
    const attempt = (fn) => { try { fn(); } catch (e) { finish(null, e); } };
    const facts = () => parseFacts(text);

    const drawFrame = (f, checks) => {
      const frame = encode(doctorFrame(f, checks, { t, tier }), tier, thePalette(), { erase: cols }) + `${ESC}[J`;
      if (rows && lines(frame) >= rows) {
        // It cannot be drawn in place on a screen this short: take what is there away and draw the box at the end.
        out.write((height ? `${ESC}[${height}A` : '') + `${ESC}[J`);
        height = 0;
        still = true;
        return;
      }
      if (!hidden) { hidden = true; out.write(HIDE_CURSOR); }    // only once there is something to draw in place
      out.write((height ? `${ESC}[${height}A` : '') + frame);
      height = lines(frame);
    };
    const drawBox = () => {
      const f = facts();
      if (doctorReal(doctorChecks(f)).length) out.write(encode([...doctorBox(f, doctorChecks(f), { final: true }), []], tier));
    };
    // The facts ended with no check in them (the shell was cut short): there is no verdict to give, and
    // what was drawn while waiting for one is taken away.
    const giveUp = () => {
      if (height) out.write(`${ESC}[${height}A${ESC}[J`);
      height = 0;
      finish('done');
    };

    function onSignal() { finish('interrupted'); }
    function onData(chunk) {
      partial += chunk;
      const cut = partial.lastIndexOf('\n');
      if (cut < 0) return;
      text += partial.slice(0, cut + 1);
      partial = partial.slice(cut + 1);
    }
    function onEnd() {
      if (ended || settled) return;
      if (partial) { text += `${partial}\n`; partial = ''; }
      ended = true;
      if (still) attempt(() => { drawBox(); finish('done'); });
    }
    const tick = () => {
      if (settled || still) return;
      attempt(() => {
        const f = facts();
        const checks = doctorChecks(f);
        if (ended && doctorReal(checks).length === 0) return giveUp();
        const last = RUN + DOCTOR_VERDICT[doctorGood(checks) ? 'good' : 'issues'];
        t = Math.min(last, inspectorStep(t, { done: doctorReal(checks).length, expect: Number(f.expect) || DOCTOR_EXPECT, ended }));
        drawFrame(f, checks);
        if (still) { if (ended) { drawBox(); finish('done'); } return; }
        if (ended && t >= last) return finish('done');
        // on the clock rather than a step after the last draw, so a slow write does not stretch the whole
        timer = setTimeout(tick, Math.max(0, started + (++ticks) * stepMs - Date.now()));
      });
    };

    for (const sig of STOP_SIGNALS) signals.on(sig, onSignal);
    input.setEncoding('utf8');
    input.on('data', onData);
    input.on('end', onEnd);
    input.on('error', onEnd);
    attempt(() => {
      if (still) return;
      started = Date.now();
      tick();
    });
  });
}

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
  // `foreman status`: the dome, the batch and the tickets, in order.
  status: { min: STATUS_MIN, frames: 1, rows: (facts, o) => statusRows(facts, o) },
  // `foreman dry-run`: the low sun, the tickets that would run, the settings and the prompt.
  dryrun: { min: DRYRUN_MIN, frames: 1, rows: (facts, o) => dryrunRows(facts, o) },
  // `foreman run`: the figure, the dome at the tickets done, and the run's facts.
  run: { min: RUN_MIN, frames: 1, rows: (facts, o) => runRows(facts, o) },
  // `foreman order`, in two parts: the header, then what the agent left once it is done.
  'order-head': { min: ORDER_MIN, frames: 1, rows: (facts) => orderHeadRows(facts) },
  order: { min: ORDER_MIN, frames: 1, rows: (facts, o) => stakeRows(facts, o) },
  // `foreman next --all` and `--count`: the stake row, and the same sum on one line.
  next: { min: NEXT_MIN, frames: 1, rows: (facts, o) => nextRows(facts, o) },
  'next-count': { min: NEXT_MIN, frames: 1, rows: (facts) => nextCountRows(facts) },
  // `foreman doctor`: the box of checks and its verdict. The inspector's frames (`--t`) and the live
  // drawing (`--stream`) are the doctor's own, below.
  doctor: { min: DOCTOR_MIN, frames: 1, rows: (facts) => doctorBox(facts, doctorChecks(facts), { final: true }) },
  // `foreman version`: the mark beside the build.
  version: { min: VERSION_MIN, frames: 1, rows: (facts, o) => versionRows(facts, o) },
  // `foreman report`: the mark beside the total cost, the outcomes, and the ledger of runs.
  report: { min: REPORT_MIN, frames: 1, rows: (facts, o) => reportRows(facts, o) },
  // `foreman convert`: the sign repainted, then what changed and what is left for the person.
  convert: { min: CONVERT_MIN, frames: 1, rows: (facts, o) => convertRows(facts, o) },
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

// The doctor's live drawing, from the facts the shell writes as it goes. A terminal on stdout is the
// only place it is played; anywhere else the box is drawn once, when the facts end.
async function streamDoctor(tier, cols, stepMs) {
  process.stdout.on('error', () => {});
  const animate = Boolean(process.stdout.isTTY) && tier !== 0;
  try {
    const how = await playDoctor({ input: process.stdin, out: process.stdout, tier, cols, rows: process.stdout.rows || 0, animate, stepMs });
    return how === 'interrupted' ? 130 : 0;
  } catch (e) {
    process.stderr.write(`foreman-draw: ${e.message}\n`);
    return 1;
  }
}

function main(argv) {
  const usage = (msg) => { process.stderr.write(`foreman-draw: ${msg}\n`); return 2; };
  let scene = null, tier = null, cols = null, frame = null, step = null, playing = false, tick = null, streaming = false, plain = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--tier') tier = argv[++i];
    else if (argv[i] === '--cols') cols = argv[++i];
    else if (argv[i] === '--frame') frame = argv[++i] ?? '';
    else if (argv[i] === '--step') step = argv[++i];
    else if (argv[i] === '--play') playing = true;
    else if (argv[i] === '--t') tick = argv[++i] ?? '';
    else if (argv[i] === '--stream') streaming = true;
    else if (argv[i] === '--plain') plain = true;
    else if (argv[i].startsWith('-') || scene !== null) return usage(`unexpected argument '${argv[i]}'`);
    else scene = argv[i];
  }
  if (scene === null) return usage('usage: foreman-draw.cjs SCENE --tier 16|256|24 --cols N [--frame N | --play]');
  if (!Object.hasOwn(SCENES, scene)) return usage(`unknown scene '${scene}'`);
  if (plain) tier = tier ?? '0';
  if (!['16', '256', '24'].includes(tier) && !(plain && tier === '0')) return usage('--tier must be 16, 256 or 24');
  if (!/^[0-9]+$/.test(cols || '') || Number(cols) < 1) return usage('--cols must be a width in columns');
  const { frames } = SCENES[scene];
  if (frame !== null && (!/^[0-9]+$/.test(frame) || Number(frame) >= frames)) {
    return usage(`--frame must be a frame number, 0 to ${frames - 1} for '${scene}' (got '${frame}')`);
  }
  if (step !== null && !/^[0-9]+$/.test(step)) return usage('--step must be a number of milliseconds');
  if (playing && frame !== null) return usage('--play and --frame are alternatives');
  if ((tick !== null || streaming) && scene !== 'doctor') return usage(`'${scene}' has no ${tick !== null ? '--t' : '--stream'}`);
  if (tick !== null && !/^[0-9]+$/.test(tick)) return usage(`--t must be a tick number (got '${tick}')`);
  if (plain && scene !== 'doctor') return usage(`'${scene}' has no --plain`);
  if ([tick !== null, streaming, playing, frame !== null].filter(Boolean).length > 1) return usage('--t, --stream, --play and --frame are alternatives');
  if (Number(cols) < SCENES[scene].min) {
    process.stderr.write(`foreman-draw: ${cols} columns is too narrow for '${scene}' (needs ${SCENES[scene].min})\n`);
    return 3;
  }

  if (streaming) return streamDoctor(Number(tier), Number(cols), step === null ? 70 : Number(step));
  if (playing) return playScene(scene, Number(tier), Number(cols), step === null ? 70 : Number(step));

  // A terminal on stdin means no one piped facts in; reading it would wait for a person.
  let text = '';
  if (!process.stdin.isTTY) {
    try { text = fs.readFileSync(0, 'utf8'); } catch { /* closed or empty: no facts */ }
  }
  const facts = parseFacts(text);
  const out = tick !== null
    ? encode(doctorTickFrame(facts, Number(tick), Number(tier)), Number(tier))
    : draw(scene, facts, { tier: Number(tier), cols: Number(cols), frame: frame === null ? undefined : Number(frame) });
  process.stdout.on('error', () => {});    // a reader that left early (| head) is not our error
  process.stdout.write(out);
  return 0;
}

module.exports = {
  loadPalette, encode, sgr, halfBlocks, parseFacts, draw, drawFrames, play, SCENES,
  doctorFrame, doctorChecks, doctorTickFrame, inspectorStep, playDoctor, RUN,
  mark, withMark, MARK_WIDTH, TEXT_COLUMN, rule, ticketId, movedCount, movedTickets, tilde, dome, runDome, runsWidth,
};

if (require.main === module) {
  Promise.resolve(main(process.argv.slice(2))).then((code) => { process.exitCode = code; });
}
