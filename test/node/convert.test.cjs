// lib/foreman-convert.cjs: `foreman convert` refuses before writing when it would rewrite or
// rename a file git does not track (B4, D1).
'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const CONVERT = path.join(__dirname, '..', '..', 'lib', 'foreman-convert.cjs');

function git(repo, ...args) {
  const r = spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8' });
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout;
}

// A repo with one tracked file that says Ralph, committed. Returns its path.
function makeRepo() {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'fm-convert-'));
  git(repo, 'init', '-q');
  git(repo, 'config', 'user.email', 't@example.com');
  git(repo, 'config', 'user.name', 't');
  fs.writeFileSync(path.join(repo, 'README.md'), 'Run `ralph run batch`.\n');
  fs.writeFileSync(path.join(repo, '.gitignore'), 'ignored.txt\n**/ralph-runs.jsonl\n');
  git(repo, 'add', '-A');
  git(repo, 'commit', '-q', '-m', 'init');
  return repo;
}

function convert(repo, ...args) {
  const env = { ...process.env, HOME: repo, USERPROFILE: repo };
  delete env.FOREMAN_DRAW_TIER;
  delete env.FOREMAN_DRAW_COLS;
  return spawnSync(process.execPath, [CONVERT, repo, ...args], { encoding: 'utf8', env });
}

test('an untracked file that says Ralph refuses the conversion, and nothing is written', () => {
  const repo = makeRepo();
  const mine = path.join(repo, 'notes.txt');
  const bytes = Buffer.from('Ask Ralph Smith <ralph@example.com> about it.\r\n');
  fs.writeFileSync(mine, bytes);
  const r = convert(repo);
  assert.equal(r.status, 1, r.stdout + r.stderr);
  assert.match(r.stderr, /notes\.txt/);
  assert.match(r.stderr, /git stash -u/);
  assert.deepEqual(fs.readFileSync(mine), bytes);
  assert.equal(fs.readFileSync(path.join(repo, 'README.md'), 'utf8'), 'Run `ralph run batch`.\n', 'tracked files are untouched too');
});

test('an untracked ralph.conf (renamed, no backup) refuses; so does an ignored one', () => {
  for (const ignored of [false, true]) {
    const repo = makeRepo();
    if (ignored) fs.appendFileSync(path.join(repo, '.gitignore'), 'ralph.conf\n');
    fs.writeFileSync(path.join(repo, 'ralph.conf'), 'RALPH_EXEC=fake\n');
    const r = convert(repo, '--allow-dirty');
    assert.equal(r.status, 1, r.stdout + r.stderr);
    assert.match(r.stderr, /ralph\.conf/);
    assert.equal(fs.readFileSync(path.join(repo, 'ralph.conf'), 'utf8'), 'RALPH_EXEC=fake\n');
    assert.ok(!fs.existsSync(path.join(repo, 'foreman.conf')));
  }
});

test('the refusal lists about ten paths, not all of them', () => {
  const repo = makeRepo();
  for (let i = 0; i < 15; i++) fs.writeFileSync(path.join(repo, `u${String(i).padStart(2, '0')}.txt`), 'Ralph\n');
  const r = convert(repo);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /u00\.txt/);
  assert.doesNotMatch(r.stderr, /u14\.txt/);
  assert.match(r.stderr, /5 more/);
});

test('a repo whose only Ralph is in tracked files still converts, and the run files (git-ignored by design) are renamed', () => {
  const repo = makeRepo();
  fs.writeFileSync(path.join(repo, 'ralph-runs.jsonl'), '{}\n');
  const r = convert(repo);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.equal(fs.readFileSync(path.join(repo, 'README.md'), 'utf8'), 'Run `foreman run batch`.\n');
  assert.ok(fs.existsSync(path.join(repo, 'foreman-runs.jsonl')));
});

test('untracked files with no Ralph in them are not a reason to refuse', () => {
  const repo = makeRepo();
  fs.writeFileSync(path.join(repo, 'scratch.txt'), 'nothing here\n');
  const r = convert(repo);
  assert.equal(r.status, 0, r.stdout + r.stderr);
});

test('--dry-run lists everything, marks the untracked file, changes nothing, and exits 0', () => {
  const repo = makeRepo();
  const mine = path.join(repo, 'notes.txt');
  fs.writeFileSync(mine, 'Ask Ralph.\n');
  const r = convert(repo, '--dry-run');
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /rewrote  README\.md/);
  const line = r.stdout.split('\n').find((l) => l.includes('notes.txt'));
  assert.ok(line, r.stdout);
  assert.match(line, /untracked/);
  assert.doesNotMatch(r.stdout.split('\n').find((l) => l.includes('README.md')), /untracked/);
  assert.match(r.stdout, /git stash -u/);
  assert.equal(fs.readFileSync(mine, 'utf8'), 'Ask Ralph.\n');
});
