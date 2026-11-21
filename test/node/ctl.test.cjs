// The control directory has one definition in bash (lib/foreman-ctl.sh) and one in node
// (lib/foreman-ctl.cjs). They must name the same files, and the node helpers must read what the bash
// helpers write.
'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const LIB = path.join(__dirname, '..', '..', 'lib');
const Ctl = require(path.join(LIB, 'foreman-ctl.cjs'));
const fwd = (p) => p.split(path.sep).join('/');

// Runs a bash snippet with foreman-ctl.sh sourced. Paths are handed over as arguments, never spliced
// into the script (a Windows path would not survive the shell).
function bash(script, ...args) {
  const r = spawnSync('bash', ['-c', `source "$1/foreman-ctl.sh" || exit 99\n${script}`, '_', fwd(LIB), ...args],
    { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout;
}

test('ctl: bash and node name the same control files', () => {
  const fromBash = {};
  for (const line of bash('for v in $(compgen -A variable CTL_F_); do printf "%s=%s\n" "$v" "${!v}"; done').split('\n')) {
    if (line) fromBash[line.slice('CTL_F_'.length, line.indexOf('=')).toLowerCase()] = line.slice(line.indexOf('=') + 1);
  }
  assert.deepEqual(fromBash, { ...Ctl.FILES });
  const list = bash('printf "%s\n" "${CTL_FILES[@]}"').split('\n').filter(Boolean);
  assert.deepEqual([...list].sort(), Object.values(Ctl.FILES).sort(), 'CTL_FILES lists every name');
  assert.equal(bash('printf %s "$CTL_DIRNAME"'), Ctl.DIRNAME);
});

test('ctl: the gitignore line the repo helper writes names the same directory', () => {
  const out = bash('source "$1/foreman-repo.sh"; printf %s "$FOREMAN_RUN_IGNORE"');
  assert.equal(out, `**/${Ctl.DIRNAME}/`);
});

test('ctl: the repo-relative directory is spelled the same', () => {
  for (const batch of ['.', '.scratch/b', 'a']) {
    assert.equal(bash('ctl_rel_dir "$2" R; printf %s "$R"', batch), Ctl.relDir(batch));
  }
});

test('ctl: the pid file bash writes is the one node parses', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'foreman-ctl-'));
  try {
    const d = fwd(dir);
    const loopPid = bash('ctl_write_pid "$2"; printf %s $$', d).trim();
    const pid = Ctl.parsePid(fs.readFileSync(path.join(dir, Ctl.FILES.pid), 'utf8'));
    assert.ok(pid && pid.msys > 0 && pid.win > 0, 'two positive pids');
    assert.equal(String(pid.msys), loopPid);
    // And bash reads back what it wrote
    const back = bash('ctl_write_pid "$2"; ctl_read_pid "$2"; printf "%s %s" "$CTL_PID_MSYS" "$CTL_PID_WIN"; echo; run_pid_alive "$$" "$CTL_PID_WIN" && echo alive', d).split('\n');
    assert.match(back[0], /^\d+ \d+$/);
    assert.equal(back[1], 'alive');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('ctl: bash write is whole, clear keeps only out', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'foreman-ctl-'));
  try {
    const d = fwd(dir);
    bash('ctl_write "$2" "$CTL_F_BUDGET" 5; : > "$2/$CTL_F_OUT"; : > "$2/$CTL_F_FEED"; ctl_clear "$2"', d);
    assert.deepEqual(fs.readdirSync(dir), [Ctl.FILES.out]);
    bash('rm "$2/$CTL_F_OUT"; ctl_write "$2" "$CTL_F_LIVE" 1; ctl_clear "$2"', d);
    assert.equal(fs.existsSync(dir), false, 'no out, so the directory goes too');
    assert.equal(bash('ctl_write "$2" live 1 2>/dev/null || echo failed', d + '/nowhere').trim(), 'failed');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('ctl: parsePid takes one or two positive integers and nothing else', () => {
  assert.deepEqual(Ctl.parsePid('123 456\n'), { msys: 123, win: 456 });
  assert.deepEqual(Ctl.parsePid('123\n'), { msys: 123, win: 123 });
  for (const bad of [null, '', '  \n', 'abc', '0 5', '-3 4', '1.5 2', '12 x']) assert.equal(Ctl.parsePid(bad), null, JSON.stringify(bad));
});

test('ctl: pidAlive is true for this process and false for a pid that cannot exist', () => {
  assert.equal(Ctl.pidAlive(process.pid), true);
  assert.equal(Ctl.pidAlive(2 ** 22 + 12345), false);
});

test('ctl: writeWhole leaves the whole text and no temp file; a gone directory is not an error', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'foreman-ctl-'));
  try {
    const f = Ctl.filePath(dir, Ctl.FILES.activity);
    assert.equal(Ctl.writeWhole(f, '1700000000 Read x\n'), true);
    assert.equal(fs.readFileSync(f, 'utf8'), '1700000000 Read x\n');
    assert.deepEqual(fs.readdirSync(dir), [Ctl.FILES.activity]);
    assert.equal(Ctl.writeWhole(Ctl.filePath(path.join(dir, 'gone'), 'x'), 'y'), false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------------------
// Where a batch's control directory is: ctl_dir in bash, resolveDir in node, the same answer.
// ---------------------------------------------------------------------------

function git(cwd, ...args) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
}

// A repository with batches at the root (`.`), `b` and `.scratch/my batch`, committed, and its own
// identity so it commits anywhere. `ignore` adds the line `doctor --fix` writes.
function makeRepo({ ignore = false } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'foreman-ctldir-'));
  git(root, 'init', '-q');
  git(root, 'config', 'user.email', 't@example.com');
  git(root, 'config', 'user.name', 't');
  for (const b of ['b', '.scratch/my batch']) {
    fs.mkdirSync(path.join(root, b), { recursive: true });
    fs.writeFileSync(path.join(root, b, 'foreman.conf'), '');
  }
  fs.writeFileSync(path.join(root, 'foreman.conf'), '');
  if (ignore) fs.writeFileSync(path.join(root, '.gitignore'), `**/${Ctl.DIRNAME}/\n`);
  git(root, 'add', '-A');
  git(root, 'commit', '-q', '-m', 'init');
  return root;
}

// What bash says, run from the repository root as every caller is.
function bashDir(root, batch) {
  const r = spawnSync('bash', ['-c', 'source "$1/foreman-ctl.sh" || exit 99; cd "$2" || exit 98; ctl_dir "$3" D || exit 97; printf "%s\n%s" "$D" "$CTL_WHERE"',
    '_', fwd(LIB), fwd(root), batch], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  const [dir, where] = r.stdout.split('\n');
  return { dir, where };
}

const BATCHES = ['.', 'b', '.scratch/my batch'];

test('ctl: the key is reversible and filesystem-safe, and bash spells it as node does', () => {
  const names = [...BATCHES, 'a/b/c', 'x__y', 'per%cent', 'dots.in.it', 'naïve/ünï', 'a:b*c?"<>|\\d', '-lead', 'x/./y'];
  for (const b of names) {
    const key = Ctl.keyOf(b);
    assert.match(key, /^[-A-Za-z0-9_%\u0080-\uffff]+$/u, `${b} -> ${key}`);
    assert.ok(!key.includes('/') && !key.includes('.') && key !== '', `${b} -> ${key}`);
    assert.equal(Ctl.batchOfKey(key), b, `round trip of ${JSON.stringify(b)}`);
    assert.equal(bash('ctl_key "$2" K; printf %s "$K"', b), key, `bash key of ${JSON.stringify(b)}`);
  }
  assert.equal(Ctl.keyOf('b'), 'b', 'a plain name is its own key');
  assert.equal(Ctl.keyOf('.'), '%2E');
  assert.equal(Ctl.keyOf('.scratch/b'), '%2Escratch%2Fb');
  // Two batches never share a key.
  assert.notEqual(Ctl.keyOf('a/b'), Ctl.keyOf('a__b'));
  assert.notEqual(Ctl.keyOf('a/b'), Ctl.keyOf('a%2Fb'));
});

test('ctl: a batch whose .foreman-run/ is ignored keeps it in the batch, in bash and node', () => {
  const root = makeRepo({ ignore: true });
  try {
    for (const b of BATCHES) {
      const want = Ctl.relDir(b);
      assert.deepEqual(bashDir(root, b), { dir: want, where: 'batch' }, `bash, ${b}`);
      assert.deepEqual(Ctl.resolveDir(root, b), { dir: want, where: 'batch' }, `node, ${b}`);
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('ctl: a batch whose .foreman-run/ is not ignored keeps it under the git directory, in bash and node', () => {
  const root = makeRepo();
  try {
    for (const b of BATCHES) {
      const want = `.git/foreman-run/${Ctl.keyOf(b)}`;
      assert.deepEqual(bashDir(root, b), { dir: want, where: 'git' }, `bash, ${b}`);
      assert.deepEqual(Ctl.resolveDir(root, b), { dir: want, where: 'git' }, `node, ${b}`);
    }
    // The pure part: a git directory that git gave relative, or absolute in either spelling.
    assert.equal(Ctl.dirFor('b', { ignored: false, gitDir: '.git' }), '.git/foreman-run/b');
    assert.equal(Ctl.dirFor('b', { ignored: false, gitDir: 'C:/r/.git/worktrees/w/' }), 'C:/r/.git/worktrees/w/foreman-run/b');
    assert.equal(Ctl.dirFor('b', { ignored: false, gitDir: 'C:\\r\\.git' }), 'C:/r/.git/foreman-run/b');
    assert.equal(Ctl.dirFor('a/b', { ignored: true, gitDir: '.git' }), 'a/b/.foreman-run');
    // fullPath: the one a reader opens, from the repository root.
    assert.equal(Ctl.fullPath('C:/r', '.git/foreman-run/b'), 'C:/r/.git/foreman-run/b');
    assert.equal(Ctl.fullPath('C:/r', 'C:/o/.git/foreman-run/b'), 'C:/o/.git/foreman-run/b');
    assert.equal(Ctl.fullPath('/r', '/o/x'), '/o/x');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('ctl: in a worktree the directory is under the worktree\'s own git directory, the same in bash and node', () => {
  const root = makeRepo();
  const wt = `${root}-wt`;
  try {
    git(root, 'worktree', 'add', '-q', fwd(wt));
    const own = git(wt, 'rev-parse', '--absolute-git-dir').replace(/\\/g, '/');
    for (const b of BATCHES) {
      const fromBash = bashDir(wt, b);
      const fromNode = Ctl.resolveDir(wt, b);
      assert.deepEqual(fromNode, fromBash, `bash and node agree, ${b}`);
      assert.equal(fromNode.where, 'git');
      // Spelled as git spells it (C:/... on Windows): the same directory as the worktree's git dir.
      const dir = fromNode.dir;
      assert.ok(path.isAbsolute(dir), `absolute: ${dir}`);
      assert.equal(path.resolve(path.dirname(path.dirname(dir))).toLowerCase(), path.resolve(own).toLowerCase(), `under ${own}: ${dir}`);
      assert.equal(path.basename(dir), Ctl.keyOf(b));
    }
    // And never the main checkout's: two checkouts of one batch are two runs.
    assert.notEqual(Ctl.resolveDir(wt, 'b').dir, Ctl.resolveDir(root, 'b').dir);
  } finally {
    spawnSync('git', ['worktree', 'remove', '--force', fwd(wt)], { cwd: root });
    fs.rmSync(wt, { recursive: true, force: true });
    fs.rmSync(root, { recursive: true, force: true });
  }
});
