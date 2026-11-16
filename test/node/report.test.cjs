// Drives lib/foreman-report.cjs --jsonl against a crafted log.
'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const REPORT = path.join(__dirname, '..', '..', 'lib', 'foreman-report.cjs');

test('report: a JSONL line that is valid JSON but not an object is skipped, not fatal', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'foreman-report-'));
  try {
    const jsonl = path.join(dir, 'j.jsonl');
    fs.writeFileSync(jsonl, 'null\n42\n"text"\n[1]\n{"run_id":"A","cost_usd":1,"tokens":{"input":3,"output":4}}\n');
    const r = spawnSync(process.execPath, [REPORT, '--jsonl', jsonl, '--json'], { encoding: 'utf8', cwd: dir });
    assert.equal(r.status, 0, r.stderr);
    const doc = JSON.parse(r.stdout);
    assert.equal(doc.totals.unreadable, 4);
    assert.equal(doc.totals.cost_usd, 1);
    assert.equal(doc.totals.runs, 1);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('report: a log of only non-object lines says it has no readable records', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'foreman-report-'));
  try {
    const jsonl = path.join(dir, 'j.jsonl');
    fs.writeFileSync(jsonl, 'null\n');
    const r = spawnSync(process.execPath, [REPORT, '--jsonl', jsonl], { encoding: 'utf8', cwd: dir });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /no readable records/);
    assert.ok(!/TypeError/.test(r.stderr));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
