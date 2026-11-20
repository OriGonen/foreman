// What the bash loop, the node helpers and the drawn scenes have to agree on, defined once.
//
// Foreman is bash and node, and several of its formats cross that line: the `key<TAB>value` facts
// the shell hands the renderers and `foreman-json.cjs`, the word an iteration is counted under, the
// numbers a run exits with. Before this file each node program kept its own copy of whatever it
// needed. Builtins only, no side effects when required: every program here may `require` it.
//
//   parseFacts(text [, { typed }])   the facts format, to an object (two shapes, see below)
//   progressedFrom / stalledFrom     the rules, from the raw inputs foreman-record.cjs has
//   isProgressed / isStalled / isCheckpoint / outcomeOf
//                                    the same rules over a recorded row, for report and --json
//   RUN_ENDS                         how a run ended, and the exit status that says so
//   guardStdout / writeOut           stdout that does not crash when the reader leaves early
'use strict';

// ---------------------------------------------------------------------------
// `key<TAB>value` facts
// ---------------------------------------------------------------------------

// The lines of a facts text: a blank line is nothing, and a CRLF is a line break (the shell may be
// bash on Windows).
function factLines(text) {
  return String(text).split('\n').map((raw) => raw.replace(/\r$/, '')).filter(Boolean);
}

// `key<TAB>value` lines to an object. A line with no tab is a key with no value. There are two
// shapes, because the two readers of this format always wanted different ones:
//
//   (default)        for the renderer: a key that repeats is a list, in order, and the object has no
//                    prototype (a fact may be named anything, `constructor` included).
//   { typed: true }  for `foreman status --json`: the keys it knows are read as what they are —
//                    `ticket` lines are collected into `tickets` (state, file, done, human, checks,
//                    handoff), `warning` lines into `warnings`, `until`, `done`, `total` and `humans`
//                    become numbers — and any other key keeps its last value, on a plain object.
function parseFacts(text, { typed = false } = {}) {
  if (!typed) {
    const facts = Object.create(null);
    for (const line of factLines(text)) {
      const tab = line.indexOf('\t');
      const key = tab < 0 ? line : line.slice(0, tab);
      const value = tab < 0 ? '' : line.slice(tab + 1);
      if (!(key in facts)) facts[key] = value;
      else facts[key] = [].concat(facts[key], value);
    }
    return facts;
  }
  const facts = { tickets: [], warnings: [] };
  for (const line of factLines(text)) {
    const f = line.split('\t');
    switch (f[0]) {
      case 'ticket':
        facts.tickets.push({
          state: f[1], file: f[2], done: f[3] === '1', human: f[4] === '1',
          checks: f[5] || null, handoff: f[6] || null,
        });
        break;
      case 'warning': facts.warnings.push(f.slice(1).join('\t')); break;
      case 'until': facts.until = { tickets: Number(f[1]), stop: f[2] }; break;
      case 'done': facts.done = Number(f[1]); break;
      case 'total': facts.total = Number(f[1]); break;
      case 'humans': facts.humans = Number(f[1]); break;
      default: facts[f[0]] = f.slice(1).join('\t');
    }
  }
  return facts;
}

// ---------------------------------------------------------------------------
// What word an iteration is counted under
// ---------------------------------------------------------------------------

// An iteration that committed work without landing its ticket, and without anything going
// wrong: the agent checkpointed a part-finished ticket and handed it off, and the loop
// continued the same ticket. Counting that as a failure would make the report contradict
// the feature — a ticket that legitimately chunks across three iterations would read as two
// failures plus a landing.
const progressedFrom = ({ committed, statusFlipped, isError, treeDirty }) =>
  Boolean(committed) && !statusFlipped && !isError && !treeDirty;

// A turn that ended cleanly with its work uncommitted and HEAD unmoved: it ran out of room
// before reaching its own checkpoint step, and the loop ran a checkpoint turn to salvage it
// rather than counting it as a failure. Not the same outcome as `progressed` — a stall
// commits nothing itself — so it gets its own bucket rather than folding into either
// `progressed` or `failed`.
const stalledFrom = ({ committed, statusFlipped, isError, treeDirty }) =>
  Boolean(treeDirty) && !committed && !statusFlipped && !isError;

// The same two rules over a recorded row (foreman-record.cjs's JSON line). `progressed` and `stalled`
// are recorded directly; the fallback derives them from fields that were always there, so log lines
// written before they existed still read correctly.
const inputsOf = (r) => ({
  committed: r.committed, statusFlipped: r.status_flipped, isError: r.is_error, treeDirty: r.tree_dirty,
});
const isProgressed = (r) =>
  r.progressed === true || (r.progressed === undefined && progressedFrom(inputsOf(r)));
const isStalled = (r) =>
  r.stalled === true || (r.stalled === undefined && stalledFrom(inputsOf(r)));

// The checkpoint turn a stall triggers is recorded as its own row (`kind: "checkpoint"`),
// never folded into the iteration count it salvaged, and never classified as landed,
// progressed, stalled or failed — those are outcomes of an iteration the operator
// commissioned, and a checkpoint turn is not one. Its cost and tokens still count toward
// the totals: the run spent real money on it.
const isCheckpoint = (r) => r.kind === 'checkpoint';

// The word an iteration is counted under — the one place that decides it, for the report's totals and
// for the words `--json` gives each iteration. A checkpoint turn is its own word; of the rest an
// iteration is landed, else stalled, else progressed, else unproductive. (An iteration that landed
// but also reported an error is `landed` here and is counted unproductive too, as it always was:
// the count adds `is_error` on top of the word.)
function outcomeOf(r) {
  if (isCheckpoint(r)) return 'checkpoint';
  if (r.status_flipped) return 'landed';
  if (isStalled(r)) return 'stalled';
  if (isProgressed(r)) return 'progressed';
  return 'unproductive';
}

// ---------------------------------------------------------------------------
// How a run ends
// ---------------------------------------------------------------------------

// The word for how a run ended and the exit status `foreman run` leaves with. (The GUI keeps its own
// copy: it never requires lib/.)
const RUN_ENDS = Object.freeze({ complete: 0, paused: 10, needs_human: 20, waiting_on_human: 30 });

// ---------------------------------------------------------------------------
// A stdout that survives its reader leaving
// ---------------------------------------------------------------------------

// `foreman report | head -1` closes the pipe while there may still be something to write; node then
// raises EPIPE on stdout, which unhandled is a stack trace. The reader has what it wanted, so stop
// quietly, with whatever exit status the program had set.
const guarded = new WeakSet();
function guardStdout(stream = process.stdout) {
  if (guarded.has(stream)) return;
  guarded.add(stream);
  stream.on('error', (err) => {
    if (err && err.code === 'EPIPE') process.exit();
    throw err;
  });
}

function writeOut(text) {
  guardStdout();
  process.stdout.write(text);
}

module.exports = {
  parseFacts, progressedFrom, stalledFrom, isProgressed, isStalled, isCheckpoint, outcomeOf,
  RUN_ENDS, guardStdout, writeOut,
};
