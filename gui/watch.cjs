'use strict';
// Watches a batch's directories and says "read again" when something in them changes.
//
// fs.watch and a 150 ms debounce, never a timer poll: with nothing happening nothing runs, not
// even a timer. An editor saving a file, or the loop committing, is a burst of events; the read
// happens once, 150 ms after the last of them. The debounce and the one retry below are one-shot
// timers that exist only while a change is waiting to be read.
//
// A read can fail because the loop renamed something under it (a landed ticket to DONE_<name>,
// the whole batch to DONE_<batch>). That is not an error to show: the read is tried once more
// after the debounce, and only a second failure is reported. After every read the directories to
// watch are asked for again, so the watch follows the batch to where it went and picks up a
// `.foreman-run/` that appeared; a directory that cannot be watched yet is simply tried again
// next time. A watch that ends (the directory it held was renamed) counts as a change, not as
// a failure.
//
//   const w = createWatcher({
//     dirs:     async () => [directories to watch, as they are now],
//     read:     async () => whatever the screen needs,           // e.g. status --json
//     onResult: (result) => ...,                                 // after a successful read
//     onError:  (error)  => ...,                                 // after the retry failed too
//   });
//   await w.start();   w.stop();
//
// `fsWatch`, `setTimer` and `clearTimer` are there so the tests can drive time; they default to
// fs.watch and setTimeout.
const fs = require('fs');

const DEBOUNCE_MS = 150;

function createWatcher({
  dirs, read, onResult, onError,
  fsWatch = fs.watch, setTimer = setTimeout, clearTimer = clearTimeout, debounceMs = DEBOUNCE_MS,
}) {
  const open = new Map();      // directory -> its fs.watch handle
  let timer = null;
  let reading = false;
  let dirtyWhileReading = false;
  let attempt = 0;             // 0 for a fresh read, 1 for its one retry
  let stopped = false;

  function schedule() {
    if (stopped) return;
    if (reading) { dirtyWhileReading = true; return; }
    if (timer !== null) clearTimer(timer);
    timer = setTimer(run, debounceMs);
  }

  function onEvent() {
    attempt = 0;
    schedule();
  }

  function watchDir(dir) {
    let handle;
    try {
      handle = fsWatch(dir, { recursive: true }, onEvent);
    } catch {
      return;                  // not there (yet): the next read looks again
    }
    handle.on('error', () => {
      // The directory under the handle went away or was renamed: let it go, and read.
      try { handle.close(); } catch { /* already closed */ }
      if (open.get(dir) === handle) open.delete(dir);
      onEvent();
    });
    open.set(dir, handle);
  }

  async function sync() {
    let wanted;
    try { wanted = await dirs(); } catch { return; }
    if (stopped) return;
    for (const [dir, handle] of open) {
      if (wanted.includes(dir)) continue;
      try { handle.close(); } catch { /* already closed */ }
      open.delete(dir);
    }
    for (const dir of wanted) if (!open.has(dir)) watchDir(dir);
  }

  async function run() {
    timer = null;
    if (stopped) return;
    reading = true;
    dirtyWhileReading = false;
    let result, failure = null;
    try { result = await read(); } catch (e) { failure = e; }
    reading = false;
    if (stopped) return;
    await sync();
    if (stopped) return;
    if (failure === null) {
      attempt = 0;
      onResult(result);
    } else if (attempt === 0) {
      attempt = 1;             // maybe a rename was in the way: once more after the debounce
      schedule();
      return;
    } else {
      attempt = 0;
      onError(failure);
    }
    if (dirtyWhileReading) schedule();
  }

  return {
    async start() { await sync(); },
    stop() {
      stopped = true;
      if (timer !== null) { clearTimer(timer); timer = null; }
      for (const handle of open.values()) { try { handle.close(); } catch { /* already closed */ } }
      open.clear();
    },
  };
}

module.exports = { createWatcher, DEBOUNCE_MS };
