// Drives lib/foreman-record.cjs as a child process (it is a top-level script) in a temp dir.
'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const RECORD = path.join(__dirname, '..', '..', 'lib', 'foreman-record.cjs');

function tmp() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'foreman-record-'));
}

function record(dir, stdin, extra = {}) {
  const o = {
    jsonl: path.join(dir, 'runs.jsonl'),
    log: path.join(dir, 'runs.log'),
    verdict: path.join(dir, 'verdict.txt'),
    ...extra
  };
  const args = [RECORD, '--jsonl', o.jsonl, '--log', o.log, '--verdict', o.verdict,
    '--run-id', 'R', '--iteration', '1', '--ticket', 't.md', '--batch', 'b',
    '--base-ref', 'a', '--head-ref', o.head ?? 'a', '--started-at', 'now',
    '--exit-status', String(o.exit ?? 0), '--tree-dirty', o.dirty ? '1' : '0',
    '--status-flipped', o.flipped ? '1' : '0', '--quiet'];
  const r = spawnSync(process.execPath, args, { input: stdin, encoding: 'utf8' });
  const verdict = fs.existsSync(o.verdict) ? fs.readFileSync(o.verdict, 'utf8') : null;
  return { ...r, o, verdict };
}

const kv = (verdict, key) => (verdict.match(new RegExp(`^${key}=(.*)$`, 'm')) || [])[1];

test('record: verdict survives a jsonl append that fails, and exit code is unchanged', () => {
  const dir = tmp();
  try {
    const jsonlDir = path.join(dir, 'a-directory');
    fs.mkdirSync(jsonlDir); // appending to a directory throws EISDIR
    const r = record(dir, 'Claude AI usage limit reached|1735689600', { jsonl: jsonlDir, exit: 1 });
    assert.equal(r.status, 0, r.stderr);
    assert.ok(r.verdict && r.verdict.length > 0, 'verdict file must not be empty');
    assert.equal(kv(r.verdict, 'limit_hit'), '1');
    assert.match(r.stderr, /could not append/);
    // the log append still happens after the failed jsonl one
    assert.match(fs.readFileSync(r.o.log, 'utf8'), /LIMIT SIGNAL DETECTED/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('record: verdict survives a log append that fails', () => {
  const dir = tmp();
  try {
    const logDir = path.join(dir, 'a-directory');
    fs.mkdirSync(logDir);
    const r = record(dir, '{"type":"result","is_error":false,"total_cost_usd":0.5,"result":"ok"}', { log: logDir });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(kv(r.verdict, 'cost_usd'), '0.500000');
    assert.match(r.stderr, /could not append/);
    assert.equal(fs.readFileSync(r.o.jsonl, 'utf8').trim().split('\n').length, 1);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('record: a torn last line in the jsonl does not swallow the next record', () => {
  const dir = tmp();
  try {
    const jsonl = path.join(dir, 'runs.jsonl');
    fs.writeFileSync(jsonl, '{"run_id":"A","cost_usd":1,"ticket":"t.md","iter');
    const r = record(dir, '{"type":"result","is_error":false,"total_cost_usd":2,"result":"ok"}');
    assert.equal(r.status, 0, r.stderr);
    const lines = fs.readFileSync(jsonl, 'utf8').split('\n').filter(Boolean);
    assert.equal(lines.length, 2);
    assert.throws(() => JSON.parse(lines[0]));
    assert.equal(JSON.parse(lines[1]).cost_usd, 2);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('record: no blank line is added when the jsonl already ends in a newline or is empty', () => {
  const dir = tmp();
  try {
    const jsonl = path.join(dir, 'runs.jsonl');
    fs.writeFileSync(jsonl, '');
    record(dir, '{"type":"result","total_cost_usd":1}');
    record(dir, '{"type":"result","total_cost_usd":2}');
    const text = fs.readFileSync(jsonl, 'utf8');
    assert.ok(text.endsWith('\n'));
    assert.equal(text.split('\n').length, 3); // two lines + trailing empty
    assert.ok(!text.startsWith('\n'));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('record: a lone non-result JSON object is not a payload', () => {
  const dir = tmp();
  try {
    const event = JSON.stringify({
      type: 'assistant',
      message: { content: [{ type: 'tool_use', name: 'Edit', input: { new_string: 'export function billing() {}' } }] }
    });
    const r = record(dir, `${event}\n`, { exit: 124 });
    assert.equal(r.status, 0, r.stderr);
    assert.equal(kv(r.verdict, 'parse_ok'), '0');
    assert.equal(kv(r.verdict, 'result_count'), '0');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('record: a pretty-printed result object is still read by the fallback', () => {
  const dir = tmp();
  try {
    const r = record(dir, JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 0.25, result: 'ok' }, null, 2));
    assert.equal(kv(r.verdict, 'parse_ok'), '1');
    assert.equal(kv(r.verdict, 'cost_usd'), '0.250000');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- T05: failures are classified from error-bearing fields, never from the agent's prose ---

const result = (fields) => JSON.stringify({
  type: 'result', subtype: 'success', is_error: false, total_cost_usd: 0.1,
  usage: { input_tokens: 10, output_tokens: 5 }, ...fields
});
const verdictOf = (stdin, extra) => {
  const dir = tmp();
  try {
    const r = record(dir, stdin, extra);
    assert.equal(r.status, 0, r.stderr);
    return r.verdict;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
};

test('record: a healthy committed turn that says "permission denied" is not a permission denial', () => {
  const v = verdictOf(result({ result: 'Implemented the handler; tests for permission denied on the cache dir now pass. Handing off.' }),
    { head: 'b' });
  assert.equal(kv(v, 'is_error'), '0');
  assert.equal(kv(v, 'permission_denied'), '0');
  // also on a flipped-but-dirty and on a stalled turn, and with the other phrase
  assert.equal(kv(verdictOf(result({ result: 'bash: x: Permission denied (quoted)' }), { head: 'b', flipped: true, dirty: true }), 'permission_denied'), '0');
  assert.equal(kv(verdictOf(result({ result: 'wrote the approval workflow; it requires approval from an admin' }), { dirty: true }), 'permission_denied'), '0');
});

test('record: structured permission_denials still set permission_denied', () => {
  const denials = [{ tool_name: 'Bash', tool_use_id: 't1', tool_input: { command: 'git commit -m x' } }];
  const v = verdictOf(result({ result: 'The commit was denied, so the work is uncommitted.', permission_denials: denials }), { dirty: true });
  assert.equal(kv(v, 'permission_denied'), '1');
  assert.equal(kv(v, 'is_error'), '0');
  // an empty list is not a denial
  assert.equal(kv(verdictOf(result({ result: 'fine', permission_denials: [] }), { dirty: true }), 'permission_denied'), '0');
});

test('record: on a failed turn the permission text fallback reads error text only', () => {
  const failed = result({ subtype: 'error_during_execution', is_error: true, result: 'Bash(git commit) requires approval' });
  assert.equal(kv(verdictOf(failed, { exit: 1 }), 'permission_denied'), '1');
  // the same words in the prose of an error_max_turns turn are not a denial
  const prose = result({ subtype: 'error_max_turns', is_error: true, result: 'Ran out of turns; the permission denied tests are done' });
  assert.equal(kv(verdictOf(prose, { exit: 1 }), 'permission_denied'), '0');
  // nor in a killed turn's agent-event lines
  assert.equal(kv(verdictOf('{"type":"assistant","message":{"content":"permission denied"}}\n', { exit: 124 }), 'permission_denied'), '0');
  // a bare non-JSON failure still counts
  assert.equal(kv(verdictOf('claude: Bash(git commit) requires approval\n', { exit: 1 }), 'permission_denied'), '1');
});

test('record: permission_denied_calls names a denied Bash command, an Edit path, and an unknown tool', () => {
  const denials = [
    { tool_name: 'Bash', tool_use_id: 't1', tool_input: { command: 'sleep 1200' } },
    { tool_name: 'Edit', tool_use_id: 't2', tool_input: { file_path: '/repo/src/a.js', old_string: 'x', new_string: 'y' } },
    { tool_name: 'WebFetch', tool_use_id: 't3', tool_input: { url: 'https://example.com' } }
  ];
  const v = verdictOf(result({ result: 'blocked', permission_denials: denials }), { dirty: true });
  assert.equal(kv(v, 'permission_denied'), '1');
  assert.equal(kv(v, 'permission_denied_calls'), 'Bash: sleep 1200 | Edit: /repo/src/a.js | WebFetch');
});

test('record: permission_denied_calls is one short line whatever the command holds', () => {
  const messy = { tool_name: 'Bash', tool_input: { command: 'echo a\n\techo b\r\nkey=value \u001b[31m' } };
  const long = { tool_name: 'Bash', tool_input: { command: 'echo ' + 'x'.repeat(500) } };
  const v = verdictOf(result({ permission_denials: [messy, long, messy, messy, messy] }), { dirty: true });
  const calls = kv(v, 'permission_denied_calls');
  assert.match(calls, /^Bash: echo a echo b key=value \[31m \| Bash: echo x+/);
  assert.match(calls, / \(\+2 more\)$/);
  assert.ok(calls.replace(/ \(\+2 more\)$/, '').length <= 200, `too long: ${calls.length}`);
  // the verdict is still one key=value per line
  assert.ok(v.trim().split('\n').every((l) => /^[a-z_]+=/.test(l)), v);
});

test('record: permission_denied_calls is empty without structured denials', () => {
  assert.equal(kv(verdictOf(result({ result: 'fine' }), { dirty: true }), 'permission_denied_calls'), '');
  assert.equal(kv(verdictOf(result({ result: 'fine', permission_denials: [] }), { dirty: true }), 'permission_denied_calls'), '');
  // the text fallback has no calls to name, but still flags the denial
  const v = verdictOf('claude: Bash(git commit) requires approval\n', { exit: 1 });
  assert.equal(kv(v, 'permission_denied'), '1');
  assert.equal(kv(v, 'permission_denied_calls'), '');
});

test('record: the billing and rate-limit words in an error_max_turns reply are not a usage limit', () => {
  for (const reply of ['Ran out of turns while refactoring the billing module.', 'Stopped: the rate limit handling tests crashed.']) {
    const v = verdictOf(result({ subtype: 'error_max_turns', is_error: true, result: reply }), { exit: 1 });
    assert.equal(kv(v, 'is_error'), '1');
    assert.equal(kv(v, 'limit_hit'), '0', reply);
    assert.equal(kv(v, 'transient'), '0');
    assert.equal(kv(v, 'auth_failed'), '0');
    assert.equal(kv(v, 'subtype'), 'error_max_turns');
  }
  // an error_during_execution with its own `errors` message: the reply beside it is prose too
  const own = result({ subtype: 'error_during_execution', is_error: true, errors: ['tool crashed'], result: 'while on the billing module' });
  assert.equal(kv(verdictOf(own, { exit: 1 }), 'limit_hit'), '0');
});

test('record: every real limit payload shape still reads as a limit', () => {
  // fake.sh `limit`: the CLI printed a bare string, no JSON
  const bare = verdictOf('Claude AI usage limit reached|1735689600\n', { exit: 1 });
  assert.equal(kv(bare, 'limit_hit'), '1');
  assert.match(kv(bare, 'limit_reset'), /^2025-/);
  // fake.sh `session-limit`: valid JSON, subtype success, is_error true, the wording only in `result`
  const session = verdictOf(result({ is_error: true, result: "You've hit your session limit · resets 4:50pm (Europe/Ljubljana)" }), { exit: 1 });
  assert.equal(kv(session, 'limit_hit'), '1');
  assert.equal(kv(session, 'limit_reset'), '4:50pm (Europe/Ljubljana)');
  // an API error object, no reply text at all
  assert.equal(kv(verdictOf('{"type":"result","is_error":true,"error":{"type":"rate_limit_error"}}\n', { exit: 1 }), 'limit_hit'), '1');
  // the sandbox's own error line around a result-less turn
  assert.equal(kv(verdictOf('ERROR: credit balance is too low\n', { exit: 1 }), 'limit_hit'), '1');
  // a pretty-printed result object, with a banner in front
  const pretty = 'sbx banner\n' + JSON.stringify({ type: 'result', is_error: true, result: 'weekly limit reached' }, null, 2);
  assert.equal(kv(verdictOf(pretty, { exit: 1 }), 'limit_hit'), '1');
});

test('record: auth, transient and context payloads classify as before, and prose cannot fake them', () => {
  // fake.sh `auth`
  const auth = verdictOf(result({ is_error: true, api_error_status: 401, result: 'Failed to authenticate: OAuth session expired and could not be refreshed' }), { exit: 1 });
  assert.equal(kv(auth, 'auth_failed'), '1');
  assert.equal(kv(auth, 'transient'), '0');
  // fake.sh `transient`
  const transient = verdictOf('{"type":"result","is_error":true,"error":{"type":"overloaded_error"}}\n', { exit: 1 });
  assert.equal(kv(transient, 'transient'), '1');
  assert.equal(kv(transient, 'limit_hit'), '0');
  // fake.sh `context-json` and `context`
  const ctx = verdictOf(result({ is_error: true, terminal_reason: 'prompt_too_long', api_error_status: 400, result: 'Prompt is too long - the request is ~894261 tokens (limit 200000).' }), { exit: 1 });
  assert.equal(kv(ctx, 'context_exhausted'), '1');
  assert.equal(kv(ctx, 'transient'), '0');
  assert.equal(kv(verdictOf('prompt is too long: 250000 tokens > 200000 maximum\n', { exit: 1 }), 'context_exhausted'), '1');
  // prose on an error_max_turns turn that merely discusses these
  const prose = result({ subtype: 'error_max_turns', is_error: true, result: 'Ran out of turns adding "failed to authenticate" handling, retry on ECONNRESET, and an api_error mapper.' });
  const v = verdictOf(prose, { exit: 1 });
  assert.equal(kv(v, 'auth_failed'), '0');
  assert.equal(kv(v, 'transient'), '0');
  // a two-result turn whose second result is a clean reply about billing is still not a failure (fake.sh double-result)
  const two = result({ result: 'landed' }) + '\n' + result({ result: 'The background check finished; the billing module tests pass.' });
  const t = verdictOf(two, { head: 'b', flipped: true });
  assert.equal(kv(t, 'limit_hit'), '0');
  assert.equal(kv(t, 'is_error'), '0');
});
