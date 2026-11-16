// Drives lib/foreman-stream.cjs (--live-file pointing nowhere: the view is off, the tail logic is on).
'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const STREAM = path.join(__dirname, '..', '..', 'lib', 'foreman-stream.cjs');

function stream(input) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'foreman-stream-'));
  try {
    return spawnSync(process.execPath, [STREAM, '--live-file', path.join(dir, 'nonexistent')],
      { input, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

const toolUse = (body) => JSON.stringify({
  type: 'assistant',
  message: { content: [{ type: 'tool_use', name: 'Edit', input: { file_path: 'src/billing.ts', new_string: body } }] }
});

test('stream: with no result, the flushed tail holds no agent events', () => {
  const r = stream(`ERROR: agent exited with code 1\n${toolUse('export function billing() {}')}\n`);
  assert.equal(r.status, 0, r.stderr);
  assert.ok(!r.stdout.includes('billing'), `agent event leaked into payload: ${r.stdout}`);
  assert.ok(!r.stdout.includes('{'), r.stdout);
  assert.match(r.stdout, /^ERROR: agent exited with code 1$/m);
});

test('stream: only agent events and no other output passes nothing on', () => {
  const r = stream(`${toolUse('x')}\n`);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, '');
});

test('stream: the ERROR banner is not evicted by a long line after it', () => {
  const r = stream(`ERROR: agent exited with code 1\n${'x'.repeat(9000)}\n`);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^ERROR: agent exited with code 1$/m);
});

test('stream: the ERROR banner is not evicted by a long JSON event after it', () => {
  const r = stream(`ERROR: agent exited with code 1\n${toolUse('y'.repeat(9000))}\n`);
  assert.match(r.stdout, /^ERROR: agent exited with code 1$/m);
});

test('stream: a result object still wins and the tail is dropped', () => {
  const result = '{"type":"result","is_error":false,"result":"ok"}';
  const r = stream(`banner line\n${toolUse('z')}\n${result}\n`);
  assert.equal(r.stdout, `${result}\n`);
});

test('stream: one huge line is handled in linear time', () => {
  const big = `${'a'.repeat(30 * 1024 * 1024)}\n`; // 30 MB, many chunks
  const t0 = Date.now();
  const r = stream(`ERROR: agent exited with code 1\n${big}`);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^ERROR: agent exited with code 1$/m);
  assert.ok(Date.now() - t0 < 5000, `took ${Date.now() - t0} ms`);
});
