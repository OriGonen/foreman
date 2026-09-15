// Reads a ralph batch's run log and prints what it cost.
//
//   ralph report <batch>              totals, then per run
//   ralph report <batch> --by-ticket  totals, then per ticket
//   ralph report <batch> --failures   only the iterations that
//                                                           errored, did not land, or
//                                                           hit a limit
//
// <batch> is the batch directory (the one with ralph.conf in it); the log is its
// ralph-runs.jsonl. Give an explicit path with `--jsonl <file>` if a batch's ralph.conf
// moved it. If <batch> is omitted, the batch is inferred when the repo has exactly one.
//
// THIS IS A MANUAL TOOL. The loop never runs it and never reads the log — the log is
// append-only telemetry, and the tickets' Status lines are the only thing the loop treats
// as state. Truncate or delete the log and the loop behaves identically.

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const valueOf = (name) => {
  const i = argv.indexOf(`--${name}`);
  return i !== -1 && i + 1 < argv.length ? argv[i + 1] : null;
};

const mode = flag('by-ticket') ? 'by-ticket' : flag('failures') ? 'failures' : 'by-run';

// Everything else in the toolkit speaks forward slashes, including the paths inside the
// log itself. Windows' path.join would be the only backslash on screen.
const show = (p) => String(p).split('\\').join('/');

// Everything that is not a flag or a flag's value is the batch directory.
const consumed = new Set();
for (const name of ['jsonl']) {
  const i = argv.indexOf(`--${name}`);
  if (i !== -1) { consumed.add(i); consumed.add(i + 1); }
}
const positional = argv.filter((a, i) => !a.startsWith('--') && !consumed.has(i));

function repoRoot() {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim();
  } catch {
    return process.cwd();
  }
}

// The one answer to "which directories are ralph batches" — shells out to the same
// ralph_find_batches the bash scripts use, so an omitted batch means the same thing here
// as it does everywhere else in the toolkit.
function soleBatch(root) {
  let out;
  try {
    out = execFileSync(
      'bash',
      ['-c', 'source "$1/ralph-repo.sh" && ralph_find_batches "$2"', 'bash', __dirname, root],
      { encoding: 'utf8' }
    );
  } catch {
    return [];
  }
  return out
    .split('\n')
    .map((s) => s.trim())
    .filter(Boolean)
    .map((rel) => (rel === '.' ? root : path.join(root, ...rel.split('/'))));
}

let jsonlPath = valueOf('jsonl');
if (!jsonlPath) {
  let batch = positional[0];
  if (!batch) {
    const root = repoRoot();
    const found = soleBatch(root);
    if (found.length === 1) {
      batch = found[0];
    } else {
      console.error(
        found.length === 0
          ? `No batch given and no ralph.conf found under ${root}.`
          : `No batch given, and ${found.length} directories have a ralph.conf:\n  ` +
            found.map((d) => show(path.relative(root, d))).join('\n  ')
      );
      console.error('Usage: ralph report <batch> [--by-ticket|--failures]');
      process.exit(1);
    }
  }
  jsonlPath = path.join(batch, 'ralph-runs.jsonl');
}

if (!fs.existsSync(jsonlPath)) {
  console.error(`No run log at ${show(jsonlPath)} — nothing has been run for this batch yet.`);
  process.exit(1);
}

const records = [];
let malformed = 0;
for (const line of fs.readFileSync(jsonlPath, 'utf8').split('\n')) {
  if (!line.trim()) continue;
  try {
    records.push(JSON.parse(line));
  } catch {
    malformed++;
  }
}

if (records.length === 0) {
  console.error(`${show(jsonlPath)} has no readable records.`);
  process.exit(1);
}

const n = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : 0);
const fmt = (v) => n(v).toLocaleString('en-US');
const usd = (v) => `$${n(v).toFixed(4)}`;

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

function blank() {
  return {
    iterations: 0,
    landed: 0,
    progressed: 0,
    stalled: 0,
    checkpoints: 0,
    failed: 0,
    limitHits: 0,
    cost: 0,
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    durationMs: 0,
    turns: 0
  };
}

function add(acc, r) {
  const t = r.tokens || {};
  if (isCheckpoint(r)) {
    acc.checkpoints++;
  } else {
    acc.iterations++;
    if (r.status_flipped) acc.landed++;
    else if (isStalled(r)) acc.stalled++;
    else if (isProgressed(r)) acc.progressed++;
    if (r.is_error || (!r.status_flipped && !isProgressed(r) && !isStalled(r))) acc.failed++;
  }
  if (r.limit_hit) acc.limitHits++;
  acc.cost += n(r.cost_usd);
  acc.input += n(t.input);
  acc.output += n(t.output);
  acc.cacheRead += n(t.cache_read);
  acc.cacheWrite += n(t.cache_creation);
  acc.durationMs += n(r.duration_ms);
  acc.turns += n(r.num_turns);
  return acc;
}

function describe(acc) {
  const billed = acc.input + acc.output;
  return [
    `  iterations ${acc.iterations}  ·  landed ${acc.landed}` +
      (acc.progressed ? `  ·  progressed ${acc.progressed}` : '') +
      (acc.stalled ? `  ·  stalled ${acc.stalled}` : '') +
      `  ·  unproductive ${acc.failed}` +
      (acc.checkpoints ? `  ·  checkpoint turns ${acc.checkpoints}` : '') +
      (acc.limitHits ? `  ·  limit hits ${acc.limitHits}` : ''),
    `  tokens     in ${fmt(acc.input)}  out ${fmt(acc.output)}  ` +
      `cache-read ${fmt(acc.cacheRead)}  cache-write ${fmt(acc.cacheWrite)}`,
    `  billed     ${fmt(billed)} tokens  ·  ${usd(acc.cost)}  ·  ` +
      `${(acc.durationMs / 60000).toFixed(1)} model-minutes  ·  ${fmt(acc.turns)} turns`
  ].join('\n');
}

const total = records.reduce(add, blank());

// records.length counts every row, iterations and checkpoint turns alike — calling all of
// them "iteration(s)" would contradict the very distinction this report draws a few lines
// down (`describe()`'s own `checkpoint turns N`), so the header breaks the two apart too.
const recordedLabel = total.checkpoints
  ? `${total.iterations} iteration(s), ${total.checkpoints} checkpoint turn(s) recorded`
  : `${total.iterations} iteration(s) recorded`;

console.log(`Run log: ${show(jsonlPath)}`);
console.log(`${recordedLabel}${malformed ? `, ${malformed} unreadable line(s)` : ''}`);
console.log('');
console.log('TOTAL, ALL RUNS');
console.log(describe(total));
if (total.iterations > 0) {
  console.log(`  average    ${usd(total.cost / total.iterations)} and ` +
    `${fmt(Math.round((total.input + total.output) / total.iterations))} billed tokens per iteration`);
}

const groupBy = (key) => {
  const groups = new Map();
  for (const r of records) {
    const k = r[key] || '(unknown)';
    if (!groups.has(k)) groups.set(k, blank());
    add(groups.get(k), r);
  }
  return groups;
};

if (mode === 'by-run') {
  console.log('');
  console.log('BY RUN');
  for (const [runId, acc] of groupBy('run_id')) {
    const first = records.find((r) => r.run_id === runId);
    console.log('');
    console.log(`${runId}   (started ${first ? first.started_at : '?'})`);
    console.log(describe(acc));
  }
}

if (mode === 'by-ticket') {
  console.log('');
  console.log('BY TICKET  (in the order they were first attempted)');
  for (const [ticket, acc] of groupBy('ticket')) {
    console.log('');
    console.log(ticket);
    console.log(describe(acc));
  }
}

if (mode === 'failures') {
  const bad = records.filter(
    (r) =>
      !isCheckpoint(r) &&
      (r.is_error || !r.status_flipped || r.limit_hit || r.tree_dirty) &&
      !isProgressed(r) &&
      !isStalled(r)
  );
  console.log('');
  console.log(`UNPRODUCTIVE ITERATIONS (${bad.length})`);
  if (bad.length === 0) console.log('  none — every recorded iteration landed its ticket');
  for (const r of bad) {
    const flags = [
      r.is_error ? 'error' : null,
      r.limit_hit ? `limit${r.limit_reset ? ` (resets ${r.limit_reset})` : ''}` : null,
      r.transient_error ? 'transient' : null,
      r.context_exhausted ? 'out-of-context' : null,
      r.permission_denied ? 'permission-denied' : null,
      !r.status_flipped ? 'not-landed' : null,
      r.tree_dirty ? 'tree-dirty' : null,
      !r.committed ? 'no-commit' : null,
      !r.parse_ok ? 'unparsed-payload' : null,
      r.subtype ? `subtype=${r.subtype}` : null
    ].filter(Boolean);
    console.log('');
    console.log(`${r.run_id} #${r.iteration}  ${r.ticket}`);
    console.log(`  ${flags.join('  ·  ')}`);
    console.log(`  ${usd(r.cost_usd)}  ·  exit ${r.exit_status}  ·  ${r.started_at}`);
  }
}

console.log('');
