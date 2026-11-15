'use strict';
// The two conditions that take a second read of the CLI: a runner missing for the batch's exec mode
// (`doctor --json` and `dry-run --json`) and a login that expired (`report --json --run`). The facts come
// from fixture JSON; nothing is worked out that the CLI did not say.
const test = require('node:test');
const assert = require('node:assert/strict');
const C = require('../conditions.cjs');
const { sample, doctorSample } = require('./sample.cjs');

const doctorWith = (rows) => ({ ...doctorSample(), sections: [{ id: 'machine', title: 'Machine', rows }] });
const row = (result, label, fix = null) => ({ result, label, detail: '', fix, auto: false, notes: [] });

test('runners: the doctor row that says the batch\'s mode needs a tool that is not on PATH', () => {
  const doc = doctorWith([row('ok', 'git'), row('fail', 'sbx is not on PATH, and FOREMAN_EXEC=sandbox needs it', 'Install sbx and put it on PATH')]);
  assert.deepEqual(C.runnersMissing('.scratch/b', doc, 'sandbox'), {
    batch: '.scratch/b', tool: 'sbx', mode: 'sandbox',
    message: 'sbx is not on PATH, and FOREMAN_EXEC=sandbox needs it', fix: 'Install sbx and put it on PATH',
  });
});

test('runners: local mode needs claude', () => {
  const doc = doctorWith([row('fail', 'claude is not on PATH, and FOREMAN_EXEC=local needs it', 'Install claude and put it on PATH')]);
  const c = C.runnersMissing('.scratch/b', doc, 'local');
  assert.equal(c.tool, 'claude');
  assert.equal(c.mode, 'local');
});

test('the exec mode: the environment, then the last active line of foreman.conf, then sandbox', () => {
  assert.equal(C.execModeOf('', {}), 'sandbox');
  assert.equal(C.execModeOf(null, {}), 'sandbox');
  assert.equal(C.execModeOf('FOREMAN_EXEC=local\n', {}), 'local');
  assert.equal(C.execModeOf('FOREMAN_EXEC=local\r\nFOREMAN_EXEC="sandbox-mount"\r\n', {}), 'sandbox-mount');
  assert.equal(C.execModeOf('# FOREMAN_EXEC=local\nFOREMAN_MODEL=x\n', {}), 'sandbox');
  assert.equal(C.execModeOf("  export FOREMAN_EXEC='local'   # for CI\n", {}), 'local');
  assert.equal(C.execModeOf('RALPH_EXEC=local\n', {}), 'local');
  assert.equal(C.execModeOf('FOREMAN_EXEC=local\n', { FOREMAN_EXEC: 'sandbox' }), 'sandbox');
  assert.equal(C.execModeOf('FOREMAN_EXEC=local\n', { FOREMAN_EXEC: '  ' }), 'local');
});

test('runners: a missing tool for another batch\'s mode is not this batch\'s problem', () => {
  const doc = doctorWith([row('fail', 'sbx is not on PATH, and FOREMAN_EXEC=sandbox needs it')]);
  assert.equal(C.runnersMissing('.scratch/b', doc, 'local'), null);
});

test('runners: nothing missing, and rows that only look alike, give null', () => {
  assert.equal(C.runnersMissing('.scratch/b', doctorWith([row('ok', 'sbx (required by FOREMAN_EXEC=sandbox)')]), 'sandbox'), null);
  assert.equal(C.runnersMissing('.scratch/b', doctorWith([row('warn', 'sbx is not on PATH, and FOREMAN_EXEC=sandbox needs it')]), 'sandbox'), null);
  assert.equal(C.runnersMissing('.scratch/b', doctorWith([]), 'sandbox'), null);
  assert.equal(C.runnersMissing('.scratch/b', {}, 'sandbox'), null);
  assert.equal(C.runnersMissing('.scratch/b', null, ''), null);
});

const needsHuman = () => { const s = sample(); s.last_run = { id: '20261021T091200Z-4411', end: 'needs_human', exit: 20, reason: '06-x.md was not attempted: the agent could not authenticate' }; return s; };
const reportWith = (flags) => ({ run: { id: '20261021T091200Z-4411', iterations: [
  { iteration: 1, kind: 'iteration', ticket: 'a/05.md', outcome: 'landed', flags: [] },
  { iteration: 2, kind: 'iteration', ticket: 'a/06.md', outcome: 'failed', flags },
] } });

test('login: needs a human, exit 20, and the run\'s last record says auth-failed', () => {
  assert.deepEqual(C.loginExpired('.scratch/b', needsHuman(), reportWith(['error', 'auth-failed'])), {
    batch: '.scratch/b', runId: '20261021T091200Z-4411', exit: 20,
    message: '06-x.md was not attempted: the agent could not authenticate',
  });
});

test('login: only the last record counts, and only with auth-failed', () => {
  assert.equal(C.loginExpired('.scratch/b', needsHuman(), reportWith([])), null);
  const earlier = reportWith([]);
  earlier.run.iterations[0].flags = ['auth-failed'];
  assert.equal(C.loginExpired('.scratch/b', needsHuman(), earlier), null);
  assert.equal(C.loginExpired('.scratch/b', needsHuman(), { run: { iterations: [] } }), null);
  assert.equal(C.loginExpired('.scratch/b', needsHuman(), null), null);
});

test('login: any other end of the last run is not this state', () => {
  for (const end of ['complete', 'paused', 'waiting_on_human', null]) {
    const s = needsHuman(); s.last_run.end = end;
    assert.equal(C.loginExpired('.scratch/b', s, reportWith(['auth-failed'])), null, String(end));
  }
  const s = sample(); s.last_run = null;
  assert.equal(C.loginExpired('.scratch/b', s, reportWith(['auth-failed'])), null);
});

test('login: not while a run is in flight', () => {
  const s = needsHuman(); s.run = { in_flight: true };
  assert.equal(C.loginExpired('.scratch/b', s, reportWith(['auth-failed'])), null);
});

// ---- reading, and remembering ----

const answerOf = (data) => ({ ok: true, repoRoot: 'C:/x', selected: '.scratch/b', status: data, statusError: null, all: { batches: [{ path: '.scratch/b' }] } });
function fake({ doctor, dry = 'sandbox', report = reportWith(['auth-failed']) } = {}) {
  const calls = { doctor: 0, report: [] };
  return {
    calls,
    doctor: async () => { calls.doctor++; if (doctor instanceof Error) throw doctor; return doctor; },
    report: async (b, o) => { calls.report.push([b, o]); if (report instanceof Error) throw report; return report; },
  };
}
const MISSING = doctorWith([row('fail', 'sbx is not on PATH, and FOREMAN_EXEC=sandbox needs it', 'Install sbx')]);

test('decorate: the login is read once for a run, and not at all when the last run did not end that way', async () => {
  const f = fake({ doctor: doctorWith([]) });
  const c = C.createConditions({ foreman: f, onChange: () => {} });
  const a = await c.decorate(answerOf(needsHuman()), { fresh: false });
  assert.equal(a.conditions.login.runId, '20261021T091200Z-4411');
  await c.decorate(answerOf(needsHuman()), { fresh: false });
  assert.equal(f.calls.report.length, 1, 'same run, same end: not asked again');
  assert.deepEqual(f.calls.report[0], ['.scratch/b', { run: '20261021T091200Z-4411' }]);

  const g = fake({ doctor: doctorWith([]) });
  const d = C.createConditions({ foreman: g, onChange: () => {} });
  const b = await d.decorate(answerOf(sample()), { fresh: false });
  assert.equal(b.conditions.login, null);
  assert.equal(g.calls.report.length, 0);
});

test('decorate: a failed report read is no login state, and is asked again next time', async () => {
  const f = fake({ doctor: doctorWith([]), report: new Error('boom') });
  const c = C.createConditions({ foreman: f, onChange: () => {} });
  assert.equal((await c.decorate(answerOf(needsHuman()), { fresh: false })).conditions.login, null);
  await c.decorate(answerOf(needsHuman()), { fresh: false });
  assert.equal(f.calls.report.length, 2);
});

test('decorate: runners are read in the background on a fresh read, and announced when they turn up', async () => {
  const f = fake({ doctor: MISSING });
  const changed = [];
  const c = C.createConditions({ foreman: f, onChange: (b) => changed.push(b) });
  const first = await c.decorate(answerOf(sample()), { fresh: true });
  assert.equal(first.conditions.runners, null, 'the overview does not wait for the doctor');
  await c.settled();
  assert.deepEqual(changed, ['.scratch/b']);
  const next = await c.decorate(answerOf(sample()), { fresh: false });
  assert.equal(next.conditions.runners.tool, 'sbx');
  assert.equal(f.calls.doctor, 1, 'a watcher tick does not ask the doctor again');
});

test('decorate: nothing is announced when the answer is the same as before', async () => {
  const f = fake({ doctor: MISSING });
  const changed = [];
  const c = C.createConditions({ foreman: f, onChange: (b) => changed.push(b) });
  await c.decorate(answerOf(sample()), { fresh: true }); await c.settled();
  await c.decorate(answerOf(sample()), { fresh: true }); await c.settled();
  assert.equal(f.calls.doctor, 2);
  assert.equal(changed.length, 1);
});

test('decorate: when sbx turns up, a fresh read clears the state and says so', async () => {
  let doc = MISSING;
  const f = { calls: {}, doctor: async () => doc, report: async () => reportWith([]) };
  const changed = [];
  const c = C.createConditions({ foreman: f, onChange: (b) => changed.push(b) });
  await c.decorate(answerOf(sample()), { fresh: true }); await c.settled();
  doc = doctorWith([row('ok', 'sbx (required by FOREMAN_EXEC=sandbox)')]);
  await c.decorate(answerOf(sample()), { fresh: true }); await c.settled();
  assert.equal(changed.length, 2);
  assert.equal((await c.decorate(answerOf(sample()), { fresh: false })).conditions.runners, null);
});

test('decorate: a doctor that fails to run is no state, and nothing is invented', async () => {
  const f = fake({ doctor: new Error('no bash') });
  const changed = [];
  const c = C.createConditions({ foreman: f, onChange: (b) => changed.push(b) });
  await c.decorate(answerOf(sample()), { fresh: true }); await c.settled();
  assert.equal(changed.length, 0);
  assert.equal((await c.decorate(answerOf(sample()), { fresh: false })).conditions.runners, null);
});

test('decorate: answers that are not of a readable batch get no conditions asked for', async () => {
  const f = fake({ doctor: MISSING });
  const c = C.createConditions({ foreman: f, onChange: () => {} });
  const bad = { ok: false, error: { kind: 'exit', message: 'm' } };
  assert.equal((await c.decorate(bad, { fresh: true })), bad);
  const noStatus = { ...answerOf(null), status: null, statusError: 'x' };
  assert.equal((await c.decorate(noStatus, { fresh: true })).conditions.runners, null);
  await c.settled();
  assert.equal(f.calls.doctor, 0);
});

test('decorate: a doctor answer for a batch the person has left is kept for that batch and not shown on another', async () => {
  const f = fake({ doctor: MISSING });
  const c = C.createConditions({ foreman: f, onChange: () => {} });
  await c.decorate(answerOf(sample()), { fresh: true }); await c.settled();
  const other = { ...answerOf(sample()), selected: '.scratch/c' };
  const got = await c.decorate(other, { fresh: false });
  assert.equal(got.conditions.runners, null);
});

test('decorate: the mode comes from the batch\'s foreman.conf and the environment, not from a row about another mode', async () => {
  const f = fake({ doctor: MISSING });
  const asked = [];
  const c = C.createConditions({ foreman: f, readConf: (b) => { asked.push(b); return 'FOREMAN_EXEC=local\n'; }, env: {}, onChange: () => {} });
  await c.decorate(answerOf(sample()), { fresh: true }); await c.settled();
  assert.deepEqual(asked, ['.scratch/b']);
  assert.equal((await c.decorate(answerOf(sample()), { fresh: false })).conditions.runners, null, 'sbx is missing, but this batch runs local');

  const g = C.createConditions({ foreman: fake({ doctor: MISSING }), readConf: () => 'FOREMAN_EXEC=local\n', env: { FOREMAN_EXEC: 'sandbox' }, onChange: () => {} });
  await g.decorate(answerOf(sample()), { fresh: true }); await g.settled();
  assert.equal((await g.decorate(answerOf(sample()), { fresh: false })).conditions.runners.mode, 'sandbox');
});
