'use strict';
// live.cjs: the run screen rebuilt from files in a control directory and from `report --run`.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createLive, readControl, parseFeed, capsFromConf } = require('../live.cjs');
const { reportRunSample } = require('./sample.cjs');

function repo(files = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'live-')).replace(/\\/g, '/');
  const ctl = `${root}/b/.foreman-run`;
  fs.mkdirSync(ctl, { recursive: true });
  for (const [name, text] of Object.entries(files)) fs.writeFileSync(`${ctl}/${name}`, text);
  return { root, ctl };
}
const RUN = { in_flight: true, id: '20261022T140533Z-9020', started_at: '2026-10-22T14:05:33Z', iteration: 2, budget: 3, live: true, control_dir: 'b/.foreman-run', pid: { msys: 1, windows: 1 } };

test('the feed: clock, tool word and the rest; anything else is shown whole, as text', () => {
  assert.deepEqual(parseFeed('00:12 · Read .scratch/b/progress.txt\n01:30 · Edit lib/a.sh  +12 −3\n02:10 · Bash\nodd line <b>x</b>\n\n'), [
    { tm: '00:12', tool: 'Read', text: '.scratch/b/progress.txt' },
    { tm: '01:30', tool: 'Edit', text: 'lib/a.sh  +12 −3' },
    { tm: '02:10', tool: 'Bash', text: '' },
    { tm: '', tool: '', text: 'odd line <b>x</b>' },
  ]);
  assert.deepEqual(parseFeed(null), []);
  assert.deepEqual(parseFeed('1:02:03 · Write x').map((x) => x.tm), ['1:02:03']);
  assert.equal(parseFeed(Array.from({ length: 500 }, (_, i) => `00:${String(i % 60).padStart(2, '0')} · Read f${i}`).join('\n')).length, 200, 'only the end of a long feed');
});

test('the control directory: budget (0 is unlimited), iteration, live, activity, spent', () => {
  const { ctl } = repo({ budget: '4\n', iteration: '2\n', live: '1\n', activity: '1761141934 Bash: bash test/smoke.sh\n', spent: '4.64 25\n', feed: '00:41 · Read x\n' });
  assert.deepEqual(readControl(ctl), {
    budget: 4, iteration: 2, live: true, activity: { epoch: 1761141934, label: 'Bash: bash test/smoke.sh' },
    feed: [{ tm: '00:41', tool: 'Read', text: 'x' }], spent: { spent: 4.64, max: 25 },
  });
  const un = repo({ budget: '0\n', live: '0\n' });
  const r = readControl(un.ctl);
  assert.equal(r.budget, null, 'a budget of 0 is unlimited');
  assert.equal(r.live, false);
  assert.equal(r.iteration, null);
  assert.equal(r.activity, null);
  assert.deepEqual(r.feed, []);
});

test('files that are missing or garbled read as absent, never as an error', () => {
  const { ctl } = repo({ budget: '4x\n', iteration: '', live: 'maybe', spent: 'a b', activity: 'soon' });
  const r = readControl(ctl);
  assert.equal(r.budget, undefined);
  assert.equal(r.iteration, null);
  assert.equal(r.live, false);
  assert.equal(r.spent, null);
  assert.equal(r.activity, null);
  assert.doesNotThrow(() => readControl('/nope/does/not/exist'));
  assert.equal(readControl('/nope/does/not/exist').budget, undefined);
});

test('caps from foreman.conf, for a run the app cannot see the environment of: an active line, or the app\'s own environment', () => {
  assert.deepEqual(capsFromConf('FOREMAN_MAX_COST_USD=25\nFOREMAN_MAX_MINUTES=90\n'), { cost: 25, minutes: 90 });
  assert.deepEqual(capsFromConf('#FOREMAN_MAX_COST_USD=25\nFOREMAN_MAX_MINUTES="45" # an hour less\n'), { cost: null, minutes: 45 });
  assert.deepEqual(capsFromConf('FOREMAN_MAX_COST_USD=0\n'), { cost: null, minutes: null });
  assert.deepEqual(capsFromConf('FOREMAN_MAX_COST_USD=$(cat x)\n'), { cost: null, minutes: null }, 'nothing computed is guessed at');
  assert.deepEqual(capsFromConf('FOREMAN_MAX_COST_USD=25\n', { FOREMAN_MAX_COST_USD: '5' }), { cost: 5, minutes: null }, 'the environment wins, as in the CLI');
  assert.deepEqual(capsFromConf(null, {}), { cost: null, minutes: null });
});

test('read: the run, its control files, and the iterations from report --run; no run in flight is null', async () => {
  const { root, ctl } = repo({ budget: '3\n', iteration: '2\n', live: '1\n', feed: '00:05 · Read a\n' });
  fs.writeFileSync(`${root}/b/foreman.conf`, 'FOREMAN_MAX_COST_USD=25\n');
  const asked = [];
  const foreman = { report: async (b, o) => { asked.push([b, o]); return reportRunSample(); } };
  const live = createLive({ repoRoot: root, foreman, env: {} });
  const out = await live.read({ batch: 'b', run: RUN, next: { file: 'b/issues/04.md' } });
  assert.deepEqual(asked, [['b', { run: RUN.id }]]);
  assert.equal(out.control.iteration, 2);
  assert.equal(out.control.budget, 3);
  assert.equal(out.iterations.length, 4, 'the rows as the CLI reported them, outcome words and all');
  assert.equal(out.iterations[0].outcome, 'progressed');
  assert.deepEqual(out.caps, { cost: 25, minutes: null });
  assert.equal(out.next.file, 'b/issues/04.md');
  assert.equal(await live.read({ batch: 'b', run: { ...RUN, in_flight: false } }), null);
  assert.equal(await live.read({ batch: 'b', run: null }), null);
  assert.ok(ctl);
});

test('a change that is not the record (a feed line, a key) does not ask the CLI again; a change to the record does', async () => {
  const { root, ctl } = repo({ budget: '3\n', iteration: '1\n', live: '1\n' });
  let calls = 0;
  const foreman = { report: async () => { calls++; return reportRunSample(); } };
  const live = createLive({ repoRoot: root, foreman, env: {} });
  await live.read({ batch: 'b', run: RUN });
  fs.writeFileSync(`${ctl}/feed`, '00:09 · Edit x\n');
  const again = await live.read({ batch: 'b', run: RUN, record: false });
  assert.equal(calls, 1, 'the report is kept');
  assert.equal(again.control.feed.length, 1, 'but the control files are read afresh');
  assert.equal(again.iterations.length, 4);
  await live.read({ batch: 'b', run: RUN, record: true });
  assert.equal(calls, 2);
  // another run, or the first read: always asked
  await live.read({ batch: 'b', run: { ...RUN, id: 'other' }, record: false });
  assert.equal(calls, 3);
});

test('a run with no finished iteration yet (the CLI has nothing to report) shows no rows, not an error', async () => {
  const { root } = repo({ budget: '3\n', iteration: '1\n' });
  const foreman = { report: async () => { throw new Error('foreman report: no run 20261022T140533Z-9020 in the record'); } };
  const out = await createLive({ repoRoot: root, foreman, env: {} }).read({ batch: 'b', run: RUN });
  assert.deepEqual(out.iterations, []);
  assert.match(out.iterationsError, /no run/);
  assert.equal(out.control.budget, 3);
});

test('a run whose control directory is not known has no control files, and still has its iterations', async () => {
  const { root } = repo();
  const foreman = { report: async () => reportRunSample() };
  const out = await createLive({ repoRoot: root, foreman, env: {} }).read({ batch: 'b', run: { ...RUN, control_dir: null } });
  assert.equal(out.control, null);
  assert.equal(out.iterations.length, 4);
});
