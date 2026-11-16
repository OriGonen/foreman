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
    '--base-ref', 'a', '--head-ref', 'a', '--started-at', 'now',
    '--exit-status', String(o.exit ?? 0), '--tree-dirty', '0', '--status-flipped', '0', '--quiet'];
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
