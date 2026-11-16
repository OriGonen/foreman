'use strict';
// watch.cjs: fs.watch with a 150 ms debounce, never a poll; a read that fails mid-rename is retried,
// and a DONE_ rename moves the watch to where the batch went. A fake fs.watch and a fake clock, so
// every case is exact.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createWatcher, DEBOUNCE_MS } = require('../watch.cjs');

// A clock that only moves when told to.
function fakeClock() {
  let now = 0, next = 1;
  const timers = new Map();
  return {
    setTimer(fn, ms) { const id = next++; timers.set(id, { at: now + ms, fn }); return id; },
    clearTimer(id) { timers.delete(id); },
    async advance(ms) {
      const end = now + ms;
      for (;;) {
        let due = null;
        for (const [id, t] of timers) if (t.at <= end && (!due || t.at < due[1].at)) due = [id, t];
        if (!due) break;
        timers.delete(due[0]); now = due[1].at; due[1].fn();
        await settle();
      }
      now = end;
      await settle();
    },
    get pending() { return timers.size; },
  };
}
const settle = () => new Promise((r) => setImmediate(r));

// A fake fs.watch: remembers each watch, and lets a case fire an event or an error on it.
function fakeFs() {
  const open = [];
  return {
    open,
    watch(dir, opts, listener) {
      const w = { dir, opts, listener, closed: false, handlers: {} };
      w.on = (ev, fn) => { w.handlers[ev] = fn; return w; };
      w.close = () => { w.closed = true; };
      open.push(w);
      return w;
    },
    live: () => open.filter((w) => !w.closed).map((w) => w.dir),
    fire(dir, name = 'x.md') { open.filter((w) => w.dir === dir && !w.closed).forEach((w) => w.listener('change', name)); },
    fail(dir) { open.filter((w) => w.dir === dir && !w.closed).forEach((w) => w.handlers.error && w.handlers.error(Object.assign(new Error('gone'), { code: 'EPERM' }))); },
  };
}

function setup(over = {}) {
  const clock = fakeClock();
  const fsw = fakeFs();
  const results = [], errors = [];
  let reads = 0;
  const w = createWatcher({
    dirs: over.dirs || (async () => ['batch']),
    read: over.read || (async () => { reads++; return { n: reads }; }),
    onResult: (r) => results.push(r),
    onError: (e) => errors.push(e),
    fsWatch: fsw.watch, setTimer: clock.setTimer, clearTimer: clock.clearTimer,
  });
  return { clock, fsw, results, errors, w, reads: () => reads };
}

test('the debounce is 150 ms', () => assert.equal(DEBOUNCE_MS, 150));

test('an event is read 150 ms later, not before', async () => {
  const t = setup();
  await t.w.start();
  t.fsw.fire('batch');
  await t.clock.advance(149);
  assert.equal(t.results.length, 0);
  await t.clock.advance(1);
  assert.equal(t.results.length, 1);
});

test('a burst of events is one read, 150 ms after the last of them', async () => {
  const t = setup();
  await t.w.start();
  t.fsw.fire('batch'); await t.clock.advance(100);
  t.fsw.fire('batch'); await t.clock.advance(100);
  t.fsw.fire('batch'); await t.clock.advance(149);
  assert.equal(t.results.length, 0, 'still waiting for quiet');
  await t.clock.advance(1);
  assert.equal(t.results.length, 1);
  assert.equal(t.reads(), 1);
});

test('nothing happening is nothing done: no read, and no timer left running', async () => {
  const t = setup();
  await t.w.start();
  await t.clock.advance(60 * 60 * 1000);
  assert.equal(t.reads(), 0);
  assert.equal(t.clock.pending, 0);
});

test('watch.cjs never polls: no setInterval anywhere in it', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'watch.cjs'), 'utf8');
  assert.doesNotMatch(src.replace(/\/\/.*$/gm, ''), /setInterval/);
});

test('it watches each directory with fs.watch, recursively', async () => {
  const t = setup({ dirs: async () => ['batch', 'batch/.foreman-run'] });
  await t.w.start();
  assert.deepEqual(t.fsw.live(), ['batch', 'batch/.foreman-run']);
  assert.equal(t.fsw.open[0].opts.recursive, true);
});

test('an event during a read asks for one more read after it, not several', async () => {
  let release; let reads = 0;
  const t = setup({ read: () => { reads++; return new Promise((r) => { release = () => r({ n: reads }); }); } });
  await t.w.start();
  t.fsw.fire('batch');
  await t.clock.advance(150);
  assert.equal(reads, 1, 'the first read is under way');
  t.fsw.fire('batch'); await t.clock.advance(50); t.fsw.fire('batch'); await t.clock.advance(200);
  assert.equal(reads, 1, 'and no second read starts while it is');
  release(); await settle();
  await t.clock.advance(150);
  assert.equal(reads, 2, 'one more, for everything that came meanwhile');
  release(); await settle();
  assert.equal(t.results.length, 2);
});

test('a read that fails is retried once after the debounce, and no error is shown if the retry works', async () => {
  let calls = 0;
  const t = setup({ read: async () => { calls++; if (calls === 1) throw new Error('ENOENT: renamed under us'); return { ok: calls }; } });
  await t.w.start();
  t.fsw.fire('batch');
  await t.clock.advance(150);
  assert.equal(calls, 1);
  assert.equal(t.errors.length, 0, 'no error yet');
  assert.equal(t.results.length, 0);
  await t.clock.advance(150);
  assert.equal(calls, 2);
  assert.deepEqual(t.results, [{ ok: 2 }]);
  assert.equal(t.errors.length, 0, 'and none after');
});

test('a read that fails twice is an error, once', async () => {
  const t = setup({ read: async () => { throw new Error('really broken'); } });
  await t.w.start();
  t.fsw.fire('batch');
  await t.clock.advance(150 + 150 + 1000);
  assert.equal(t.errors.length, 1);
  assert.match(t.errors[0].message, /really broken/);
  assert.equal(t.results.length, 0);
});

test('a DONE_ rename: the old watch is dropped, the batch is found where it went, and the change is read', async () => {
  let where = 'batch';
  const t = setup({ dirs: async () => [where] });
  await t.w.start();
  assert.deepEqual(t.fsw.live(), ['batch']);
  where = 'DONE_batch';                     // the loop renames the directory...
  t.fsw.fail('batch');                      // ...and the handle on it reports that it is gone
  await t.clock.advance(150);
  assert.equal(t.errors.length, 0, 'a watch that ends is not an error to show');
  assert.equal(t.results.length, 1, 'it is a change: read it');
  assert.deepEqual(t.fsw.live(), ['DONE_batch'], 'and the watch moved with the batch');
  t.fsw.fire('DONE_batch');
  await t.clock.advance(150);
  assert.equal(t.results.length, 2, 'events on the new place count');
});

test('the directories are looked up again after every read, so a new .foreman-run/ is watched', async () => {
  let dirs = ['batch'];
  const t = setup({ dirs: async () => dirs });
  await t.w.start();
  dirs = ['batch', 'batch/.foreman-run'];
  t.fsw.fire('batch');
  await t.clock.advance(150);
  assert.deepEqual(t.fsw.live(), ['batch', 'batch/.foreman-run']);
  dirs = ['batch'];
  t.fsw.fire('batch');
  await t.clock.advance(150);
  assert.deepEqual(t.fsw.live(), ['batch'], 'and one that went is let go');
});

test('a directory that cannot be watched yet is not an error, and is tried again after the next read', async () => {
  const clock = fakeClock();
  const opened = [];
  let throwFor = 'batch/.foreman-run';
  const results = [], errors = [];
  const w = createWatcher({
    dirs: async () => ['batch', 'batch/.foreman-run'],
    read: async () => ({ ok: 1 }),
    onResult: (r) => results.push(r), onError: (e) => errors.push(e),
    fsWatch: (dir, o, l) => {
      if (dir === throwFor) throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' });
      const h = { dir, close() { this.closed = true; }, on() { return this; } }; opened.push(h); h.l = l; return h;
    },
    setTimer: clock.setTimer, clearTimer: clock.clearTimer,
  });
  await w.start();
  assert.deepEqual(opened.map((h) => h.dir), ['batch']);
  assert.equal(errors.length, 0);
  throwFor = null;
  opened[0].l('change', 'x');
  await clock.advance(150);
  assert.deepEqual(opened.filter((h) => !h.closed).map((h) => h.dir).sort(), ['batch', 'batch/.foreman-run']);
});

test('stop closes every watch and drops the pending read', async () => {
  const t = setup();
  await t.w.start();
  t.fsw.fire('batch');
  t.w.stop();
  assert.deepEqual(t.fsw.live(), []);
  await t.clock.advance(1000);
  assert.equal(t.reads(), 0);
  assert.equal(t.clock.pending, 0);
});

test('a read finishing after stop is not delivered', async () => {
  let release;
  const t = setup({ read: () => new Promise((r) => { release = () => r({ late: true }); }) });
  await t.w.start();
  t.fsw.fire('batch');
  await t.clock.advance(150);
  t.w.stop();
  release(); await settle();
  assert.equal(t.results.length, 0);
});

// ---- what changed is handed to the read (ticket 10) ----

test('read is given what changed since the last read: the directory and the name, with forward slashes', async () => {
  const seen = [];
  const t = setup({ read: async (changes) => { seen.push(changes); return 1; } });
  await t.w.start();
  t.fsw.fire('batch', 'issues\\01-a.md');
  t.fsw.fire('batch', '.foreman-run/feed');
  t.fsw.fire('batch', '.foreman-run/feed');
  await t.clock.advance(150);
  assert.deepEqual(seen[0], [
    { dir: 'batch', name: 'issues/01-a.md' }, { dir: 'batch', name: '.foreman-run/feed' }, { dir: 'batch', name: '.foreman-run/feed' },
  ], 'one read for the burst, and it knows what was in it');
  t.fsw.fire('batch', 'foreman-runs.jsonl');
  await t.clock.advance(150);
  assert.deepEqual(seen[1], [{ dir: 'batch', name: 'foreman-runs.jsonl' }], 'the next read has only what is new');
});

test('an event with no name, or a watch that ended, reads as "something changed": name null', async () => {
  const seen = [];
  const t = setup({ read: async (changes) => { seen.push(changes); return 1; } });
  await t.w.start();
  t.fsw.fire('batch', null);
  await t.clock.advance(150);
  assert.deepEqual(seen[0], [{ dir: 'batch', name: null }]);
  t.fsw.fail('batch');
  await t.clock.advance(150);
  assert.deepEqual(seen[1], [{ dir: 'batch', name: null }]);
});

test('the one retry after a failed read is given what the failed read was given, and what came since', async () => {
  const seen = [];
  let n = 0;
  const t = setup({ read: async (changes) => { seen.push(changes.map((c) => c.name)); if (++n === 1) throw new Error('renamed under us'); return n; } });
  await t.w.start();
  t.fsw.fire('batch', 'a');
  await t.clock.advance(150);
  assert.equal(t.errors.length, 0, 'not an error yet');
  await t.clock.advance(150);
  assert.deepEqual(seen, [['a'], ['a']]);
  assert.equal(t.results.length, 1);
});

test('a read that was rejected (a timed-out CLI call) does not wedge the watcher: the next change is read', async () => {
  let calls = 0;
  const t = setup({ read: async () => { calls++; if (calls <= 2) throw new Error('foreman did not answer within 60 s'); return { ok: calls }; } });
  await t.w.start();
  t.fsw.fire('batch');
  await t.clock.advance(150 + 150 + 1000);
  assert.equal(t.errors.length, 1, 'the failure is shown once');
  t.fsw.fire('batch');
  await t.clock.advance(150);
  assert.deepEqual(t.results, [{ ok: 3 }], 'and a later change is read again');
});
