// Reads text with SGR escapes on stdin (a design's .ans file, or what foreman-draw prints) and
// prints one line per row, the first N cells of it (`--cells N`, default all), each as
// `char/fg/bg` — fg and bg as r;g;b, or empty — so two pictures are the same when their lines are.
// Bold is not part of a cell here: the art has none, and the words beside it are checked as text.
// A row is padded with blank cells to N, as the design pads its rows and the renderer does not.
// `--rows A-B` keeps only those rows (0-based, inclusive).
'use strict';

let width = Infinity, from = 0, to = Infinity;
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--cells') width = Number(args[++i]);
  else if (args[i] === '--rows') [from, to] = args[++i].split('-').map(Number);
}

const lines = require('fs').readFileSync(0, 'utf8').split('\n');
if (lines[lines.length - 1] === '') lines.pop();
const out = [];
lines.forEach((line, n) => {
  if (n < from || n > to) return;
  let fg = '', bg = '';
  const cells = [];
  const re = /\x1b\[([0-9;]*)m|([^\x1b])/gu;
  let m;
  while ((m = re.exec(line))) {
    if (m[2] !== undefined) { cells.push(`${m[2]}/${fg}/${bg}`); continue; }
    const p = m[1] === '' ? [0] : m[1].split(';').map(Number);
    fg = ''; bg = '';
    for (let i = 0; i < p.length;) {
      if (p[i] === 38 && p[i + 1] === 2) { fg = p.slice(i + 2, i + 5).join(';'); i += 5; }
      else if (p[i] === 48 && p[i + 1] === 2) { bg = p.slice(i + 2, i + 5).join(';'); i += 5; }
      else i++;
    }
  }
  while (cells.length < width) cells.push(' //');
  // A blank cell has no colour worth comparing: a space on a background is still a blank for this.
  out.push(cells.slice(0, width).map((c) => (c[0] === ' ' ? ' //' : c)).join(' '));
});
process.stdout.write(out.join('\n') + (out.length ? '\n' : ''));
