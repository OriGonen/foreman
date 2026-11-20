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
