// Records one ralph iteration.
//
// Reads the raw `claude --output-format json` payload on stdin (which may be malformed,
// truncated, or an error string — that is the point of doing this in node rather than
// jq) and does three things:
//
//   1. appends one JSON object to the structured run log (--jsonl), one line per
//      iteration, forever;
//   2. appends a human-readable block to the transcript log (--log), including the
//      agent's own reply, so a run can be read back later without a JSON tool;
//   3. writes a small verdict file (--verdict) of sanitized key=value pairs for the
//      bash loop to act on.
//
// The two logs are APPEND-ONLY and are never read back — not by this script, not by the
// loop. Resume state lives in the tickets' Status lines (see ralph-next.sh). That keeps
// the logs pure telemetry: truncate them, delete them, or hand-edit them and the loop
// behaves identically. `ralph-report.cjs` reads them, but only when a human runs it.
//
// Both logs live in the BATCH directory, never in this toolkit directory — the toolkit is
// stateless and shared, and two batches must never write to one log.
//
// Usage:
//   node ralph-record.cjs --jsonl P --log P --verdict P --run-id ID --iteration N \
//        --ticket PATH --batch DIR --base-ref SHA --head-ref SHA --started-at ISO \
//        --exit-status N --tree-dirty 0|1 --status-flipped 0|1 < payload

const fs = require('node:fs');

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && i + 1 < process.argv.length ? process.argv[i + 1] : fallback;
}

const jsonlPath = arg('jsonl');
const logPath = arg('log');
const verdictPath = arg('verdict');

if (!jsonlPath || !logPath || !verdictPath) {
  console.error('ralph-record.cjs: --jsonl, --log and --verdict are all required');
  process.exit(2);
}

const raw = fs.readFileSync(0, 'utf8');

// In sandbox modes `sbx run` prints its own "Starting claude agent..." / "Workspace: ..."
// banner to stdout ahead of the JSON, so the payload is banner-text + JSON rather than
// valid JSON on its own. It also wraps the JSON in its own terminal control codes
// (set-title, clear-screen, cursor-home) with no newline separating them from the `{`,
// which hides the object's start from a line-anchored search. Strip those before looking.
// In `local` mode there is no banner and this all reduces to a no-op.
const stripAnsi = (s) => s
  .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, '') // OSC ... BEL/ST (e.g. set title)
  .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, '')             // CSI ... letter (e.g. clear, cursor)
  .replace(/\x1b[()][A-Za-z0-9]/g, '')                // charset select
  .replace(/\x1b./g, '');                             // any other two-char escape

const cleaned = stripAnsi(raw);
const jsonStart = cleaned.search(/^\{/m);
const jsonText = jsonStart === -1 ? '' : cleaned.slice(jsonStart);

let payload = null;
try {
  payload = JSON.parse(jsonText);
} catch {
  payload = null;
}

const usage = (payload && payload.usage) || {};
const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : 0);

const tokens = {
  input: num(usage.input_tokens),
  output: num(usage.output_tokens),
  cache_read: num(usage.cache_read_input_tokens),
  cache_creation: num(usage.cache_creation_input_tokens)
};

const costUsd = num(payload && payload.total_cost_usd);
const exitStatus = Number(arg('exit-status', '0')) || 0;

// ---------------------------------------------------------------------------
// Limit detection.
//
// Best-effort and deliberately secondary: the reliable brake is the cost/iteration/
// time budget the loop enforces itself. This only exists so that hitting a limit
// mid-run pauses cleanly instead of burning the rest of the iterations on errors that
// will all fail the same way.
//
// Matched against the whole payload, because a limit can surface as the `result` text,
// as an API error object, or as a bare string when the CLI never got far enough to
// produce JSON at all.
//
// Only scan when there is actual reason to believe the run failed: JSON never parsed,
// the CLI marked is_error, or the process exited non-zero. A successful run's own reply
// text is otherwise fair game, and a ticket that legitimately implements billing, quota
// or rate-limit behaviour would otherwise false-trigger a pause on a run that went fine.
// ---------------------------------------------------------------------------
const ranSuccessfully = payload !== null && payload.is_error !== true && exitStatus === 0;
const haystack = ranSuccessfully ? '' : raw.toLowerCase();

const LIMIT_PATTERNS = [
  'usage limit reached',
  'rate limit',
  'rate_limit_error',
  'quota exceeded',
  'credit balance is too low',
  'insufficient credit',
  'billing'
];
const limitHit = LIMIT_PATTERNS.some((p) => haystack.includes(p));

// Transient failures worth one retry on the SAME ticket, rather than a pause: the model
// was briefly unavailable, not out of budget.
const TRANSIENT_PATTERNS = [
  'overloaded_error',
  'api_error',
  'internal server error',
  'connection error',
  'econnreset',
  'etimedout',
  'fetch failed'
];
const transient = !limitHit && TRANSIENT_PATTERNS.some((p) => haystack.includes(p));

// Claude Code reports the 5-hour window reset as an epoch after a pipe, e.g.
// "Claude AI usage limit reached|1735689600". Surface it so the pause message can say
// when to come back.
let limitReset = '';
const resetMatch = raw.match(/usage limit reached\s*\|\s*(\d{9,13})/i);
if (resetMatch) {
  const n = Number(resetMatch[1]);
  const ms = n > 1e12 ? n : n * 1000;
  const d = new Date(ms);
  if (!Number.isNaN(d.getTime())) limitReset = d.toISOString();
}

const isError = exitStatus !== 0 || Boolean(payload && payload.is_error) || limitHit;

const record = {
  run_id: arg('run-id', ''),
  iteration: Number(arg('iteration', '0')) || 0,
  ticket: arg('ticket', ''),
  batch: arg('batch', ''),
  started_at: arg('started-at', ''),
  finished_at: new Date().toISOString(),
  base_ref: arg('base-ref', ''),
  head_ref: arg('head-ref', ''),
  committed: arg('base-ref', '') !== arg('head-ref', ''),
  status_flipped: arg('status-flipped', '0') === '1',
  tree_dirty: arg('tree-dirty', '0') === '1',
  exit_status: exitStatus,
  parse_ok: payload !== null,
  is_error: isError,
  limit_hit: limitHit,
  limit_reset: limitReset,
  transient_error: transient,
  subtype: (payload && typeof payload.subtype === 'string' ? payload.subtype : '') || '',
  session_id: (payload && typeof payload.session_id === 'string' ? payload.session_id : '') || '',
  num_turns: num(payload && payload.num_turns),
  duration_ms: num(payload && payload.duration_ms),
  duration_api_ms: num(payload && payload.duration_api_ms),
  cost_usd: costUsd,
  tokens,
  // The model's own reply. Kept in the structured log too so a single file is enough to
  // reconstruct what happened, at the cost of some size.
  reply: (payload && typeof payload.result === 'string' ? payload.result : '') || ''
};

fs.appendFileSync(jsonlPath, JSON.stringify(record) + '\n');

// ---------------------------------------------------------------------------
// Human-readable transcript.
// ---------------------------------------------------------------------------
const fmt = (n) => n.toLocaleString('en-US');
const billedTokens = tokens.input + tokens.output;
const lines = [
  '',
  '='.repeat(78),
  `iteration ${record.iteration}  ·  ${record.ticket}`,
  `run ${record.run_id}  ·  started ${record.started_at}  ·  finished ${record.finished_at}`,
  `commit ${record.base_ref.slice(0, 10)} -> ${record.head_ref.slice(0, 10)}` +
    `${record.committed ? '' : '  (NO NEW COMMIT)'}` +
    `${record.status_flipped ? '' : '  (STATUS NOT FLIPPED)'}` +
    `${record.tree_dirty ? '  (TREE LEFT DIRTY)' : ''}`,
  `exit ${record.exit_status}  ·  subtype ${record.subtype || 'n/a'}  ·  turns ${record.num_turns}` +
    `  ·  ${(record.duration_ms / 1000).toFixed(1)}s wall, ${(record.duration_api_ms / 1000).toFixed(1)}s api`,
  `tokens  in ${fmt(tokens.input)}  out ${fmt(tokens.output)}  ` +
    `cache-read ${fmt(tokens.cache_read)}  cache-write ${fmt(tokens.cache_creation)}  ` +
    `(billed ${fmt(billedTokens)})`,
  `cost    $${costUsd.toFixed(4)}`
];
if (!record.parse_ok) lines.push('WARNING: payload was not valid JSON; usage figures are zeros');
if (limitHit) lines.push(`LIMIT SIGNAL DETECTED${limitReset ? ` · resets ${limitReset}` : ''}`);
if (transient) lines.push('TRANSIENT ERROR SIGNAL DETECTED');
lines.push('-'.repeat(78));
lines.push(record.reply || '(no reply text)');
if (!record.parse_ok && raw.trim()) {
  lines.push('-'.repeat(78));
  lines.push('RAW PAYLOAD (unparsed):');
  lines.push(raw.length > 20000 ? raw.slice(0, 20000) + '\n…truncated…' : raw);
}
lines.push('');

fs.appendFileSync(logPath, lines.join('\n'));

// ---------------------------------------------------------------------------
// Verdict for the bash loop.
//
// Fixed keys, values constrained to digits/dots/hyphens/colons/underscores/letters, so
// the loop can grep them out without ever eval-ing anything derived from model output.
// ---------------------------------------------------------------------------
const safe = (v) => String(v).replace(/[^A-Za-z0-9._:+-]/g, '');
const verdict = [
  `cost_usd=${costUsd.toFixed(6)}`,
  `input_tokens=${tokens.input}`,
  `output_tokens=${tokens.output}`,
  `cache_read_tokens=${tokens.cache_read}`,
  `cache_creation_tokens=${tokens.cache_creation}`,
  `num_turns=${record.num_turns}`,
  `duration_ms=${record.duration_ms}`,
  `parse_ok=${record.parse_ok ? 1 : 0}`,
  `is_error=${record.is_error ? 1 : 0}`,
  `limit_hit=${limitHit ? 1 : 0}`,
  `limit_reset=${safe(limitReset)}`,
  `transient=${transient ? 1 : 0}`,
  `subtype=${safe(record.subtype)}`
].join('\n');
fs.writeFileSync(verdictPath, verdict + '\n');

// One line to the loop's own stdout, so a live run reads sensibly without tailing a file.
console.log(
  `   usage: billed ${fmt(billedTokens)} tok  ` +
    `(in ${fmt(tokens.input)} / out ${fmt(tokens.output)}, cache r ${fmt(tokens.cache_read)} / w ${fmt(tokens.cache_creation)})` +
    `  ·  $${costUsd.toFixed(4)}  ·  ${(record.duration_ms / 1000).toFixed(1)}s`
);
