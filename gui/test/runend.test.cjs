'use strict';
// runend.js: how a run ended -> which scene, in the loop's own words. The app has no end-state logic of
// its own beyond this mapping, so every exit code the loop has is held here, from fixture `status --json`.
const test = require('node:test');
const assert = require('node:assert/strict');
const E = require('../runend.js');
const { sample, reportRunSample } = require('./sample.cjs');

const RUN = '20261022T140533Z-9020';
const rows = () => reportRunSample().run.iterations;

// status --json of the batch after the run, with the footer the loop wrote.
function after(end, exit, reason = null, over = {}) {
  const status = sample();
  status.last_run = { id: RUN, end, exit, reason };
  return Object.assign(status, over);
}
const choose = (status, over = {}) => E.choose({ status, runId: RUN, watched: '.scratch/b', rows: rows(), ...over });
const labels = (s) => s.actions.map((a) => a.label);
const action = (s, name) => s.actions.find((a) => a.do === name);

test('exit 0: done, with the sun risen, a flag for each landed ticket, and the report as the next step', () => {
  const status = after('complete', 0, null, { counts: { done: 10, total: 10 } });
  const s = choose(status);
  assert.equal(s.kind, 'scene');
  assert.equal(s.scene, 'done');
  assert.equal(s.code, 0);
  assert.equal(s.heading, 'The batch is done');
  assert.equal(s.art.flags, 10);
  assert.deepEqual(labels(s), ['Report', 'Show iterations']);
  assert.deepEqual(action(s, 'report').tag, { cls: 'free', text: 'free' });
  assert.equal(action(s, 'report').primary, true);
  assert.ok(s.facts.includes('10 of 10 landed'), s.facts);
  assert.ok(s.facts.includes('3 iterations'), 'the iterations the record has for this run, not the checkpoint turn: ' + s.facts);
  assert.ok(s.facts.includes('$4.25'), s.facts);
  assert.ok(s.facts.includes('28m30s') || s.facts.includes('29m'), s.facts);
});

test('exit 0 with the batch renamed to DONE_: the scene says done, and where the batch is now', () => {
  const status = after('complete', 0, null, { counts: { done: 10, total: 10 }, batch: { path: '.scratch/DONE_b', name: 'DONE_b' } });
  const s = choose(status);
  assert.equal(s.scene, 'done');
  assert.ok(s.facts.includes('now .scratch/DONE_b'), s.facts);
  assert.ok(!choose(after('complete', 0, null, { counts: { done: 10, total: 10 } })).facts.includes('now '), 'not renamed: nothing to say');
});

test('exit 0 with fewer landed than the batch has (every ticket the run could do is done) still flags what landed', () => {
  const s = choose(after('complete', 0, null, { counts: { done: 4, total: 10 } }));
  assert.equal(s.art.flags, 4);
});

test('exit 10: paused with the loop\'s reason, the next ticket, and Resume… marked costs money', () => {
  const s = choose(after('paused', 10, 'iteration budget reached'));
  assert.equal(s.scene, 'paused');
  assert.equal(s.code, 10);
  assert.equal(s.heading, 'Paused — iteration budget reached');
  assert.ok(s.sentence.includes('05 document-human-tickets'), s.sentence);
  assert.ok(s.sentence.includes('Nothing is lost'), s.sentence);
  assert.deepEqual(labels(s), ['Resume…', 'Dry run', 'Show iterations']);
  assert.deepEqual(action(s, 'resume').tag, { cls: 'paid', text: 'costs money' });
  assert.deepEqual(action(s, 'dry-run').tag, { cls: 'free', text: 'free' });
  assert.equal(action(s, 'resume').primary, true);
});

test('exit 10 with no reason in the log still says paused, in the loop\'s own default words', () => {
  assert.equal(choose(after('paused', 10, null)).heading, 'Paused — budget reached');
});

test('exit 20: needs a human, the # reason: line as the CLI wrote it, and open the ticket or the log', () => {
  const reason = "the review turn found changes outside the ticket's scope in lib/exec/ <b>and</b> committed nothing";
  const s = choose(after('needs_human', 20, reason));
  assert.equal(s.scene, 'problem');
  assert.equal(s.code, 20);
  assert.equal(s.heading, 'It needs you to look');
  assert.equal(s.message, reason, 'passed through untouched');
  assert.deepEqual(labels(s), ['Open ticket', 'Open the log', 'Doctor', 'Resume…', 'Show iterations']);
  assert.equal(action(s, 'open-file').file, 'batch/issues/04-fourth.md', 'the ticket the run last worked on');
  assert.equal(action(s, 'open-log').file, '.scratch/b/foreman-runs.log');
  assert.deepEqual(action(s, 'doctor').tag, { cls: 'free', text: 'free' });
  assert.deepEqual(action(s, 'resume').tag, { cls: 'paid', text: 'costs money' });
  assert.equal(action(s, 'resume').primary, undefined);
});

test('exit 20 with no iteration in the record opens the ticket the status says is next', () => {
  const s = choose(after('needs_human', 20, 'x'), { rows: [] });
  assert.equal(action(s, 'open-file').file, '.scratch/b/issues/05-document-human-tickets.md');
});

test('exit 20 with no reason line has no message, and no invented one', () => {
  const s = choose(after('needs_human', 20, null));
  assert.equal(s.message, null);
});

test('exit 20 where the login expired is the login-expired state of ticket 07, as it is on the overview', () => {
  const s = choose(after('needs_human', 20, 'the agent could not authenticate'), { login: { batch: '.scratch/b', runId: RUN, exit: 20, message: 'x' } });
  assert.equal(s.scene, 'problem');
  assert.equal(s.login, true, 'the view shows ticket 07\'s state in the scene\'s place');
  assert.deepEqual(labels(s), ['Show iterations']);
});

test('exit 30: waiting on a human, the human ticket, and a different set of next steps', () => {
  const s = choose(after('waiting_on_human', 30, '07-try-it-on-a-real-repo.md is a human ticket'));
  assert.equal(s.scene, 'human');
  assert.equal(s.code, 30);
  assert.equal(s.heading, 'Waiting on you: 07 try-it-on-a-real-repo');
  assert.equal(s.message, '07-try-it-on-a-real-repo.md is a human ticket');
  assert.deepEqual(labels(s), ['Fill in handoff', 'Open ticket in editor', 'Resume…', 'Show iterations']);
  assert.equal(action(s, 'handoff').file, '.scratch/b/issues/07-try-it-on-a-real-repo.md', 'the app opens that ticket\'s page');
  assert.equal(action(s, 'open-file').file, '.scratch/b/issues/07-try-it-on-a-real-repo.md');
  assert.deepEqual(action(s, 'resume').tag, { cls: 'paid', text: 'costs money' });
  assert.ok(s.sentence.includes('status line'), s.sentence);
});

test('exit 30: with no human ticket in the status the next ticket stands in, and nothing throws', () => {
  const status = after('waiting_on_human', 30, null);
  status.tickets = status.tickets.filter((t) => !t.human);
  const s = choose(status);
  assert.equal(s.scene, 'human');
  assert.ok(s.heading.startsWith('Waiting on you: '));
});

test('each scene has its own art, and exit 10 and exit 30 are the same sun', () => {
  const kinds = [['complete', 0], ['paused', 10], ['needs_human', 20], ['waiting_on_human', 30]].map(([end, exit]) => choose(after(end, exit, 'r')).art.kind);
  assert.deepEqual(kinds, ['done', 'paused', 'problem', 'human']);
});

test('a run whose footer is not its own (another run\'s, or none yet) is not told as an ending', () => {
  const other = sample();    // last_run is 20261021-2, paused
  assert.equal(choose(other), null, 'not this run\'s footer: nothing is decided from it');
});

test('a run with no closing line in the log is shown as text, with what the process said', () => {
  const s = choose(after(null, null), { exit: { code: 137, out: 'Killed' } });
  assert.equal(s.kind, 'text');
  assert.ok(s.heading.includes('without a closing line'), s.heading);
  assert.ok(s.said.includes('Killed') && s.said.includes('137'), s.said);
  assert.deepEqual(labels(s), ['Show iterations']);
});

test('a run the app started and never saw in flight is told by the footer that is new since it began', () => {
  const status = after('paused', 10, 'time cap reached');
  const s = E.choose({ status, runId: null, before: '20261021-2', watched: '.scratch/b', rows: [] });
  assert.equal(s.scene, 'paused');
  assert.equal(s.heading, 'Paused — time cap reached');
  assert.equal(E.choose({ status: sample(), runId: null, before: '20261021-2', watched: '.scratch/b', rows: [] }), null, 'the same footer as before: no run happened');
});

test('a status with no last run decides nothing', () => {
  const status = sample();
  status.last_run = null;
  assert.equal(E.choose({ status, runId: RUN, watched: '.scratch/b', rows: [] }), null);
  assert.equal(E.choose({ status: null, runId: RUN, watched: '.scratch/b', rows: [] }), null);
});

test('the exit code in the footer, not a guess, picks the scene: an end word the loop does not have is text', () => {
  const s = choose(after('exploded', 99, 'boom'));
  assert.equal(s.kind, 'text');
  assert.ok(s.said.includes('boom'));
});

test('a batch with no tickets landed has no flags, and the facts line does not claim any iterations it cannot count', () => {
  const s = choose(after('complete', 0, null, { counts: { done: 0, total: 0 } }), { rows: [] });
  assert.equal(s.art.flags, 0);
  assert.ok(!/NaN|undefined/.test(s.facts), s.facts);
});

test('a ticket the loop renamed to DONE_ since the iteration was recorded is opened under its current name', () => {
  const status = after('needs_human', 20, 'x');
  const t = status.tickets.find((x) => x.number === '05');
  t.file = '.scratch/b/issues/DONE_05-document-human-tickets.md';
  const s = choose(status, { rows: [{ iteration: 1, kind: 'iteration', ticket: '.scratch/b/issues/05-document-human-tickets.md', outcome: 'unproductive' }] });
  assert.equal(action(s, 'open-file').file, '.scratch/b/issues/DONE_05-document-human-tickets.md');
  const gone = choose(after('needs_human', 20, 'x'), { rows: [{ iteration: 1, kind: 'iteration', ticket: 'batch/issues/99-unknown.md' }] });
  assert.equal(action(gone, 'open-file').file, 'batch/issues/99-unknown.md', 'a ticket the status does not list is opened as recorded');
});

test('exit 20\'s fixed words point at what the next steps offer, and promise nothing about the work in the tree', () => {
  const s = choose(after('needs_human', 20, 'x'));
  assert.equal(s.sentence, 'Look at the ticket and the log, then resume.');
});
