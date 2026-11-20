// The control directory of a run, for node: the same file names as foreman-ctl.sh (which documents what
// each file holds and who writes it; test/node/ctl.test.cjs holds the two lists together), the
// pid-file parse, and the liveness check. Required by foreman-stream.cjs, foreman-json.cjs and the
// app (gui/live.cjs, gui/runner.cjs).
//
// The run's directory is `<batch>/.foreman-run/`; it is only there for a batch whose repository
// ignores that name (see foreman-ctl.sh).
'use strict';

const fs = require('fs');

const DIRNAME = '.foreman-run';

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

module.exports = { DIRNAME, FILES, relDir, filePath, parsePid, pidAlive, writeWhole };
