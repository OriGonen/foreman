// The control directory of a run, for node: the same file names as foreman-ctl.sh (which documents what
// each file holds and who writes it; test/node/ctl.test.cjs holds the two lists together), the
// pid-file parse, and the liveness check. Required by foreman-stream.cjs, foreman-json.cjs and the
// app (gui/live.cjs, gui/runner.cjs).
//
// Where the directory is: `<batch>/.foreman-run/` when the repository ignores that name, else
// `<git-dir>/foreman-run/<key>` (resolveDir, the twin of ctl_dir in foreman-ctl.sh, which says why).
'use strict';

const fs = require('fs');
const { spawnSync } = require('child_process');

const DIRNAME = '.foreman-run';
// The directory under the git directory that holds the control directories of the batches whose
// repository does not ignore DIRNAME, one per batch, named by keyOf.
const GITDIRNAME = 'foreman-run';

// Every file a run keeps in its control directory, by the key node code uses -> the name on disk.
const FILES = Object.freeze({
  budget: 'budget',
  live: 'live',
  iteration: 'iteration',
  screen: 'screen',
  activity: 'activity',
  foot: 'foot',
  spent: 'spent',
  pid: 'pid',
  run: 'run',
  feed: 'feed',
  stop: 'stop',
  out: 'out',
});

// The repo-relative control directory of a batch (`.` is a batch at the repo root).
function relDir(batchDir) {
  return batchDir === '.' ? DIRNAME : `${batchDir}/${DIRNAME}`;
}

// A batch's repo-relative path (`.` for the root) as one directory name, and back (foreman-ctl.sh ctl_key spells it the
// same). Letters, digits, `_`, `-` and anything outside ASCII stay as they are; every other ASCII
// character becomes `%XX` (upper-case hex), `%` itself included, so the mapping reverses and no key
// holds a `/`, a `.` or a character Windows refuses: `.scratch/b` is `%2Escratch%2Fb`, `.` is `%2E`.
function keyOf(batchDir) {
  let out = '';
  for (const ch of String(batchDir)) {
    const n = ch.codePointAt(0);
    out += n >= 128 || /[A-Za-z0-9_-]/.test(ch) ? ch : `%${n.toString(16).toUpperCase().padStart(2, '0')}`;
  }
  return out;
}
function batchOfKey(key) {
  return String(key).replace(/%([0-9A-F]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));
}

// The control directory of a batch, given what git says: in the batch when its `.foreman-run/` is
// ignored, else `<gitDir>/foreman-run/<key>`. gitDir is `git rev-parse --git-dir` from the repository
// root: `.git` in a plain checkout (so the answer is repo-relative), absolute in a worktree (`C:/...`
// from Git for Windows), with forward slashes either way here.
function dirFor(batchDir, { ignored, gitDir }) {
  if (ignored) return relDir(batchDir);
  return `${String(gitDir).replace(/\\/g, '/').replace(/\/+$/, '')}/${GITDIRNAME}/${keyOf(batchDir)}`;
}

// Asks git, from the repository root, and answers as ctl_dir does: { dir, where } with where 'batch'
// or 'git', and dir as dirFor spells it. The ignore question is asked of the `pid` file's path, as the
// loop has always asked it. `git` runs git with arguments in a directory and returns
// { status, stdout } (spawnSync by default; the app can hand in its own).
function resolveDir(repoRoot, batchDir, git = defaultGit) {
  const ignored = git(repoRoot, ['check-ignore', '-q', '--', `${relDir(batchDir)}/${FILES.pid}`]).status === 0;
  if (ignored) return { dir: relDir(batchDir), where: 'batch' };
  const r = git(repoRoot, ['rev-parse', '--git-dir']);
  const gitDir = r.status === 0 ? String(r.stdout || '').trim() : '';
  if (!gitDir) throw new Error(`no git directory for ${repoRoot}`);
  return { dir: dirFor(batchDir, { ignored: false, gitDir }), where: 'git' };
}
function defaultGit(cwd, args) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8', windowsHide: true });
  return { status: r.status, stdout: r.stdout };
}

// The path a reader opens for a control directory as resolveDir or `status --json` gives it: an
// absolute one as it is, a repo-relative one under the repository root.
function fullPath(repoRoot, dir) {
  if (/^([A-Za-z]:)?[\\/]/.test(dir)) return dir;
  return `${String(repoRoot).replace(/[\\/]+$/, '')}/${dir}`;
}

// A file in a control directory, in the spelling every reader uses: `<dir>/<name>`.
function filePath(dir, name) {
  return `${dir}/${name}`;
}

// The pid file's text, "MSYS_PID WINDOWS_PID", as { msys, win }; the Windows pid is the MSYS one when
// there is only one number (off Windows the two are the same). null when there is no pid, or any word
// of it is not a positive integer.
function parsePid(text) {
  const pids = (text || '').trim().split(/\s+/).filter(Boolean).map(Number);
  if (pids.length === 0 || !pids.every((n) => Number.isInteger(n) && n > 0)) return null;
  const [msys, win = msys] = pids;
  return { msys, win };
}

// Whether a process is alive, by the pid the loop wrote for it. `kill 0` sends nothing: it only asks
// (EPERM means it is there and not ours). The loop's own word, `runalive` in `status --json`'s facts,
// is the better answer where there is one (foreman-ctl.sh run_pid_alive: it knows a recycled pid).
function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return Boolean(e) && e.code === 'EPERM';
  }
}

// Writes `text` to `file` whole: a temp file and a rename, so a reader never sees half of it. Windows
// can refuse the rename while a reader has the file open; then it is written in place, and a torn read
// costs one second of one label. Returns false when the directory is gone (the run is ending).
function writeWhole(file, text) {
  const tmp = `${file}.tmp`;
  try {
    fs.writeFileSync(tmp, text);
    fs.renameSync(tmp, file);
    return true;
  } catch {
    try {
      fs.writeFileSync(file, text);
      return true;
    } catch {
      return false;
    }
  }
}

module.exports = {
  DIRNAME, GITDIRNAME, FILES, relDir, keyOf, batchOfKey, dirFor, resolveDir, fullPath, filePath, parsePid, pidAlive, writeWhole,
};
