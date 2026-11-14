// The one rule that decides what word an iteration of the run record is counted under.
//
// Shared by `foreman report` (foreman-report.cjs: the totals, and the word each iteration gets
// in `--json`) and by `foreman status --json` (foreman-json.cjs: the words of a ticket's runs), so
// the two cannot disagree. It is a module, not a copy, for exactly that reason: report is a script
// that runs when it is loaded, and status could only reuse its rule by running it.
//
// A record is one parsed line of foreman-runs.jsonl. Lines written before a field existed read
// back correctly: each rule falls back to what the older fields say.
'use strict';

// An iteration that committed work without landing its ticket, and without anything going
// wrong: the agent checkpointed a part-finished ticket and handed it off, and the loop
// continued the same ticket. Counting that as a failure would make the report contradict
// the feature — a ticket that legitimately chunks across three iterations would read as two
// failures plus a landing.
//
// `progressed` is recorded directly now; the fallback derives it from fields that were
// always there, so log lines written before it existed still read correctly.
const isProgressed = (r) =>
  r.progressed === true ||
  (r.progressed === undefined &&
    Boolean(r.committed) && !r.status_flipped && !r.is_error && !r.tree_dirty);

// A turn that ended cleanly with its work uncommitted and HEAD unmoved: it ran out of room
// before reaching its own checkpoint step, and the loop ran a checkpoint turn to salvage it
// rather than counting it as a failure. Not the same outcome as `progressed` — a stall
// commits nothing itself — so it gets its own bucket rather than folding into either
// `progressed` or `failed`.
const isStalled = (r) =>
  r.stalled === true ||
  (r.stalled === undefined &&
    Boolean(r.tree_dirty) && !r.committed && !r.status_flipped && !r.is_error);

// The checkpoint turn a stall triggers is recorded as its own row (`kind: "checkpoint"`),
// never folded into the iteration count it salvaged, and never classified as landed,
// progressed, stalled or failed — those are outcomes of an iteration the operator
// commissioned, and a checkpoint turn is not one. Its cost and tokens still count toward
// the totals: the run spent real money on it.
const isCheckpoint = (r) => r.kind === 'checkpoint';

// The word an iteration is counted under — the one place that decides it, for the report's totals and
// for the words `--json` gives each iteration (of `report` and of `status`). A checkpoint turn is its own word; of the rest an
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

module.exports = { isProgressed, isStalled, isCheckpoint, outcomeOf };
