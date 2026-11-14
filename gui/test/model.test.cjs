'use strict';
// model.js: what the overview draws, worked out from `foreman status --json`. The page only turns
// this into elements, so what a person sees is decided — and tested — here.
const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('../model.js');

const { sample, dryRunSample, reportSample, reportByTicketSample, reportRunSample } = require('./sample.cjs');

test('stakes: one character per ticket, in order — landed, next, human, followup, to go', () => {
  assert.equal(M.stakes(sample().tickets), 'dddd>.hf..');
});

test('the dome is sized by tickets landed, and has nothing to divide by when the batch is empty', () => {
  const o = M.overview(sample());
  assert.equal(o.dome.landed, 4);
  assert.equal(o.dome.total, 10);
  assert.equal(o.dome.toGo, 6);
  assert.equal(o.dome.p, 0.4);
  assert.equal(M.overview({ ...sample(), counts: { done: 0, total: 0 }, tickets: [] }).dome.p, 0);
  assert.equal(M.overview({ ...sample(), counts: { done: 10, total: 10 } }).dome.p, 1);
});

test('spend: dollars and the number of runs, nothing at all for a batch that never ran', () => {
  assert.equal(M.overview(sample()).spent, '$9.84 spent in 2 runs');
  assert.equal(M.overview({ ...sample(), runs: 1, spent_usd: 0.5 }).spent, '$0.50 spent in 1 run');
  assert.equal(M.overview({ ...sample(), runs: 0, spent_usd: null }).spent, null);
  assert.equal(M.usd(1.12), '$1.12');
  assert.equal(M.usd(0), '$0.00');
  assert.equal(M.usd(null), '');
});

test('the next ticket: its name, who it waits for, how the last run ended', () => {
  const n = M.overview(sample()).next;
  assert.equal(n.name, '05 document-human-tickets');
  assert.equal(n.file, '.scratch/b/issues/05-document-human-tickets.md');
  assert.deepEqual(n.blockedBy, [{ ref: '04', landed: true }]);
  assert.equal(n.lastRun, '20261021-2 · paused: iteration budget reached');
  assert.equal(n.sentBackBy, null);
});

test('blocked by: a ticket still to land is not marked landed, free text is kept whole, and "None" is no blocker', () => {
  const s = sample();
  s.next = { ...s.next, file: s.tickets[7].file };
  s.tickets[7].state = 'next';
  assert.deepEqual(M.overview(s).next.blockedBy, [{ ref: '07', landed: false }]);
  const s2 = sample();
  s2.tickets[4].blocked_by = '02, 99';
  assert.deepEqual(M.overview(s2).next.blockedBy, [{ ref: '02', landed: true }, { ref: '99', landed: false }]);
  s2.tickets[4].blocked_by = '02 and the design review';
  assert.deepEqual(M.overview(s2).next.blockedBy, [{ text: '02 and the design review' }]);
  const s3 = sample();
  s3.tickets[4].blocked_by = 'None — can start immediately';
  assert.deepEqual(M.overview(s3).next.blockedBy, []);
  s3.tickets[4].blocked_by = null;
  assert.deepEqual(M.overview(s3).next.blockedBy, []);
});

test('no next ticket (everything landed, or nothing to run): the card says so rather than being empty', () => {
  const s = sample();
  s.next = null;
  assert.equal(M.overview(s).next, null);
});

test('last run: an id with no end is a run that has not finished', () => {
  const s = sample();
  s.last_run = { id: '20261022-1', end: null, exit: null, reason: null };
  assert.equal(M.overview(s).next.lastRun, '20261022-1 · no closing line');
  s.last_run = null;
  assert.equal(M.overview(s).next.lastRun, null);
  s.last_run = { id: 'r', end: 'needs_human', exit: 20, reason: 'red flag' };
  assert.equal(M.overview(s).next.lastRun, 'r · stopped: needs a human — red flag');
  s.last_run = { id: 'r', end: 'waiting_on_human', exit: 30, reason: null };
  assert.equal(M.overview(s).next.lastRun, 'r · stopped: waiting on a human');
  s.last_run = { id: 'r', end: 'complete', exit: 0, reason: null };
  assert.equal(M.overview(s).next.lastRun, 'r · complete');
});

test('the human ticket that is waiting: the first human ticket not landed, named by the run-until note', () => {
  const h = M.overview(sample()).human;
  assert.equal(h.name, '07 try-it-on-a-real-repo');
  assert.equal(h.handoff, '.scratch/b/handoff/07-try-it-on-a-real-repo.md');
  assert.equal(h.remaining, 1);
  assert.equal(h.note, 'The loop will run 2 ticket(s), then stop at 07-try-it-on-a-real-repo.md for a human.');
});

test('no human ticket ahead: no card, even though the note may be there', () => {
  const s = sample();
  s.tickets[6].human = false;
  s.human_remaining = 0;
  s.run_until = null;
  assert.equal(M.overview(s).human, null);
});

test('a human ticket that is next: the note is the run-until sentence, and the card still names it', () => {
  const s = sample();
  for (let i = 4; i < 6; i++) { s.tickets[i].state = 'done'; s.tickets[i].done = true; }
  s.tickets[6].state = 'next';
  s.next = { file: s.tickets[6].file, human: true, handoff: s.tickets[6].handoff, sent_back_by: '07a-followup-try-the-followup-skill' };
  s.run_until = null;
  const o = M.overview(s);
  assert.equal(o.human.name, '07 try-it-on-a-real-repo');
  assert.equal(o.human.note, null);
  assert.equal(o.next.sentBackBy, '07a-followup-try-the-followup-skill');
});

test('the order: a row for each ticket — glyph, chip, spend, and where a human ticket\'s handoff is', () => {
  const rows = M.overview(sample()).rows;
  assert.equal(rows.length, 10);
  assert.deepEqual(rows[0], { file: '.scratch/b/issues/01-human-ticket-status.md', num: '01', slug: 'human-ticket-status', kind: 'done', glyph: '✓', chip: null, meta: '$1.12' });
  assert.deepEqual(rows[4], { file: '.scratch/b/issues/05-document-human-tickets.md', num: '05', slug: 'document-human-tickets', kind: 'next', glyph: '▶', chip: { cls: 'next', text: 'next' }, meta: '' });
  assert.deepEqual(rows[5], { file: '.scratch/b/issues/06-doctor-human-warnings.md', num: '06', slug: 'doctor-human-warnings', kind: 'todo', glyph: '·', chip: null, meta: '' });
  assert.equal(rows[6].glyph, '✋');
  assert.deepEqual(rows[6].chip, { cls: 'human', text: 'human' });
  assert.equal(rows[6].meta, '07-try-it-on-a-real-repo.md');
  assert.deepEqual(rows[7].chip, { cls: 'followup', text: 'followup · checks 07' });
});

test('a landed ticket that cost nothing shows no spend, and one that cost $0 shows it', () => {
  const s = sample();
  s.tickets[0].spent_usd = null;
  s.tickets[1].spent_usd = 0;
  const rows = M.overview(s).rows;
  assert.equal(rows[0].meta, '');
  assert.equal(rows[1].meta, '$0.00');
});

test('a followup\'s chip names the ticket it checks by number, even when the name has no number', () => {
  assert.equal(M.checksChip('01-sign-off-the-picked-designs.md'), 'followup · checks 01');
  assert.equal(M.checksChip('ghost.md'), 'followup · checks ghost');
  assert.equal(M.checksChip('DONE_07a-x.md'), 'followup · checks 07a');
});

test('warnings are the CLI\'s own lines, unchanged', () => {
  const s = sample();
  s.warnings = ['warning: batch/issues/05-ticket.md Checks: ghost.md, which is not a ticket in this batch'];
  assert.deepEqual(M.overview(s).warnings, s.warnings);
});

test('the rail: every batch, landed finished ones last and dimmed, progress as a fraction', () => {
  const all = { batches: [
    { path: '.scratch/DONE_old', name: 'DONE_old', finished: true, counts: null, human_remaining: null, next: null, error: null },
    { path: '.scratch/a', name: 'a', finished: false, counts: { done: 1, total: 4 }, human_remaining: 0, next: 'x', error: null },
    { path: '.scratch/broken', name: 'broken', finished: false, counts: null, human_remaining: null, next: null, error: 'foreman-next.sh: boom' },
    { path: '.scratch/b', name: 'b', finished: false, counts: { done: 0, total: 0 }, human_remaining: 0, next: null, error: null },
  ] };
  const rail = M.rail(all, '.scratch/a');
  assert.deepEqual(rail.map((r) => r.path), ['.scratch/a', '.scratch/broken', '.scratch/b', '.scratch/DONE_old']);
  assert.deepEqual(rail[0], { path: '.scratch/a', name: 'a', label: '1/4', frac: 0.25, on: true, done: false, error: null });
  assert.equal(rail[1].error, 'foreman-next.sh: boom');
  assert.equal(rail[1].label, '!');
  assert.equal(rail[2].frac, 0);
  assert.deepEqual([rail[3].done, rail[3].label, rail[3].on], [true, '✓', false]);
});

test('which batch to show: the one asked for, else the first with work to do, else the first', () => {
  const b = (path, finished, error = null) => ({ path, name: path.split('/').pop(), finished, error, counts: error ? null : { done: 0, total: 1 } });
  const all = { batches: [b('x/DONE_old', true), b('x/b', false), b('x/c', false)] };
  assert.equal(M.pickBatch(all, 'x/c'), 'x/c');
  assert.equal(M.pickBatch(all, null), 'x/b');
  assert.equal(M.pickBatch({ batches: [b('x/DONE_old', true)] }, null), 'x/DONE_old');
  assert.equal(M.pickBatch({ batches: [] }, null), null);
  assert.equal(M.pickBatch({ batches: [b('x/bad', false, 'boom'), b('x/b', false)] }, null), 'x/b');
});

test('which batch to show after the loop renamed it to DONE_: follow it, and do not follow a different batch', () => {
  const b = (path, finished) => ({ path, name: path.split('/').pop(), finished, counts: null });
  // `.scratch/gui` finished and became `.scratch/DONE_gui`
  const all = { batches: [b('.scratch/DONE_gui', true), b('.scratch/other', false)] };
  assert.equal(M.pickBatch(all, '.scratch/gui'), '.scratch/DONE_gui');
  // a finished batch whose name merely ends the same way in another directory is not it
  const elsewhere = { batches: [b('.other/DONE_gui', true), b('.scratch/other', false)] };
  assert.equal(M.pickBatch(elsewhere, '.scratch/gui'), '.scratch/other');
  // a name that is only a suffix ("gui" vs "xgui") is not it either
  const suffix = { batches: [b('.scratch/DONE_xgui', true), b('.scratch/other', false)] };
  assert.equal(M.pickBatch(suffix, '.scratch/gui'), '.scratch/other');
});

test('the title: the batch path, as the design shows it', () => {
  assert.equal(M.overview(sample()).title, '.scratch/b');
});

// ---- the dry run ----

test('dry run: the tickets a run would take, in order, the first marked next, a followup says what it checks', () => {
  const d = M.dryRun(dryRunSample());
  assert.deepEqual(d.would.map((r) => [r.num, r.slug, r.kind, r.glyph]), [
    ['05', 'document-human-tickets', 'next', '▶'],
    ['06', 'doctor-human-warnings', 'todo', ''],
  ]);
  assert.equal(d.summary, '2 would run');
  const f = dryRunSample();
  f.would_run.tickets.push({ ...f.would_run.remaining[3] });
  assert.deepEqual(M.dryRun(f).would[2].chip, { cls: 'followup', text: 'followup · checks 07' });
});

test('dry run: the human ticket the run stops at, and whether the budget gets that far', () => {
  assert.equal(M.dryRun(dryRunSample()).stop.text, 'then the run stops at 07 try-it-on-a-real-repo, a human ticket');
  const short = dryRunSample();
  short.would_run.stops_at.reached = false;
  assert.equal(M.dryRun(short).stop.text, 'the iteration budget ends the run before 07 try-it-on-a-real-repo, a human ticket');
  const first = dryRunSample();
  first.would_run.tickets = [];
  assert.equal(M.dryRun(first).stop.text, 'the run stops at 07 try-it-on-a-real-repo, a human ticket', 'nothing before it, so not "then"');
  const none = dryRunSample();
  none.would_run.stops_at = null;
  assert.equal(M.dryRun(none).stop, null);
});

test('dry run: the dome counts what has landed and marks every ticket still to do, as the overview does', () => {
  const d = M.dryRun(dryRunSample());
  assert.deepEqual([d.dome.landed, d.dome.total, d.dome.toGo, d.dome.p], [4, 10, 6, 0.4]);
  assert.equal(d.dome.stakes, 'dddd>.hf..');
  assert.equal(M.dryRun({ ...dryRunSample(), counts: { done: 0, total: 0 }, would_run: { tickets: [], remaining: [], stops_at: null } }).dome.p, 0);
});

test('dry run: the settings, in the order the terminal prints them, with unlimited for a budget that has no limit', () => {
  const d = M.dryRun(dryRunSample());
  assert.deepEqual(d.settings, [
    ['exec', 'local'], ['perms', 'acceptEdits'], ['model', 'claude-sonnet-5-5'], ['effort', 'high'], ['live', 'off'],
    ['budgets', 'cost $25 · time 90m · iterations unlimited'],
    ['logs', ['.scratch/b/foreman-runs.jsonl', '.scratch/b/foreman-runs.log']],
  ]);
  const f = dryRunSample();
  f.settings.live = true;
  f.settings.budgets = { cost_usd: null, minutes: null, iterations: 1, text: '' };
  const g = M.dryRun(f).settings;
  assert.deepEqual(g.find((r) => r[0] === 'live'), ['live', 'on']);
  assert.deepEqual(g.find((r) => r[0] === 'budgets'), ['budgets', 'cost unlimited · time unlimited · iterations 1']);
});

test('dry run: the prompt is the CLI\'s text, untouched, with one number a line and the count in the label', () => {
  const doc = dryRunSample();
  const d = M.dryRun(doc);
  assert.equal(d.prompt.text, doc.prompt.text, 'not trimmed, not reflowed');
  assert.equal(d.prompt.label, 'Prompt for 05 · 7 lines');
  assert.equal(d.prompt.numbers, '1\n2\n3\n4\n5\n6\n7');
  doc.prompt = { for: doc.prompt.for, text: 'one line', lines: 1 };
  assert.equal(M.dryRun(doc).prompt.label, 'Prompt for 05 · 1 line');
  assert.equal(M.dryRun(doc).prompt.numbers, '1');
});

test('dry run: no prompt when a human ticket is next, or nothing is left — and the screen says why', () => {
  const human = dryRunSample();
  human.prompt = null;
  human.would_run.tickets = [];
  human.would_run.remaining = human.would_run.remaining.slice(2);
  assert.equal(M.dryRun(human).prompt, null);
  assert.equal(M.dryRun(human).nothing, '07 try-it-on-a-real-repo is a human ticket, and it is next. A run stops there, so no prompt would be sent.');
  const done = dryRunSample();
  done.prompt = null;
  done.would_run = { tickets: [], remaining: [], stops_at: null };
  assert.equal(M.dryRun(done).nothing, 'Every ticket in this batch has landed. Nothing would run.');
  assert.equal(M.dryRun(done).summary, 'nothing would run');
});

test('dry run: warnings are the CLI\'s own lines, unchanged', () => {
  const doc = dryRunSample();
  doc.warnings = ['batch/issues/05-ticket.md Checks: ghost.md, which is not a ticket in this batch'];
  assert.deepEqual(M.dryRun(doc).warnings, doc.warnings);
});

// ---- the report (`foreman report --json`) ----

test('report: the bill is the totals as the CLI counted them, in the words the plain report uses', () => {
  const r = M.report(reportSample());
  assert.equal(r.title, 'batch');
  assert.equal(r.bill.total, '$6.95');
  assert.equal(r.bill.exact, '$6.9500', 'the figure the plain report prints, for the tooltip');
  assert.equal(r.bill.sub, '3 runs · 7 iterations · 48.2 model-minutes · 1 unreadable line');
  assert.deepEqual(r.bill.outcomes.map((o) => [o.label, o.value, o.tone]), [
    ['landed', '3', 'ok'], ['progressed', '1', ''], ['stalled', '1', ''], ['unproductive', '2', ''],
    ['checkpoint turns', '1', ''], ['limit hits', '1', 'rust'],
  ]);
  assert.deepEqual(r.bill.tokens.map((o) => [o.label, o.value]), [
    ['billed tokens', '167,500'], ['cache read', '5,820,000'], ['cache write', '432,000'], ['turns', '220'],
  ]);
  assert.equal(r.bill.tokens[0].hint, 'in 21,200 · out 146,300', 'billed is input plus output; the tooltip says so');
  assert.deepEqual([r.bill.perIteration, r.bill.perIterationHint], ['$0.99', '23,929 billed tokens']);
});

test('report: like the plain report, a count that is zero is left out, except landed and unproductive', () => {
  const doc = reportSample();
  Object.assign(doc.totals, { runs: 1, iterations: 1, landed: 1, progressed: 0, stalled: 0, unproductive: 0, checkpoints: 0, limit_hits: 0, unreadable: 0 });
  const r = M.report(doc);
  assert.deepEqual(r.bill.outcomes.map((o) => o.label), ['landed', 'unproductive']);
  assert.equal(r.bill.sub, '1 run · 1 iteration · 48.2 model-minutes', 'singular, and nothing about unreadable lines when there were none');
});

test('report: a log of checkpoint turns only has no per-iteration figure, and says so by leaving it out', () => {
  const doc = reportSample();
  Object.assign(doc.totals, { iterations: 0, per_iteration: null });
  const r = M.report(doc);
  assert.equal(r.bill.perIteration, null);
  assert.equal(r.bill.perIterationHint, null);
});

test('report: the ledger is one row per run, newest first, with a cost bar relative to the dearest run', () => {
  const r = M.report(reportSample());
  assert.equal(r.by, 'run');
  assert.deepEqual(r.rows.map((x) => x.id), ['20261023T081014Z-1207', '20261022T140533Z-9020', '20261021T091200Z-4411']);
  const mid = r.rows[1];
  assert.deepEqual([mid.label, mid.title, mid.cost, mid.exact, mid.expandable], ['20261022T140533Z-9020', 'started 2026-10-22T14:05:33Z', '$4.25', '$4.2500', true]);
  assert.deepEqual(mid.parts.map((p) => [p.text, p.tone]), [
    ['3', ''], ['1 landed', 'ok'], ['1 progressed', ''], ['1 unproductive', ''], ['limit hit', 'rust'], ['1 checkpoint turn', 'dim'],
  ]);
  assert.equal(mid.frac, 1, 'the dearest run is a full bar');
  assert.equal(r.rows[2].frac, 2 / 4.25);
  assert.ok(r.rows[0].frac > 0.15 && r.rows[0].frac < 0.17);
});

test('report: a run of checkpoint turns only reads "0 · 1 checkpoint turn", and a tiny cost still shows a bar', () => {
  const doc = reportSample();
  doc.rows = [{ ...doc.rows[0], iterations: 0, landed: 0, checkpoints: 2, limit_hits: 3, cost_usd: 0.001 }, { ...doc.rows[1], cost_usd: 100 }];
  const [small] = M.report(doc).rows.slice().reverse();
  assert.deepEqual(small.parts.map((p) => p.text), ['0', '3 limit hits', '2 checkpoint turns']);
  assert.equal(small.frac, 0.02, 'never rounded away to nothing');
  doc.rows[0].cost_usd = 0;
  assert.equal(M.report(doc).rows.at(-1).frac, 0);
  doc.rows.forEach((x) => { x.cost_usd = 0; });
  assert.equal(M.report(doc).rows[0].frac, 0, 'no division by a cost of nothing');
});

test('report: by ticket the rows are the tickets in the order first attempted, named as the order names them, and do not expand', () => {
  const r = M.report(reportByTicketSample());
  assert.equal(r.by, 'ticket');
  assert.deepEqual(r.rows.map((x) => x.label), ['01 first', '02 second', '03 third', '04 fourth', '05 fifth']);
  assert.equal(r.rows[3].title, 'batch/issues/04-fourth.md');
  assert.ok(r.rows.every((x) => x.expandable === false));
  assert.equal(M.report({ ...reportByTicketSample(), rows: [{ ...reportByTicketSample().rows[0], id: 'batch/issues/DONE_07a-followup-x.md' }] }).rows[0].label, '07a followup-x');
  assert.equal(M.report({ ...reportByTicketSample(), rows: [{ ...reportByTicketSample().rows[0], id: '(unknown)' }] }).rows[0].label, '(unknown)');
});

test('report: an iteration is its number, its ticket and the CLI\'s outcome word, whole; what went wrong is beside it', () => {
  const its = M.reportIterations(reportRunSample());
  assert.deepEqual(its.map((i) => i.label), [
    '1 · 03 third · progressed', '2 · 03 third · landed', '3 · 04 fourth · unproductive (error, limit)', '3 · 04 fourth · checkpoint',
  ]);
  assert.deepEqual(its.map((i) => i.cost), ['$2.00', '$1.50', '$0.50', '$0.25']);
  assert.deepEqual(its.map((i) => i.tone), ['', 'ok', 'rust', 'dim']);
  assert.equal(its[2].exact, '$0.5000');
  assert.equal(its[2].limit, true);
});

test('report: the app has no outcome logic: a word it does not know is shown as it came, and nothing is worked out from the flags', () => {
  const doc = reportRunSample();
  doc.run.iterations = [{ ...doc.run.iterations[0], outcome: 'melted', flags: [], limit_hit: false, ticket: null }];
  const [i] = M.reportIterations(doc);
  assert.equal(i.label, '1 · (no ticket) · melted');
  assert.equal(i.tone, '');
  assert.deepEqual(M.reportIterations(reportSample()), [], 'no run asked for: no iterations');
});
