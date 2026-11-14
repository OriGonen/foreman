'use strict';
// overview.cjs: the one place that knows which batch the window is on, and what to do when a read
// started by the watcher and one started by a click overlap. A fake foreman stands in for the CLI.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createOverview } = require('../overview.cjs');
const { sample } = require('./sample.cjs');

const entry = (path, extra = {}) => ({ path, name: path.split('/').pop(), finished: false, counts: { done: 0, total: 1 }, human_remaining: 0, next: null, error: null, ...extra });

function fake({ batches, status } = {}) {
  const f = {
    batches: batches || [entry('.scratch/a'), entry('.scratch/b')],
    calls: [],
    gates: [],                       // when set, a read waits for it: lets a test interleave two reads
    failStatus: new Set(),
    async statusAll() { f.calls.push('all'); return { foreman_json: 1, command: 'status', all: true, batches: f.batches }; },
    async status(p) {
      f.calls.push('status ' + p);
      if (f.gates.length) await f.gates.shift();
      if (f.failStatus.has(p)) throw Object.assign(new Error('could not read ' + p), { kind: 'exit' });
      return { ...(status || sample()), batch: { path: p, name: p.split('/').pop() } };
    },
  };
  return f;
}
const make = (f) => createOverview({ foreman: f, repoRoot: 'C:/Projects/app' });

test('load: the rail, the batch chosen, its status, and the repository', async () => {
  const f = fake();
  const o = make(f);
  const d = await o.load(null);
  assert.equal(d.ok, true);
  assert.equal(d.repoRoot, 'C:/Projects/app');
  assert.equal(d.selected, '.scratch/a');
  assert.equal(d.status.batch.path, '.scratch/a');
  assert.equal(d.statusError, null);
  assert.equal(d.all.batches.length, 2);
  assert.equal(o.selected, '.scratch/a');
});

test('load of another batch moves the window to it, and the next refresh stays there', async () => {
  const f = fake();
  const o = make(f);
  await o.load(null);
  assert.equal((await o.load('.scratch/b')).selected, '.scratch/b');
  const r = await o.refresh();
  assert.equal(r.selected, '.scratch/b');
  assert.equal(f.calls[f.calls.length - 1], 'status .scratch/b');
});

test('a batch the list calls broken is an answer, with the CLI\'s words; a batch the list calls fine but cannot be read is thrown, for a retry', async () => {
  const f = fake({ batches: [entry('.scratch/a', { counts: null, error: 'boom in a' }), entry('.scratch/b')] });
  f.failStatus.add('.scratch/a');
  const o = make(f);
  const d = await o.load('.scratch/a');
  assert.equal(d.status, null);
  assert.equal(d.statusError, 'could not read .scratch/a');
  f.failStatus.add('.scratch/b');
  await assert.rejects(o.load('.scratch/b'), /could not read \.scratch\/b/);
});

test('no batches: nothing selected, no status read', async () => {
  const f = fake({ batches: [] });
  const d = await make(f).load(null);
  assert.equal(d.selected, null);
  assert.equal(d.status, null);
  assert.ok(!f.calls.some((c) => c.startsWith('status ')));
});

test('the loop renames the batch to DONE_ under the window: the next refresh follows it', async () => {
  const f = fake({ batches: [entry('.scratch/gui')] });
  const o = make(f);
  await o.load('.scratch/gui');
  f.batches = [entry('.scratch/DONE_gui', { finished: true, counts: null })];
  const r = await o.refresh();
  assert.equal(r.selected, '.scratch/DONE_gui');
  assert.equal(o.selected, '.scratch/DONE_gui');
});

test('a refresh that was running when a click moved the window is thrown away, and does not move it back', async () => {
  const f = fake();
  const o = make(f);
  await o.load('.scratch/a');
  let release;
  f.gates.push(new Promise((r) => { release = r; }));          // the refresh's status read waits
  const stale = o.refresh();                                    // of .scratch/a
  const click = await o.load('.scratch/b');                     // the person clicks b meanwhile
  assert.equal(click.selected, '.scratch/b');
  release();
  assert.equal(await stale, null, 'the stale answer is discarded');
  assert.equal(o.selected, '.scratch/b', 'and the window stays on b');
});

test('a click that starts while a refresh is running, and finishes after it: the refresh is discarded and the click wins', async () => {
  const f = fake();
  const o = make(f);
  await o.load('.scratch/a');
  let releaseRefresh, releaseClick;
  f.gates.push(new Promise((r) => { releaseRefresh = r; }), new Promise((r) => { releaseClick = r; }));
  const refresh = o.refresh();                       // its status read takes the first gate
  const click = o.load('.scratch/b');                // the person's takes the second
  releaseRefresh();
  assert.equal(await refresh, null);
  assert.equal(o.selected, '.scratch/a', 'the click has not finished, so nothing has moved yet');
  releaseClick();
  assert.equal((await click).selected, '.scratch/b');
  assert.equal(o.selected, '.scratch/b');
});

test('dirs: every batch still being worked on, and the finished one the window is on; nothing before the first read', async () => {
  const f = fake({ batches: [entry('.scratch/a'), entry('.scratch/DONE_old', { finished: true, counts: null }), entry('.scratch/b')] });
  const o = make(f);
  assert.deepEqual(await o.dirs(), []);
  await o.load('.scratch/a');
  assert.deepEqual(await o.dirs(), ['.scratch/a', '.scratch/b']);
  await o.load('.scratch/DONE_old');
  assert.deepEqual(await o.dirs(), ['.scratch/a', '.scratch/DONE_old', '.scratch/b']);
});

test('statusOf: the status the last read got for that batch, for the ticket page to use; null for any other', async () => {
  const f = fake();
  const o = make(f);
  assert.equal(o.statusOf('.scratch/a'), null, 'nothing read yet');
  const d = await o.load('.scratch/a');
  assert.equal(o.statusOf('.scratch/a'), d.status);
  assert.equal(o.statusOf('.scratch/b'), null);
  const before = f.calls.length;
  const r = await o.refresh();
  assert.equal(o.statusOf('.scratch/a'), r.status, 'a refresh replaces it');
  assert.ok(f.calls.length > before);
  f.failStatus.add('.scratch/b');
  await assert.rejects(o.load('.scratch/b'));
  assert.equal(o.statusOf('.scratch/b'), null, 'a read that failed leaves none');
});
