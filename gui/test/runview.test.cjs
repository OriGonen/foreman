'use strict';
// runview.js: the live screen's model, from what main read and the batch's status.
const test = require('node:test');
const assert = require('node:assert/strict');
const V = require('../runview.js');
const { sample, reportRunSample } = require('./sample.cjs');

const T0 = Date.parse('2026-10-22T14:05:33Z');
const runOf = (over = {}) => ({ in_flight: true, id: 'r1', started_at: '2026-10-22T14:05:33Z', iteration: 4, budget: 5, live: true, control_dir: 'b/.foreman-run', pid: { msys: 1, windows: 1 }, ...over });
const ctlOf = (over = {}) => ({ budget: 5, iteration: 4, live: true, activity: { epoch: Math.floor((T0 + 31 * 60000) / 1000), label: 'Bash: x' }, feed: [], spent: null, ...over });
function live(over = {}) {
  const status = sample();
  return { batch: '.scratch/b', run: runOf(), next: status.next, control: ctlOf(), iterations: reportRunSample().run.iterations, iterationsError: null, caps: { cost: 25, minutes: 90 }, ...over };
}
const ctx = (over = {}) => ({ status: sample(), now: T0 + 32 * 60000 + 24000, ...over });

test('the iterations in order, each with the CLI\'s outcome word, its cost and its time; a checkpoint turn is its own row', () => {
  const s = V.screen(live(), ctx());
  const done = s.rows.filter((r) => r.kind === 'done');
  assert.deepEqual(done.map((r) => [r.num, r.label, r.chip.text, r.meta]), [
    ['1/5', '03 third', 'progressed', '15m00s · $2.00'],
    ['2/5', '03 third', 'landed', '12m00s · $1.50'],
    ['3/5', '04 fourth', 'unproductive', '1m00s · $0.50'],
    ['', '04 fourth', 'checkpoint turn', '0m30s · $0.25'],
  ]);
  assert.deepEqual(done.map((r) => r.glyph), ['↗', '✓', '✗', '⟲']);
  assert.deepEqual(done[2].flags, ['error', 'limit']);
});

test('the running iteration is the one the loop says (iteration 4), shown under the finished ones with the ticket the status names next', () => {
  const s = V.screen(live({ control: ctlOf({ feed: [{ tm: '00:12', tool: 'Read', text: 'a' }, { tm: '02:10', tool: 'Bash', text: 'bash test/smoke.sh' }] }) }), ctx());
  const r = s.rows[s.rows.length - 1];
  assert.equal(r.kind, 'running');
  assert.equal(r.num, '4/5');
  assert.equal(r.label, '05 document-human-tickets');
  assert.equal(r.chip.text, 'running');
  assert.equal(r.meta, '01:24', 'its own clock, from when its agent started');
  assert.equal(r.feed.length, 2);
  assert.equal(s.running, r);
});

test('with live off there is no feed to show, and the row says so', () => {
  const s = V.screen(live({ control: ctlOf({ live: false, feed: [{ tm: '00:12', tool: 'Read', text: 'a' }] }) }), ctx());
  assert.deepEqual(s.running.feed, []);
  assert.equal(s.running.feedOff, true);
  assert.equal(s.bar.live, false);
});

test('before anything has run there is one row, starting', () => {
  const s = V.screen(live({ iterations: [], control: ctlOf({ iteration: 0, activity: null }), run: runOf({ iteration: 0 }) }), ctx());
  assert.equal(s.rows.length, 1);
  assert.equal(s.rows[0].label, 'starting…');
  assert.equal(s.bar.iteration, 'starting');
});

test('when every iteration the loop has started is in the record, no row claims to be running', () => {
  const s = V.screen(live({ control: ctlOf({ iteration: 3 }) }), ctx());
  assert.equal(s.running, null);
  assert.equal(s.rows.length, 4);
});

test('the bar: the iteration and budget from the control directory, not from the status read before the key was pressed', () => {
  const s = V.screen(live({ control: ctlOf({ budget: 6 }) }), ctx());
  assert.equal(s.bar.iteration, '4 of 6');
  assert.equal(s.bar.budget, 6);
  assert.equal(V.screen(live({ control: ctlOf({ budget: null }) }), ctx()).bar.iteration, '4 of unlimited');
  assert.equal(V.screen(live({ control: null }), ctx()).bar.iteration, '4 of 5', 'no control files: what status said');
});

test('− cannot go below the iteration running and + means nothing when unlimited', () => {
  assert.equal(V.screen(live({ control: ctlOf({ budget: 4 }) }), ctx()).bar.minusOff, true);
  assert.equal(V.screen(live({ control: ctlOf({ budget: 5 }) }), ctx()).bar.minusOff, false);
  const un = V.screen(live({ control: ctlOf({ budget: null }) }), ctx());
  assert.equal(un.bar.plusOff, true);
  assert.equal(un.bar.minusOff, false, 'from unlimited, − is "stop after this one"');
});

test('spend and time against their caps; hot near the cap; no cap says so', () => {
  const s = V.screen(live(), ctx());
  assert.equal(s.bar.spent.text, '$4.25 / $25');
  assert.ok(Math.abs(s.bar.spent.frac - 0.17) < 1e-9);
  assert.equal(s.bar.spent.hot, false);
  assert.equal(s.bar.time.text, '32m / 90m');
  const hot = V.screen(live({ caps: { cost: 5, minutes: null } }), ctx());
  assert.equal(hot.bar.spent.hot, true);
  assert.equal(hot.bar.time.text, '32m · no cap');
  assert.equal(hot.bar.time.frac, 0);
  const own = V.screen(live(), ctx({ caps: { cost: 10, minutes: 40 } }));
  assert.equal(own.bar.spent.text, '$4.25 / $10', 'the caps the app started the run with');
});

test('a run with no cost in the record yet shows the spent file the loop wrote, if there is one', () => {
  const s = V.screen(live({ iterations: [], control: ctlOf({ iteration: 1, spent: { spent: 0.4, max: 25 } }) }), ctx());
  assert.equal(s.bar.spent.text, '$0.40 / $25');
});

test('steering is off, with the words, when the run has no control directory in the batch', () => {
  const s = V.screen(live({ run: runOf({ control_dir: null }), control: null }), ctx());
  assert.equal(s.steerable, false);
  assert.equal(s.bar.disabledWhy, 'Steering needs `doctor --fix`');
  assert.equal(V.screen(live(), ctx()).bar.disabledWhy, null);
});

test('the compact view: where it is, the running ticket and its last activity', () => {
  const s = V.screen(live({ control: ctlOf({ feed: [{ tm: '02:10', tool: 'Bash', text: 'bash test/smoke.sh doctor' }] }) }), ctx());
  assert.equal(s.compact.line, '05 document-human-tickets');
  assert.equal(s.compact.activity, '02:10 Bash bash test/smoke.sh doctor');
  assert.equal(s.compact.progress, '4 of 10 · iteration 4 of 5');
  const noFeed = V.screen(live(), ctx());
  assert.equal(noFeed.compact.activity, 'Bash: x', 'the activity label when the feed is empty');
});

test('clock words', () => {
  assert.equal(V.clock(48000), '0m48s');
  assert.equal(V.clock(1500000), '25m00s');
  assert.equal(V.clock(null), '');
  assert.equal(V.mmss(144), '02:24');
  assert.equal(V.ticketName('b/issues/DONE_07a-followup-x.md'), '07a followup-x');
});
