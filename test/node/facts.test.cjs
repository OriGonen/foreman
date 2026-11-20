// lib/foreman-facts.cjs: the formats and rules the bash loop and the node programs share.
'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const LIB = path.join(__dirname, '..', '..', 'lib');
const FACTS = path.join(LIB, 'foreman-facts.cjs');
const facts = require(FACTS);

// --- parseFacts ----------------------------------------------------------------------------

test('parseFacts (renderer shape): repeated keys are lists, a bare key is empty, blanks and CRs are nothing', () => {
  const f = facts.parseFacts('name\tbatch one\r\n\nrun\ta\t1\nrun\tb\t2\nrun\tc\nflag\nrun\td\n');
  assert.deepEqual({ ...f }, { name: 'batch one', run: ['a\t1', 'b\t2', 'c', 'd'], flag: '' });
});

test('parseFacts (renderer shape): no prototype, so a fact may be named constructor', () => {
  const f = facts.parseFacts('constructor\tx\ntoString\ty');
  assert.equal(Object.getPrototypeOf(f), null);
  assert.equal(f.constructor, 'x');
  assert.equal(f.toString, 'y');
});

test('parseFacts (renderer shape): the empty text is no facts', () => {
  assert.deepEqual({ ...facts.parseFacts('') }, {});
  assert.deepEqual({ ...facts.parseFacts(undefined) }, { undefined: '' });
});

test('parseFacts (typed): tickets, warnings and numbers are read as what they are; other keys keep the last value', () => {
  const f = facts.parseFacts([
    'repo\t/r',
    'ticket\topen\tt/01.md\t0\t1\tnpm test\tmore to do',
    'ticket\tdone\tt/DONE_02.md\t1\t0',
    'warning\ta\tb',
    'until\t3\tt/04.md',
    'done\t1', 'total\t2', 'humans\t1',
    'name\tfirst', 'name\tsecond',
    'bare',
    '',
  ].join('\r\n'), { typed: true });
  assert.deepEqual(f.tickets, [
    { state: 'open', file: 't/01.md', done: false, human: true, checks: 'npm test', handoff: 'more to do' },
    { state: 'done', file: 't/DONE_02.md', done: true, human: false, checks: null, handoff: null },
  ]);
  assert.deepEqual(f.warnings, ['a\tb']);
  assert.deepEqual(f.until, { tickets: 3, stop: 't/04.md' });
  assert.equal(f.done, 1);
  assert.equal(f.total, 2);
  assert.equal(f.humans, 1);
  assert.equal(f.name, 'second');
  assert.equal(f.bare, '');
  assert.equal(f.repo, '/r');
});

test('parseFacts (typed): no facts is an empty list of tickets and warnings', () => {
  assert.deepEqual(facts.parseFacts('', { typed: true }), { tickets: [], warnings: [] });
});

test('the renderer and foreman-json.cjs read facts through this one function', () => {
  const draw = require(path.join(LIB, 'foreman-draw.cjs'));
  const json = require(path.join(LIB, 'foreman-json.cjs'));
  assert.equal(draw.parseFacts, facts.parseFacts);
  const text = 'ticket\topen\ta.md\t0\t0\nwarning\tw';
  assert.deepEqual(json.parseFacts(text), facts.parseFacts(text, { typed: true }));
});

// --- the outcome rules ---------------------------------------------------------------------

const BOOLS = [false, true];
function* inputs() {
  for (const committed of BOOLS) for (const statusFlipped of BOOLS)
    for (const isError of BOOLS) for (const treeDirty of BOOLS) yield { committed, statusFlipped, isError, treeDirty };
}
const rowOf = ({ committed, statusFlipped, isError, treeDirty }) =>
  ({ committed, status_flipped: statusFlipped, is_error: isError, tree_dirty: treeDirty });

test('progressed: committed, not landed, no error, clean tree — and only then', () => {
  for (const i of inputs()) {
    assert.equal(facts.progressedFrom(i), i.committed && !i.statusFlipped && !i.isError && !i.treeDirty, JSON.stringify(i));
  }
});

test('stalled: dirty tree, nothing committed, not landed, no error — and only then', () => {
  for (const i of inputs()) {
    assert.equal(facts.stalledFrom(i), i.treeDirty && !i.committed && !i.statusFlipped && !i.isError, JSON.stringify(i));
  }
});

test('a row without recorded progressed/stalled is derived by the very rule the recorder uses', () => {
  for (const i of inputs()) {
    assert.equal(facts.isProgressed(rowOf(i)), facts.progressedFrom(i), JSON.stringify(i));
    assert.equal(facts.isStalled(rowOf(i)), facts.stalledFrom(i), JSON.stringify(i));
  }
});

test('a recorded progressed/stalled wins over the fields; only an absent one falls back', () => {
  const clean = rowOf({ committed: false, statusFlipped: false, isError: false, treeDirty: false });
  assert.equal(facts.isProgressed({ ...clean, progressed: true }), true);
  assert.equal(facts.isStalled({ ...clean, stalled: true }), true);
  const committed = rowOf({ committed: true, statusFlipped: false, isError: false, treeDirty: false });
  assert.equal(facts.isProgressed({ ...committed, progressed: false }), false);
  assert.equal(facts.isProgressed({ ...committed, progressed: null }), false);
  assert.equal(facts.isProgressed(committed), true);
});

test('outcomeOf: checkpoint, landed, stalled, progressed, else unproductive, in that order', () => {
  assert.equal(facts.outcomeOf({ kind: 'checkpoint', status_flipped: true }), 'checkpoint');
  assert.equal(facts.outcomeOf({ status_flipped: true, is_error: true }), 'landed');
  assert.equal(facts.outcomeOf({ tree_dirty: true }), 'stalled');
  assert.equal(facts.outcomeOf({ committed: true }), 'progressed');
  assert.equal(facts.outcomeOf({ committed: true, tree_dirty: true }), 'unproductive');
  assert.equal(facts.outcomeOf({ tree_dirty: true, is_error: true }), 'unproductive');
  assert.equal(facts.outcomeOf({}), 'unproductive');
  assert.equal(facts.outcomeOf({ stalled: true, progressed: true }), 'stalled');
});

test('the recorder and the report agree: the verdict the recorder writes is the word the report reads back', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'foreman-facts-'));
  try {
    for (const i of inputs()) {
      const jsonl = path.join(dir, 'runs.jsonl');
      fs.rmSync(jsonl, { force: true });
      const r = spawnSync(process.execPath, [
        path.join(LIB, 'foreman-record.cjs'),
        '--jsonl', jsonl, '--log', path.join(dir, 'runs.log'), '--verdict', path.join(dir, 'v.txt'),
        '--run-id', 'R', '--iteration', '1', '--ticket', 't.md', '--batch', 'b', '--started-at', 'now',
        '--base-ref', 'a', '--head-ref', i.committed ? 'b' : 'a',
        '--exit-status', i.isError ? '1' : '0', '--tree-dirty', i.treeDirty ? '1' : '0',
        '--status-flipped', i.statusFlipped ? '1' : '0', '--quiet',
      ], { input: '{"is_error":false,"result":"ok"}', encoding: 'utf8' });
      assert.equal(r.status, 0, r.stderr);
      const rec = JSON.parse(fs.readFileSync(jsonl, 'utf8'));
      assert.equal(rec.progressed, facts.progressedFrom({ ...i, isError: rec.is_error }), JSON.stringify(i));
      assert.equal(rec.stalled, facts.stalledFrom({ ...i, isError: rec.is_error }), JSON.stringify(i));
      // the recorded booleans and the fallback over the other fields name the same outcome
      const { progressed, stalled, ...legacy } = rec;
      assert.equal(facts.outcomeOf(rec), facts.outcomeOf(legacy), JSON.stringify(i));
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- exit words ----------------------------------------------------------------------------

test('RUN_ENDS: the exit statuses of foreman run', () => {
  assert.deepEqual({ ...facts.RUN_ENDS }, { complete: 0, paused: 10, needs_human: 20, waiting_on_human: 30 });
  assert.ok(Object.isFrozen(facts.RUN_ENDS));
});

test('status --json reads a run log\'s endings with those statuses', () => {
  const { readLastRun } = require(path.join(LIB, 'foreman-json.cjs'));
  const log = (end) => `# run r1 started\n# ---- run r1 finished\n${end}\n`;
  assert.deepEqual(readLastRun(log('# complete')), { id: 'r1', end: 'complete', exit: 0, reason: null });
  assert.deepEqual(readLastRun(log('# paused: usage limit')), { id: 'r1', end: 'paused', exit: 10, reason: 'usage limit' });
  assert.equal(readLastRun(log('# stopped: needs a human')).exit, 20);
  assert.equal(readLastRun(log('# stopped: waiting on a human')).exit, 30);
});

// --- stdout that survives its reader -------------------------------------------------------

test('writeOut: a reader that leaves early ends the program quietly, with its own exit status', async () => {
  const script = `
    const { writeOut } = require(${JSON.stringify(FACTS)});
    process.exitCode = 7;
    setTimeout(() => { writeOut('x'.repeat(1 << 20)); writeOut('y'.repeat(1 << 20)); setTimeout(() => process.exit(9), 1000); }, 300);
  `;
  const child = spawn(process.execPath, ['-e', script], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', (d) => { stderr += d; });
  child.stdout.destroy();                     // `| head -0`
  const status = await new Promise((resolve) => child.on('close', resolve));
  assert.equal(stderr, '');
  assert.equal(status, 7);
});

test('a broken pipe is quiet from the programs that print: report, json and draw', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'foreman-facts-'));
  try {
    const jsonl = path.join(dir, 'j.jsonl');
    fs.writeFileSync(jsonl, '{"run_id":"A","cost_usd":1,"tokens":{"input":3,"output":4}}\n');
    // Hold each write back until the reader has gone, whatever the machine's speed.
    fs.writeFileSync(path.join(dir, 'slow.cjs'),
      'const w = process.stdout.write.bind(process.stdout); process.stdout.write = (...a) => { setTimeout(() => w(...a), 400); return true; };');
    const runs = [
      [path.join(LIB, 'foreman-report.cjs'), ['--jsonl', jsonl, '--json']],
      [path.join(LIB, 'foreman-json.cjs'), ['status']],
      [path.join(LIB, 'foreman-draw.cjs'), ['status', '--tier', '16', '--cols', '100']],
    ];
    for (const [file, args] of runs) {
      const child = spawn(process.execPath, ['--require', path.join(dir, 'slow.cjs'), file, ...args], { stdio: ['pipe', 'pipe', 'pipe'], cwd: dir });
      let stderr = '';
      child.stderr.on('data', (d) => { stderr += d; });
      child.stdout.destroy();
      child.stdin.end('');
      await new Promise((resolve) => child.on('close', resolve));
      assert.ok(!/EPIPE|Unhandled|node:events/.test(stderr), path.basename(file) + ': ' + stderr);
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// --- report and convert are modules --------------------------------------------------------

test('report and convert export their functions and do nothing when required', () => {
  const r = spawnSync(process.execPath, ['-e', `
    const report = require(${JSON.stringify(path.join(LIB, 'foreman-report.cjs'))});
    const convert = require(${JSON.stringify(path.join(LIB, 'foreman-convert.cjs'))});
    console.log(typeof report.main, typeof report.describe, typeof convert.main, typeof convert.convertText);
  `], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, 'function function function function\n');
  assert.equal(r.stderr, '');
});

test('convertText: the word is swapped case for case, credit to the technique and protected names stay', () => {
  const { convertText } = require(path.join(LIB, 'foreman-convert.cjs'));
  assert.deepEqual(convertText('RALPH_X, `ralph run`, Ralph', []), { text: 'FOREMAN_X, `foreman run`, Foreman', n: 3 });
  assert.equal(convertText('the Ralph loop and Ralph Wiggum', []).n, 0);
  assert.deepEqual(convertText('see ralph-notes.md and ralph', ['ralph-notes.md']), { text: 'see ralph-notes.md and foreman', n: 1 });
});
