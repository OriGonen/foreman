'use strict';
// art.js: the end scenes (designs/05-run-end.html, take b1), checked as shapes. How they look is checked by a
// person against the design; what is held here is what the ticket says is true of every one: the same sun
// apart from its height, the foreman as one flat dark shape in square cells with no face, the signs on
// their sides, a flag for each landed ticket, and nothing the strict CSP would refuse.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class El {
  constructor(tag) { this.tagName = tag; this.children = []; this.attrs = {}; this._text = ''; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  appendChild(k) { this.children.push(k); return k; }
  append(...ks) { ks.forEach((k) => this.appendChild(k)); }
  set textContent(v) { this._text = String(v); }
  get textContent() { return this._text + this.children.map((c) => c.textContent).join(''); }
  get className() { return this.attrs.class || ''; }
  all() { return this.children.flatMap((c) => [c, ...c.all()]); }
  has(cls) { return this.className.split(/\s+/).includes(cls); }
}
const win = { document: { createElementNS: (_n, tag) => new El(tag), createElement: (tag) => new El(tag) } };
win.window = win;
vm.createContext(win);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'art.js'), 'utf8'), win, { filename: 'art.js' });
const A = win.ForemanArt;

const scene = (kind, flags = 0) => A.endScene({ kind, flags, w: 400 });
const byClass = (svg, cls) => svg.all().filter((e) => e.has(cls));
const sun = (svg) => ['f-ring2', 'f-ring1', 'f-rim', 'f-mid', 'f-core'].map((c) => { const e = byClass(svg, c)[0]; return [c, e.attrs.cx, e.attrs.cy, e.attrs.r]; });
const figure = (svg) => byClass(svg, 'foreman')[0];
const cells = (svg) => figure(svg).all().find((e) => e.tagName === 'path').attrs.d;

test('a scene is one svg of the design\'s 320 x 170 canvas, decorative, and scales with its width', () => {
  const s = scene('done');
  assert.equal(s.tagName, 'svg');
  assert.equal(s.attrs.viewBox, '0 0 320 170');
  assert.equal(s.attrs.width, '400');
  assert.equal(s.attrs.height, '213');
  assert.equal(s.attrs['aria-hidden'], 'true');
  assert.equal(A.endScene({ kind: 'done', w: 200 }).attrs.height, '106');
});

test('an unknown kind is the done scene, as in the design, not a crash', () => {
  assert.equal(sun(scene('nonsense')).join(), sun(scene('done')).join());
});

test('the sun is the terminal\'s: five flat bands from the rim in, a glow behind, one big sun on a low horizon', () => {
  const s = scene('done');
  const bands = sun(s);
  assert.deepEqual(bands.map((b) => b[0]), ['f-ring2', 'f-ring1', 'f-rim', 'f-mid', 'f-core']);
  assert.deepEqual(bands.map((b) => +b[3]), [80, 75, 70, 70 * 0.84, 70 * 0.56].map((n) => +n.toFixed(1)));
  assert.ok(bands.every((b) => b[1] === '160'), 'centred');
  assert.equal(byClass(s, 'f-glow').length, 1);
  assert.ok(s.all().some((e) => e.tagName === 'radialGradient'), 'the glow is a gradient behind the sun, not on the figure');
});

test('the sun\'s height is the scene: risen, held halfway, a little lower than halfway', () => {
  const cy = (k) => +sun(scene(k))[0][2];
  assert.equal(cy('done'), 80, 'fully risen: its centre well above the horizon (148)');
  assert.equal(cy('paused'), 148, 'halfway: centred on the horizon');
  assert.equal(cy('problem'), 156, 'a little lower than halfway');
  assert.ok(cy('done') < cy('paused') && cy('paused') < cy('problem'));
});

test('exit 30\'s sun is exactly exit 10\'s: same height, bands and colours', () => {
  const key = (k) => JSON.stringify(sun(scene(k)).concat(byClass(scene(k), 'f-glow').map((e) => [e.attrs.cx, e.attrs.cy, e.attrs.r]),
    byClass(scene(k), 'k-glint').map((e) => [e.attrs.x1, e.attrs.x2, e.attrs.y1, e.attrs.opacity])));
  assert.equal(key('human'), key('paused'));
  assert.notEqual(key('problem'), key('paused'));
});

test('the glint under the horizon: four lines on the ground, narrowing and fading, only the colour of the token', () => {
  const g = byClass(scene('paused'), 'k-glint');
  assert.equal(g.length, 4);
  const widths = g.map((e) => +e.attrs.x2 - +e.attrs.x1);
  assert.ok(widths.every((w, i) => i === 0 || w < widths[i - 1]), 'narrowing: ' + widths);
  assert.ok(g.every((e) => +e.attrs.y1 > 148), 'below the horizon');
  assert.ok(+g[3].attrs.opacity < +g[0].attrs.opacity);
});

test('the ground is a band that fades out, with a hard horizon in the figure\'s dark', () => {
  const s = scene('done');
  assert.equal(byClass(s, 'f-night').length, 1);
  const h = byClass(s, 'f-sil').find((e) => e.tagName === 'rect' && e.attrs.height === '1.5');
  assert.ok(h, 'the horizon line');
  assert.equal(h.attrs.y, '147.4');
});

test('the foreman is one flat dark shape: a single path of square cells, no face, no colour, no gradient', () => {
  for (const k of ['done', 'paused', 'problem', 'human']) {
    const f = figure(scene(k));
    assert.ok(f.has('f-sil'), 'his one colour');
    const kids = f.all();
    assert.equal(kids.length, 1, 'one shape');
    assert.equal(kids[0].tagName, 'path');
    assert.equal(kids[0].attrs['shape-rendering'], 'crispEdges');
    assert.ok(!/gradient|url\(/.test(JSON.stringify(f.attrs) + JSON.stringify(kids[0].attrs)));
    assert.ok(!('fill' in kids[0].attrs) && !('stroke' in kids[0].attrs), 'colour comes from his class alone');
    assert.ok(/^(M-?\d+ -?\d+h1\.04v1\.04h-1\.04z)+$/.test(kids[0].attrs.d), 'every cell is a square of one size');
  }
});

test('the foreman is the terminal\'s 18 x 25 sprite: body cells the same in every pose, the arms the pose', () => {
  const body = (d) => d.split('z').filter(Boolean).map((c) => c + 'z');
  const poses = ['done', 'paused', 'problem', 'human'].map((k) => body(cells(scene(k))));
  const rowsOf = (list) => list.map((c) => +/M-?\d+ (-?\d+)/.exec(c)[1]);
  for (const p of poses) assert.ok(Math.max(...rowsOf(p)) === 24, 'feet on row 24 of 25');
  const common = poses.map((p) => new Set(p));
  const shared = [...common[0]].filter((c) => common.every((s) => s.has(c)));
  assert.ok(shared.length > 150, 'one body under every pose: ' + shared.length);
  const distinct = new Set(poses.map((p) => p.join('')));
  assert.equal(distinct.size, 4, 'four poses');
  assert.ok(poses[0].some((c) => /^M\d+ -1h/.test(c)), 'the raised arm goes above his head');
  assert.ok(poses[3].some((c) => /^M-\d/.test(c)), 'the shrug puts both elbows out past his sides');
});

test('he stands in front of the sun, on the horizon, where the design puts him', () => {
  const at = (k) => /translate\(([\d.]+) ([\d.]+)\) scale\(([\d.]+)\)/.exec(figure(scene(k)).attrs.transform);
  assert.deepEqual([at('done'), at('paused'), at('problem'), at('human')].map((m) => +(+m[1] + 8.8 * +m[3]).toFixed(0)), [160, 144, 136, 190]);
  assert.ok([at('done'), at('paused')].every((m) => +m[2] + 25 * +m[3] === 148), 'his feet on the horizon');
});

test('exit 0: a small flag on a stake for each landed ticket, on both sides of him, never on him', () => {
  const flags = (n) => byClass(scene('done', n), 'flag');
  assert.equal(flags(0).length, 0);
  assert.equal(flags(4).length, 4);
  assert.equal(flags(10).length, 10);
  assert.equal(flags(25).length, 10, 'the horizon holds ten; the facts line carries the true count');
  const xs = flags(10).map((f) => +f.attrs['data-x']);
  assert.ok(xs.every((x) => x < 130 || x > 190), 'clear of the foreman (at 160): ' + xs);
  assert.ok(xs.some((x) => x < 160) && xs.some((x) => x > 160));
  assert.equal(byClass(scene('paused', 5), 'flag').length, 0, 'only the done scene has flags');
});

test('exit 20: a hand-lettered, leaning "problem!" sign on his right', () => {
  const s = scene('problem');
  const sign = byClass(s, 'sign');
  assert.equal(sign.length, 1);
  const m = /translate\(([\d.-]+) [\d.]+\) rotate\(([\d.-]+)\)/.exec(sign[0].attrs.transform);
  assert.ok(+m[1] > 136, 'to the right of the foreman at 136');
  assert.ok(+m[2] > 0, 'leaning, not square to the floor');
  const letters = sign[0].all().filter((e) => e.tagName === 'text');
  assert.deepEqual(letters.map((t) => t.textContent), ['problem!']);
  assert.ok(letters[0].has('f-letter'));
  assert.match(letters[0].attrs['font-family'], /Segoe Print.*cursive/);
  assert.ok(letters[0].attrs.rotate.split(' ').length === 'problem!'.length, 'every letter a little off, by hand');
  assert.ok(sign[0].has('f-sil'), 'a dark board');
});

test('exit 30: a different, leaning sign on his left that says "need human inspection!"', () => {
  const s = scene('human');
  const sign = byClass(s, 'sign');
  assert.equal(sign.length, 1);
  const m = /translate\(([\d.-]+) [\d.]+\) rotate\(([\d.-]+)\)/.exec(sign[0].attrs.transform);
  assert.ok(+m[1] < 190, 'to the left of the foreman at 190');
  assert.ok(+m[2] < 0, 'leaning the other way');
  const letters = sign[0].all().filter((e) => e.tagName === 'text').map((t) => t.textContent);
  assert.equal(letters.join(' '), 'need human inspection!');
  assert.notEqual(sign[0].all().map((e) => e.attrs.d || '').join(), byClass(scene('problem'), 'sign')[0].all().map((e) => e.attrs.d || '').join(), 'a different board');
});

test('the done and paused scenes have no sign, and no scene has confetti, a face or a bare colour', () => {
  assert.equal(byClass(scene('done', 3), 'sign').length, 0);
  assert.equal(byClass(scene('paused'), 'sign').length, 0);
  for (const k of ['done', 'paused', 'problem', 'human']) {
    const all = scene(k, 10).all();
    assert.ok(all.every((e) => !('style' in e.attrs)), 'no inline style: the CSP refuses it');
    assert.ok(all.every((e) => !('fill' in e.attrs) || /^url\(#/.test(e.attrs.fill) || e.attrs.fill === 'none'), 'colour only from the tokens, through classes');
    assert.ok(all.every((e) => !('stroke' in e.attrs) || /^#?\w+$/.test(e.attrs.stroke)));
    assert.ok(!all.some((e) => e.tagName === 'image' || e.tagName === 'foreignObject'));
    assert.equal(all.filter((e) => e.tagName === 'circle').length, 6, 'the glow and five bands, nothing else round (no head, no eyes, no confetti)');
  }
});

test('two scenes on a screen do not share gradient ids', () => {
  const ids = (s) => s.all().map((e) => e.attrs.id).filter(Boolean);
  const a = ids(scene('done')), b = ids(scene('done'));
  assert.ok(a.length >= 4);
  assert.ok(a.every((i) => !b.includes(i)));
});
