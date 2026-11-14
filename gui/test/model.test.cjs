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

// ---- the ticket page (`status --json`, plus the files main read) ----

const { statsSample } = require('./sample.cjs');
const part = (f) => f.parts.map((p) => p.text).join('');
const fact = (page, label) => page.facts.find((f) => f.label === label);

// 03 landed after running; 05 is next; 07 is human, 07a checks it.
function withStats() {
  const s = sample();
  s.tickets[2].stats = statsSample();
  return s;
}

test('ticketNotes: the entries whose heading starts with the ticket\'s number, and nothing for 07 in 07a\'s', () => {
  const text = '# gui — notes\n\n## 07 — human ticket\n- waits\n\n## 07a — followup\n- reads\n\n## 08 — other\n- unrelated\n';
  const t07 = { name: '07-try-it', number: '07', slug: 'try-it' };
  const t07a = { name: '07a-followup', number: '07a', slug: 'followup' };
  assert.deepEqual(M.ticketNotes(text, t07), [{ title: '07 — human ticket', text: '- waits' }]);
  assert.deepEqual(M.ticketNotes(text, t07a), [{ title: '07a — followup', text: '- reads' }]);
  assert.deepEqual(M.ticketNotes(text, { name: '09-none', number: '09', slug: 'none' }), []);
});

test('ticketNotes: an entry that names the ticket in full anywhere in it, as a path or with DONE_, belongs to it', () => {
  const text = '## 16 — the model\n- ticket 03 should show models. See .scratch/gui/issues/DONE_03-ticket-page.md\n- 2026-10-03 is a date\n\n## 05 — report\n- plain, mentions 03 only as a number\n';
  const t = { name: '03-ticket-page', number: '03', slug: 'ticket-page' };
  assert.deepEqual(M.ticketNotes(text, t).map((n) => n.title), ['16 — the model']);
});

test('ticketNotes: a file with no headings is read a line at a time, by the number as a whole word', () => {
  const text = '2026-10-21 · 06 · 2/5 progressed\n2026-10-21 · 07 waits on a person\n2026-10-06 · 07a — not this one\n\n2026-10-21 · 06 · landed';
  assert.deepEqual(M.ticketNotes(text, { name: '06-x', number: '06', slug: 'x' }),
    [{ title: null, text: '2026-10-21 · 06 · 2/5 progressed' }, { title: null, text: '2026-10-21 · 06 · landed' }]);
  assert.deepEqual(M.ticketNotes(text, { name: '07-x', number: '07', slug: 'x' }).map((n) => n.text), ['2026-10-21 · 07 waits on a person']);
});

test('ticketNotes: nothing to read is no notes; the text before the first heading is no one\'s', () => {
  const t = { name: '03-x', number: '03', slug: 'x' };
  assert.deepEqual(M.ticketNotes(null, t), []);
  assert.deepEqual(M.ticketNotes('', t), []);
  assert.deepEqual(M.ticketNotes('03 mentioned in a preamble\n\n## 04 — x\n', t), []);
});

test('ticketNotes: markup in a note stays in it as characters, and the heading mark is the only thing taken off', () => {
  const evil = '<script>alert(1)</script>';
  const [n] = M.ticketNotes(`## 03 — ${evil}\n- ${evil}`, { name: '03-x', number: '03', slug: 'x' });
  assert.equal(n.title, `03 — ${evil}`);
  assert.equal(n.text, `- ${evil}`);
});

test('duration and tokens: how a run\'s time and size are worded', () => {
  assert.equal(M.duration(1710000), '28m 30s');
  assert.equal(M.duration(45000), '45s');
  assert.equal(M.duration(0), '0s');
  assert.equal(M.duration(3600000 + 125000), '1h 02m');
  assert.equal(M.duration(null), '');
  assert.equal(M.compact(310000), '310k');
  assert.equal(M.compact(46000), '46k');
  assert.equal(M.compact(1250000), '1.3M');
  assert.equal(M.compact(842), '842');
  assert.equal(M.compact(1500), '1.5k');
  assert.equal(M.compact(null), '0');
});

test('ticketPage: a human ticket — its chip, the facts strip, and the handoff in the right column', () => {
  const p = M.ticketPage(sample(), '07-try-it-on-a-real-repo', null);
  assert.equal(p.name, '07 try-it-on-a-real-repo');
  assert.deepEqual(p.chip, { cls: 'human', text: 'human' });
  assert.equal(part(fact(p, 'Status')), 'ready-for-human');
  assert.equal(part(fact(p, 'Blocked by')), 'nothing');
  assert.equal(part(fact(p, 'Checked by')), '07a followup-try-the-followup-skill');
  assert.equal(part(fact(p, 'Handoff')), '.scratch/b/handoff/07-try-it-on-a-real-repo.md');
  assert.equal(fact(p, 'Checks'), undefined);
  assert.equal(p.side.kind, 'handoff');
  assert.equal(p.side.reminder, 'Record where a secret is stored (a password manager entry, an env var name), never its value.');
  assert.equal(p.text, null);
  assert.deepEqual(p.notes, []);
});

test('ticketPage: the facts say whether each blocker has landed, and a human blocker is called out', () => {
  const s = sample();
  assert.deepEqual(fact(M.ticketPage(s, '05-document-human-tickets', null), 'Blocked by').parts,
    [{ text: '04', tone: '' }, { text: ' landed', tone: 'muted' }]);
  const a = M.ticketPage(s, '07a-followup-try-the-followup-skill', null);
  assert.deepEqual(fact(a, 'Blocked by').parts, [{ text: '07', tone: '' }, { text: ' human, not done', tone: 'rust' }]);
  s.tickets[5].blocked_by = '09';
  assert.deepEqual(fact(M.ticketPage(s, '06-doctor-human-warnings', null), 'Blocked by').parts, [{ text: '09', tone: '' }, { text: ' not landed yet', tone: 'muted' }]);
  s.tickets[5].blocked_by = 'the CLI, once it is built';
  assert.equal(part(fact(M.ticketPage(s, '06-doctor-human-warnings', null), 'Blocked by')), 'the CLI, once it is built');
});

test('ticketPage: an agent ticket that checks a human one — Checks, the followup chip, and what the loop knows', () => {
  const p = M.ticketPage(sample(), '07a-followup-try-the-followup-skill', null);
  assert.deepEqual(p.chip, { cls: 'followup', text: 'followup · checks 07' });
  assert.equal(part(fact(p, 'Checks')), '07 try-it-on-a-real-repo');
  assert.equal(fact(p, 'Handoff'), undefined);
  assert.equal(p.side.kind, 'knows');
  assert.deepEqual(p.side.rows, [['Iterations', 'none yet'], ['In flight', 'not known yet'], ['Sent back', 'no']]);
});

test('ticketPage: the next ticket has the chip next; a plain one has none', () => {
  assert.deepEqual(M.ticketPage(sample(), '05-document-human-tickets', null).chip, { cls: 'next', text: 'next' });
  assert.equal(M.ticketPage(sample(), '06-doctor-human-warnings', null).chip, null);
});

test('ticketPage: what the loop knows says what has been spent on a ticket that ran but did not land, and who sent it back', () => {
  const s = sample();
  s.tickets[4].stats = { ...statsSample(), iterations: 2, cost_usd: 1.64 };
  s.tickets[4].spent_usd = 1.64;
  s.next.sent_back_by = '07a-followup-try-the-followup-skill';
  s.run = { in_flight: false };
  const p = M.ticketPage(s, '05-document-human-tickets', null);
  assert.deepEqual(p.side.rows, [['Iterations', '2 · $1.64'], ['In flight', 'no'], ['Sent back', 'by 07a-followup-try-the-followup-skill']]);
  assert.equal(part(fact(p, 'Spend')), '$1.64 · 2 iterations');
});

test('ticketPage: a ticket that landed and ran shows its run stats, as the design\'s b3 words them', () => {
  const p = M.ticketPage(withStats(), '03-stop-on-waiting-human', null);
  assert.deepEqual(p.chip, { cls: 'landed', text: 'done' });
  assert.equal(p.side.kind, 'stats');
  assert.deepEqual(p.side.cards, [
    { k: 'Cost', v: '$4.62', mono: false }, { k: 'Runtime', v: '28m 30s', mono: false },
    { k: 'Model', v: 'claude-sonnet-5-5', mono: true }, { k: 'Iterations', v: '3', mono: false },
    { k: 'Turns', v: '112', mono: false }, { k: 'Tokens in / out', v: '310k / 46k', mono: true },
  ]);
  assert.equal(part(fact(p, 'Status')), 'done');
  assert.equal(fact(p, 'Status').parts[0].tone, 'ok');
  assert.equal(part(fact(p, 'Spend')), '$3.08 · 3 iterations');
});

test('ticketPage: one row for each line of the record, with the CLI\'s outcome word, and a checkpoint turn marked as one', () => {
  const rows = M.ticketPage(withStats(), '03-stop-on-waiting-human', null).side.iterations;
  assert.deepEqual(rows.map((r) => [r.n, r.outcome, r.tone, r.meta]), [
    ['1', 'progressed', '', '11m 15s · $1.64'],
    ['2', 'stalled', 'rust', '8m 10s · $1.48'],
    ['2', 'checkpoint', 'dim', '40s · $0.20'],
    ['3', 'landed', 'ok', '8m 25s · $1.30'],
  ]);
  assert.equal(rows[0].label, 'run 20261021T091200Z-4411');
  assert.equal(rows[2].label, 'run 20261021T091200Z-4411 · checkpoint turn');
});

test('ticketPage: several models are shown in the order they were used; none recorded is said, not guessed', () => {
  const s = withStats();
  s.tickets[2].stats.models = ['claude-sonnet-5-5', 'claude-opus-5-5'];
  assert.equal(M.ticketPage(s, '03-stop-on-waiting-human', null).side.cards[2].v, 'claude-sonnet-5-5 → claude-opus-5-5');
  s.tickets[2].stats.models = [];
  assert.equal(M.ticketPage(s, '03-stop-on-waiting-human', null).side.cards[2].v, 'not recorded');
});

test('ticketPage: a ticket that landed and never ran says none yet; a human one that landed shows its handoff and no stats', () => {
  const none = M.ticketPage(sample(), '02-handoff-file-path', null);
  assert.equal(none.side.kind, 'nostats');
  assert.equal(none.side.text, 'none yet');
  const s = withStats();
  s.tickets[6].done = true; s.tickets[6].state = 'done'; s.tickets[6].status = 'done';
  s.tickets[6].stats = statsSample();
  const human = M.ticketPage(s, '07-try-it-on-a-real-repo', null);
  assert.equal(human.side.kind, 'handoff');
  assert.equal(human.side.cards, undefined);
});

test('ticketPage: a human ticket with no Handoff: line says so instead of offering an editor', () => {
  const s = sample();
  s.tickets[6].handoff = null;
  const p = M.ticketPage(s, '07-try-it-on-a-real-repo', null);
  assert.equal(p.side.kind, 'handoff');
  assert.equal(p.side.path, null);
  assert.equal(fact(p, 'Handoff'), undefined);
});

test('ticketPage: the text and the notes come from what main read, the notes only the ticket\'s own', () => {
  const doc = { file: 'x', text: '# 07\n- [ ] a', progress: '## 06 — other\n- no\n\n## 07 — mine\n- yes\n', handoff: null };
  const p = M.ticketPage(sample(), '07-try-it-on-a-real-repo', doc);
  assert.equal(p.text, '# 07\n- [ ] a');
  assert.deepEqual(p.notes, [{ title: '07 — mine', text: '- yes' }]);
});

test('ticketPage: a ticket that is not in the batch (the loop renamed it, or it is gone) is null', () => {
  assert.equal(M.ticketPage(sample(), 'nope', null), null);
  assert.equal(M.ticketPage({ ...sample(), tickets: undefined }, '03-x', null), null);
});

// ---- the doctor ----

const { doctorSample } = require('./sample.cjs');

test('doctor: the sections come in the CLI\'s order, each row with the mark and tone the terminal gives its result', () => {
  const d = M.doctor(doctorSample('blocked'));
  assert.deepEqual(d.sections.map((s) => s.id), ['machine', 'repository', 'skill', 'batches']);
  assert.deepEqual(d.sections.map((s) => s.title), ['Machine', 'Repository', 'Skill', 'Batches']);
  assert.deepEqual(d.sections[1].rows.map((r) => [r.mark, r.tone]), [['■', 'ok'], ['■', 'ok'], ['■', 'ok']]);
  assert.deepEqual(d.sections[2].rows.map((r) => [r.mark, r.tone]), [['!', 'acc'], ['■', 'ok']], 'a warning is a !');
  assert.deepEqual(d.sections[3].rows.map((r) => [r.mark, r.tone]), [['■', 'ok'], ['✗', 'err']], 'a failure --fix cannot write needs you: ✗');
  assert.deepEqual(M.doctor(doctorSample()).sections[1].rows.map((r) => [r.mark, r.tone]), [['■', 'ok'], ['!', 'acc'], ['■', 'ok']], 'one --fix can write is a !');
});

test('doctor: a failure that --fix writes is marked auto, with its fix and the terminal\'s notes; a row that passed has neither', () => {
  const d = M.doctor(doctorSample());
  const bad = d.sections[1].rows[1];
  assert.equal(bad.label, 'foreman-runs.log not ignored');
  assert.equal(bad.auto, true);
  assert.equal(bad.fix, 'foreman doctor --fix appends it to .gitignore');
  assert.deepEqual(bad.notes, ['run state would show up as changes']);
  const fine = d.sections[1].rows[0];
  assert.equal(fine.fix, null);
  assert.equal(fine.auto, false);
});

test('doctor: a batch row keeps the detail after its name', () => {
  assert.equal(M.doctor(doctorSample()).sections[3].rows[0].detail, '3 of 14 done');
});

test('doctor: the stamp says what the CLI\'s verdict says, in the tone of passing or not', () => {
  assert.deepEqual(M.doctor(doctorSample()).stamp, { label: 'NOT PASSED', detail: '1 to fix', tone: 'err' });
  assert.deepEqual(M.doctor(doctorSample('blocked')).stamp, { label: 'NOT PASSED', detail: '1 blocker', tone: 'err' });
  assert.deepEqual(M.doctor(doctorSample('ready')).stamp, { label: 'PASSED', detail: 'ready to run', tone: 'ok' });
});

test('doctor: the next command is the CLI\'s, with its label; none when there is nothing foreman can do', () => {
  assert.deepEqual(M.doctor(doctorSample()).next, { label: 'fix', command: 'foreman doctor --fix' });
  assert.deepEqual(M.doctor(doctorSample('ready')).next, { label: 'next', command: 'foreman run .scratch/gui' });
  assert.equal(M.doctor(doctorSample('blocked')).next, null);
});

test('doctor: the legend names the marks that are on the sheet, and only those', () => {
  assert.deepEqual(M.doctor(doctorSample()).legend, [
    { mark: '■', tone: 'ok', text: 'passed' }, { mark: '!', tone: 'acc', text: '--fix can do it' }, { mark: '!', tone: 'acc', text: 'worth a look' },
  ]);
  assert.deepEqual(M.doctor(doctorSample('blocked')).legend.map((l) => l.text), ['passed', 'needs you', 'worth a look']);
  const clean = doctorSample('ready');
  clean.sections = clean.sections.filter((s) => s.id !== 'skill');
  assert.deepEqual(M.doctor(clean).legend.map((l) => l.text), ['passed']);
});

test('doctor: Fix what it can lists each file with the lines it will append and why, and is there only when there is something to append', () => {
  const d = M.doctor(doctorSample());
  assert.equal(d.fix.files.length, 1);
  assert.equal(d.fix.files[0].file, '.gitignore');
  assert.deepEqual(d.fix.files[0].lines, ['# Foreman: per-batch run state.', '**/.foreman-iter.bundle', '**/.foreman-stall-marker', '**/foreman-runs.jsonl', '**/foreman-runs.log']);
  assert.match(d.fix.files[0].why, /does not ignore foreman/);
  assert.equal(d.fix.summary, 'Appends 5 lines to .gitignore. Nothing else is written.');
  assert.equal(M.doctor(doctorSample('ready')).fix, null);
  assert.equal(M.doctor(doctorSample('blocked')).fix, null, 'a blocker --fix cannot write does not make the button appear');
});

test('doctor: the summary counts lines and files, in the singular too', () => {
  const doc = doctorSample();
  doc.plan = [
    { file: '.gitignore', text: 'a\nb\n', why: 'x' },
    { file: '.gitattributes', text: 'only\n', why: 'y' },
  ];
  assert.equal(M.doctor(doc).fix.summary, 'Appends 2 lines to .gitignore and 1 line to .gitattributes. Nothing else is written.');
});

test('doctor: after --fix, what was appended and where, and how many are left', () => {
  const doc = { ...doctorSample(), fix: { appended: [{ file: '.gitignore', text: 'a\nb\nc\n' }, { file: '.gitattributes', text: 'x\n' }], remaining: 0 } };
  const d = M.doctor(doc);
  assert.equal(d.applied.text, 'Appended 3 lines to .gitignore and 1 line to .gitattributes.');
  assert.equal(d.applied.then, 'Review the diff and commit it: a run refuses to start on a dirty tree.');
  assert.equal(M.doctor(doctorSample()).applied, null, 'nothing was appended unless --fix ran');
  assert.equal(M.doctor({ ...doctorSample(), fix: { appended: [], remaining: 0 } }).applied, null, 'and --fix that appended nothing says nothing');
});

test('doctor: the title says which repository, which build and when, as the terminal\'s does', () => {
  assert.equal(M.doctor(doctorSample()).meta, 'C:/Projects/app · foreman d0d6874 · 2026-10-21');
  assert.equal(M.doctor({ ...doctorSample(), rev: '', date: '' }).meta, 'C:/Projects/app');
});

test('doctor: info lines (a batch section with no batch) are kept, as plain lines', () => {
  const doc = doctorSample();
  doc.sections[3] = { id: 'batches', title: 'Batches', rows: [], info: ['none — no directory here has a foreman.conf.', 'Create one:  foreman init <batch-dir>'] };
  assert.deepEqual(M.doctor(doc).sections[3].info, ['none — no directory here has a foreman.conf.', 'Create one:  foreman init <batch-dir>']);
  assert.deepEqual(M.doctor(doc).sections[3].rows, []);
});
