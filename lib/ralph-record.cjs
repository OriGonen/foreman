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
const stripAnsi = require('./ralph-strip-ansi.cjs');

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

// In sandbox modes the payload is `sbx`'s own banner plus terminal control codes and then
// the JSON, rather than valid JSON on its own — see ralph-strip-ansi.cjs, which
// ralph-stream.cjs shares. Strip that before looking for the object's start.
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

// What the loop saw of the iteration's effect on the repository. Read up here rather than
// only inside the record, because the signal detection below needs them too.
const committed = arg('base-ref', '') !== arg('head-ref', '');
const statusFlipped = arg('status-flipped', '0') === '1';
const treeDirty = arg('tree-dirty', '0') === '1';

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
  'rate limit',
  'rate_limit_error',
  'quota exceeded',
  'credit balance is too low',
  'insufficient credit',
  'billing'
];
// The 5-hour window is announced in more than one wording, and matching only the one this
// list was written against ("Claude AI usage limit reached|<epoch>") let the current CLI's
// "You've hit your session limit · resets 4:50pm" fall through to the generic paths — where
// a dirty tree wins the branch order and the run stops as "left uncommitted changes" with
// no mention of the limit at all. Match the shape both wordings share instead of the exact
// sentence, so the next rephrasing does not silently regress this again.
const LIMIT_RE = /\b(?:usage|session|weekly)\s+limit\b/i;
const limitHit = LIMIT_PATTERNS.some((p) => haystack.includes(p)) || LIMIT_RE.test(haystack);

// Context exhaustion: this conversation grew past the model's context window.
//
// A third class, and neither of the other two. It is not a quota — nothing is out of
// budget — and it is not a blip, because the same prompt will hit the same wall again.
// What makes it worth its own signal is that the cause is THIS conversation's accumulated
// length, not a repeatable defect in the ticket, so a fresh context is a plausible fix;
// and when it is not, the right advice to a human is specific ("this ticket is too big for
// one iteration"), not the generic "it did not land".
//
// Detected two ways. `terminal_reason: "prompt_too_long"` is the structured one, observed
// end-to-end through `claude --print --output-format json`. The text patterns are the
// fallback for an overflow that kills the CLI before it emits any JSON at all — which is
// exactly the case worth retrying — and for the compaction failures, which are taken from
// the strings in the CLI binary rather than observed here.
const CONTEXT_EXHAUSTED_PATTERNS = [
  'prompt is too long',
  'prompt_too_long',
  'input is too long for requested model',
  'conversation could not be reduced below the context limit',
  'automatic compaction failed',
  'partial compaction failed',
  'reactive compaction failed'
];
const contextExhausted = !limitHit && !ranSuccessfully && (
  (payload && payload.terminal_reason === 'prompt_too_long') ||
  CONTEXT_EXHAUSTED_PATTERNS.some((p) => haystack.includes(p))
);

// Transient failures worth one retry on the SAME ticket, rather than a pause: the model
// was briefly unavailable, not out of budget.
//
// Evaluated AFTER context exhaustion, and excluding it, because the two overlap by
// accident: a real overflow payload carries `"api_error_status": 400`, whose field NAME
// contains 'api_error'. Without this ordering every context failure would read as
// transient and none of the handling above would ever fire.
const TRANSIENT_PATTERNS = [
  'overloaded_error',
  'api_error',
  'internal server error',
  'connection error',
  'econnreset',
  'etimedout',
  'fetch failed'
];
const transient = !limitHit && !contextExhausted &&
  TRANSIENT_PATTERNS.some((p) => haystack.includes(p));

// A tool call the agent was not permitted to make.
//
// `acceptEdits` covers Edit and Write but leaves Bash to the settings allowlist, and under
// `claude --print` there is no approver — anything that would prompt is denied outright. So
// a batch whose allowlist has no `git` entry gets the ticket's work done and then cannot
// commit it, and the run stops one branch later as a generic dirty tree with the real cause
// named nowhere.
//
// Gated differently from every signal above, on purpose. Those scan `haystack`, which is
// empty unless the run visibly failed — but a permission denial usually rides on a turn the
// CLI itself calls a success: the tool was denied, the agent said so in its reply, exit 0,
// subtype success. Gating on that would mean never firing on the case this exists for. The
// gate is the OUTCOME instead: an iteration that both landed its ticket and left a clean
// tree cannot be one a denial stopped, so a ticket that legitimately implements permission
// handling still cannot false-trigger.
const landedCleanly = ranSuccessfully && statusFlipped && !treeDirty;
const PERMISSION_PATTERNS = ['requires approval', 'permission denied'];
const permissionHaystack = landedCleanly ? '' : raw.toLowerCase();
const permissionDenied = PERMISSION_PATTERNS.some((p) => permissionHaystack.includes(p));

// Claude Code reports the 5-hour window reset as an epoch after a pipe, e.g.
// "Claude AI usage limit reached|1735689600". Surface it so the pause message can say
// when to come back.
//
// Under `--print --output-format json` the same event instead arrives already formatted for
// a human — "resets 4:50pm (Europe/Ljubljana)" — with no epoch anywhere in the payload. Take
// that verbatim rather than trying to turn it back into a timestamp: it is only ever printed
// in the pause message, and its own local-time wording is exactly what the user needs.
let limitReset = '';
const resetMatch = raw.match(/(?:usage|session|weekly)\s+limit[^|]*\|\s*(\d{9,13})/i);
if (resetMatch) {
  const n = Number(resetMatch[1]);
  const ms = n > 1e12 ? n : n * 1000;
  const d = new Date(ms);
  if (!Number.isNaN(d.getTime())) limitReset = d.toISOString();
} else if (limitHit) {
  const textMatch = raw.match(/resets?\s+([0-9][0-9:.]*\s*(?:[ap]\.?m\.?)?(?:\s*\([^)\n]{1,40}\))?)/i);
  if (textMatch) limitReset = textMatch[1].trim();
}

const isError = exitStatus !== 0 || Boolean(payload && payload.is_error) || limitHit;

// The iteration committed work but did not land the ticket, and nothing went wrong: the
// agent checkpointed a part-finished ticket and handed it off, which the loop continues
// rather than counts as a failure. Derived entirely from fields already recorded, so old
// log lines read back correctly and there is nothing to migrate.
const progressed = committed && !statusFlipped && !isError && !treeDirty;

const record = {
  run_id: arg('run-id', ''),
  iteration: Number(arg('iteration', '0')) || 0,
  ticket: arg('ticket', ''),
  batch: arg('batch', ''),
  started_at: arg('started-at', ''),
  finished_at: new Date().toISOString(),
  base_ref: arg('base-ref', ''),
  head_ref: arg('head-ref', ''),
  committed,
  status_flipped: statusFlipped,
  tree_dirty: treeDirty,
  exit_status: exitStatus,
  parse_ok: payload !== null,
  is_error: isError,
  limit_hit: limitHit,
  limit_reset: limitReset,
  transient_error: transient,
  context_exhausted: contextExhausted,
  permission_denied: permissionDenied,
  progressed,
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
if (contextExhausted) lines.push('CONTEXT EXHAUSTED SIGNAL DETECTED');
if (permissionDenied) lines.push('PERMISSION DENIED SIGNAL DETECTED');
if (progressed) lines.push('PROGRESSED (work committed, ticket not landed yet)');
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
// limit_reset alone may be a human-readable local time ("4:50pm (Europe/Ljubljana)"), so it
// needs spaces, parentheses and a slash that `safe` would eat. Newlines stay forbidden —
// they would end the key=value line — and the loop only ever interpolates this into a
// message, never evaluates it.
const safeReset = (v) => String(v).replace(/[^A-Za-z0-9._:+()/ -]/g, '').replace(/\s+/g, ' ').trim();
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
  `limit_reset=${safeReset(limitReset)}`,
  `transient=${transient ? 1 : 0}`,
  `context_exhausted=${contextExhausted ? 1 : 0}`,
  `permission_denied=${permissionDenied ? 1 : 0}`,
  `subtype=${safe(record.subtype)}`
].join('\n');
fs.writeFileSync(verdictPath, verdict + '\n');

// One line to the loop's own stdout, so a live run reads sensibly without tailing a file.
console.log(
  `   usage: billed ${fmt(billedTokens)} tok  ` +
    `(in ${fmt(tokens.input)} / out ${fmt(tokens.output)}, cache r ${fmt(tokens.cache_read)} / w ${fmt(tokens.cache_creation)})` +
    `  ·  $${costUsd.toFixed(4)}  ·  ${(record.duration_ms / 1000).toFixed(1)}s`
);
