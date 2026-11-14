'use strict';
// app.js, run against a small fake DOM (there is no browser in the tests, and no Electron). What
// is held here is that the screens draw without throwing, that what they show is what model.js
// decided, that ticket and CLI text only ever becomes text, and that a click asks main for the
// right thing. How it looks is checked by a person against the design.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { sample, dryRunSample } = require('./sample.cjs');

// ---- the fake DOM: only what app.js and art.js use ----

class Text { constructor(t) { this.data = String(t); this.parent = null; } get textContent() { return this.data; } }

class El {
  constructor(tag) {
    this.tagName = tag; this.children = []; this.parent = null; this.attrs = {}; this.listeners = {};
    this.style = {}; this.className = ''; this.disabled = false; this.title = ''; this.scrollTop = 0;
    this.classList = {
      add: (c) => { if (!this.className.split(' ').includes(c)) this.className = (this.className + ' ' + c).trim(); },
      remove: (c) => { this.className = this.className.split(' ').filter((x) => x && x !== c).join(' '); },
    };
  }
  set innerHTML(_v) { throw new Error('innerHTML was set'); }
  set outerHTML(_v) { throw new Error('outerHTML was set'); }
  get textContent() { return this.children.map((c) => c.textContent).join(''); }
  set textContent(v) { this.children = []; if (v !== '') this._add(new Text(v)); }
  _add(k) { if (k.parent) k.parent.children = k.parent.children.filter((c) => c !== k); k.parent = this; this.children.push(k); }
  append(...kids) { for (const k of kids) this._add(typeof k === 'string' ? new Text(k) : k); }
  appendChild(k) { this._add(k); return k; }
  replaceChildren(...kids) { this.children = []; this.append(...kids); }
  get firstChild() { return this.children[0] || null; }
  get lastChild() { return this.children[this.children.length - 1] || null; }
  setAttribute(k, v) { this.attrs[k] = String(v); if (k === 'class') this.className = String(v); }
  getAttribute(k) { return this.attrs[k] === undefined ? null : this.attrs[k]; }
  get dataset() {
    const o = {};
    for (const [k, v] of Object.entries(this.attrs)) if (k.startsWith('data-')) o[k.slice(5)] = v;
    return o;
  }
  addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); }
  click() { if (!this.disabled) for (const fn of this.listeners.click || []) fn({ target: this }); }
  focus() { this.ownerDocument.activeElement = this; }
  all() { return this.children.flatMap((c) => (c instanceof El ? [c, ...c.all()] : [])); }
  matches(sel) {
    const cls = /^\.([\w-]+)$/.exec(sel);
    if (cls) return this.className.split(/\s+/).includes(cls[1]);
    const attr = /^\[([\w-]+)\]$/.exec(sel);
    if (attr) return attr[1] in this.attrs;
    throw new Error('fake DOM: selector ' + sel);
  }
  querySelectorAll(sel) { return this.all().filter((e) => e.matches(sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}

function boot(api) {
  const document = { title: '', activeElement: null };
  const make = (tag) => { const e = new El(tag); e.ownerDocument = document; return e; };
  document.createElement = make;
  document.createElementNS = (_ns, tag) => make(tag);
  const app = make('div');
  document.getElementById = (id) => { assert.equal(id, 'app'); return app; };
  const win = { document, foreman: api };
  win.window = win;
  vm.createContext(win);
  for (const f of ['model.js', 'art.js', 'app.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', f), 'utf8'), win, { filename: f });
  }
  return { app, document };
}

const tick = () => new Promise((r) => setImmediate(r));
const text = (app) => app.textContent;
const buttons = (app) => app.all().filter((e) => e.tagName === 'button');
const buttonNamed = (app, name) => buttons(app).find((b) => b.textContent.startsWith(name));

function data(over = {}) {
  const status = sample();
  return {
    ok: true, repoRoot: 'C:/Projects/app', selected: '.scratch/b', status, statusError: null,
    all: { batches: [
      { path: '.scratch/b', name: 'b', finished: false, counts: { done: 4, total: 10 }, human_remaining: 1, next: status.next.file, error: null },
      { path: '.scratch/c', name: 'c', finished: false, counts: { done: 0, total: 3 }, human_remaining: 0, next: 'x', error: null },
      { path: '.scratch/DONE_old', name: 'DONE_old', finished: true, counts: null, human_remaining: null, next: null, error: null },
    ] },
    ...over,
  };
}

function fakeApi(first, dry = { ok: true, doc: dryRunSample() }) {
  const calls = { load: [], open: [], dryRun: [] };
  let update = null;
  return {
    calls, push: (d) => update(d),
    load: async (b) => { calls.load.push(b); return typeof first === 'function' ? first(b) : first; },
    dryRun: async (b) => { calls.dryRun.push(b); return typeof dry === 'function' ? dry(b) : dry; },
    open: async (p) => { calls.open.push(p); return null; },
    onUpdate: (fn) => { update = fn; return () => {}; },
  };
}

// ---- the overview ----

test('the overview shows the dome, the next ticket, the human ticket, the note and the order', async () => {
  const api = fakeApi(data());
  const { app, document } = boot(api);
  await tick();
  const t = text(app);
  for (const want of ['.scratch/b', 'of 10', 'landed · 6 to go', '$9.84 spent in 2 runs', '05 document-human-tickets',
    'Blocked by', '04 ✓ landed', '20261021-2 · paused: iteration budget reached', '07 try-it-on-a-real-repo',
    'The loop will run 2 ticket(s), then stop at 07-try-it-on-a-real-repo.md for a human.',
    'human-ticket-status', '$1.12', 'followup · checks 07']) {
    assert.ok(t.includes(want), `the overview shows ${JSON.stringify(want)}`);
  }
  assert.equal(document.title, 'Foreman — .scratch/b');
  assert.deepEqual(api.calls.load, [null]);
  assert.ok(app.all().filter((e) => e.tagName === 'rect').length >= 10, 'the dome has its stakes');
});

test('free actions are marked free, paid ones say they cost money, and what is not built yet is disabled, not dead', async () => {
  const { app } = boot(fakeApi(data()));
  await tick();
  const dry = buttonNamed(app, 'Dry run');
  const start = buttonNamed(app, 'Start run…');
  assert.ok(dry.textContent.includes('free'));
  assert.ok(start.textContent.includes('costs money'));
  assert.equal(dry.disabled, false, 'the dry run is built');
  assert.equal(start.disabled, true);
  assert.ok(start.title.length > 0, 'a disabled button says why');
  assert.equal(buttonNamed(app, 'Open ticket').disabled, false);
  assert.equal(buttonNamed(app, 'Open folder').disabled, false);
});

test('the rail lists every batch, marks the one shown, and a click on another asks for it', async () => {
  const api = fakeApi((b) => (b === '.scratch/c' ? data({ selected: '.scratch/c' }) : data()));
  const { app } = boot(api);
  await tick();
  const items = app.all().filter((e) => e.attrs['data-batch']);
  assert.deepEqual(items.map((i) => i.attrs['data-batch']), ['.scratch/b', '.scratch/c', '.scratch/DONE_old']);
  assert.equal(items[0].attrs['aria-current'], 'page');
  assert.ok(items[0].className.includes('on'));
  assert.ok(items[2].className.includes('done'));
  assert.equal(items[0].textContent, 'b4/10');
  items[1].click();
  await tick();
  assert.deepEqual(api.calls.load, [null, '.scratch/c']);
  assert.ok(app.all().filter((e) => e.attrs['data-batch'])[1].className.includes('on'));
});

test('Open ticket and Open folder ask main to open a repo-relative path, nothing else', async () => {
  const api = fakeApi(data());
  const { app } = boot(api);
  await tick();
  buttonNamed(app, 'Open ticket').click();
  buttonNamed(app, 'Open folder').click();
  assert.deepEqual(api.calls.open, ['.scratch/b/issues/05-document-human-tickets.md', '.scratch/b']);
});

test('a file changed on disk: the pushed overview replaces the one on screen, with no reload', async () => {
  const api = fakeApi(data());
  const { app } = boot(api);
  await tick();
  assert.ok(text(app).includes('4of 10') || text(app).includes('of 10'));
  const d = data();
  for (let i = 4; i < 6; i++) { d.status.tickets[i].state = 'done'; d.status.tickets[i].done = true; }
  d.status.counts = { done: 6, total: 10 };
  d.status.next = { file: d.status.tickets[6].file, human: true, handoff: d.status.tickets[6].handoff, sent_back_by: null };
  d.status.tickets[6].state = 'next';
  d.status.run_until = null;
  api.push(d);
  assert.ok(text(app).includes('landed · 4 to go'));
  assert.ok(text(app).includes('it is next: a run stops there until you mark it done'));
});

test('the person\'s place survives a redraw: scroll position and the focused batch', async () => {
  const api = fakeApi(data());
  const { app, document } = boot(api);
  await tick();
  app.querySelector('.main').scrollTop = 240;
  app.all().find((e) => e.attrs['data-batch'] === '.scratch/c').focus();
  api.push(data());
  assert.equal(app.querySelector('.main').scrollTop, 240);
  assert.equal(document.activeElement.attrs['data-batch'], '.scratch/c');
});

test('warnings are shown as the CLI printed them', async () => {
  const d = data();
  d.status.warnings = ['warning: batch/issues/05-ticket.md Checks: ghost.md, which is not a ticket in this batch'];
  const { app } = boot(fakeApi(d));
  await tick();
  assert.ok(text(app).includes(d.status.warnings[0]));
});

// ---- text is text ----

test('ticket names, notes and CLI words that look like markup are drawn as the characters they are', async () => {
  const evil = '<img src=x onerror="alert(1)"><script>alert(2)</script>';
  const d = data();
  d.status.tickets[5].slug = evil;
  d.status.tickets[4].slug = evil;
  d.status.warnings = [evil];
  d.status.last_run = { id: evil, end: 'paused', exit: 10, reason: evil };
  d.status.run_until.text = evil;
  d.all.batches[1].name = evil;
  const { app } = boot(fakeApi(d));
  await tick();
  assert.ok(text(app).includes(evil));
  const tags = new Set(app.all().map((e) => e.tagName));
  for (const bad of ['img', 'script', 'iframe', 'a', 'style']) assert.ok(!tags.has(bad), `no <${bad}> element`);
});

// ---- the states that fill the pane ----

test('Git Bash missing: the sentence, what was looked at, and a button that tries again', async () => {
  const api = fakeApi({ ok: false, error: { kind: 'git-bash-missing', message: 'foreman runs in Git Bash.', tried: ['C:\\a\\bash.exe (FOREMAN_BASH)', 'git.exe on PATH (not found)'] } });
  const { app } = boot(api);
  await tick();
  const t = text(app);
  assert.ok(t.includes('Git Bash was not found.'));
  assert.ok(t.includes('foreman runs in Git Bash.'));
  assert.ok(t.includes('C:\\a\\bash.exe (FOREMAN_BASH)') && t.includes('git.exe on PATH (not found)'));
  assert.ok(app.className.includes('solo'));
  buttonNamed(app, 'Try again').click();
  await tick();
  assert.equal(api.calls.load.length, 2);
});

test('an error from foreman is shown in its own words', async () => {
  const { app } = boot(fakeApi({ ok: false, error: { kind: 'exit', message: 'foreman-next.sh: boom', tried: null } }));
  await tick();
  assert.ok(text(app).includes('foreman reported a problem.'));
  assert.ok(text(app).includes('foreman-next.sh: boom'));
});

test('a repository with no batch says what a batch is; a batch that cannot be read says why, with the rail still there', async () => {
  const { app } = boot(fakeApi(data({ all: { batches: [] }, selected: null, status: null })));
  await tick();
  assert.ok(text(app).includes('No batch here.') && text(app).includes('foreman.conf'));

  const broken = data({ status: null, statusError: 'order.md lists a ticket that does not exist' });
  const b = boot(fakeApi(broken));
  await tick();
  assert.ok(text(b.app).includes('This batch cannot be read.'));
  assert.ok(text(b.app).includes('order.md lists a ticket that does not exist'));
  assert.ok(b.app.all().some((e) => e.attrs['data-batch'] === '.scratch/c'), 'the rail is still there');
});

test('a batch with everything landed says so instead of showing an empty next card', async () => {
  const d = data();
  d.status.next = null;
  d.status.counts = { done: 10, total: 10 };
  const { app } = boot(fakeApi(d));
  await tick();
  assert.ok(text(app).includes('Every ticket has landed.'));
});

// ---- the dry run ----

const preOf = (app, cls) => app.all().find((e) => e.tagName === 'pre' && e.className.split(' ').includes(cls));

async function openDry(api) {
  const b = boot(api);
  await tick();
  buttonNamed(b.app, 'Dry run').click();
  await tick();
  return b;
}

test('Dry run on the overview asks for that batch\'s dry run and shows the screen, marked free', async () => {
  const api = fakeApi(data());
  const { app, document } = await openDry(api);
  assert.deepEqual(api.calls.dryRun, ['.scratch/b']);
  const t = text(app);
  for (const want of ['Dry run', 'free', 'no prompt is sent · no sandbox starts', '2 would run', 'Would run',
    '05 document-human-tickets', '06 doctor-human-warnings', 'then the run stops at 07 try-it-on-a-real-repo, a human ticket',
    'Settings', 'exec', 'local', 'acceptEdits', 'claude-sonnet-5-5', 'cost $25 · time 90m · iterations unlimited',
    '.scratch/b/foreman-runs.jsonl', '.scratch/b/foreman-runs.log',
    'Prompt for 05 · 7 lines', 'nothing was sent; no sandbox was started']) {
    assert.ok(t.includes(want), `the screen shows ${JSON.stringify(want)}`);
  }
  assert.equal(document.title, 'Foreman — dry run · .scratch/b');
  assert.ok(app.all().some((e) => e.className.split(' ').includes('free')), 'the free mark is on the screen');
  assert.ok(buttonNamed(app, 'Start run…').textContent.includes('costs money'));
  assert.equal(buttonNamed(app, 'Start run…').disabled, true, 'starting a run is a later ticket');
  assert.ok(app.all().some((e) => e.attrs['data-batch'] === '.scratch/c'), 'the rail is still there');
});

test('the prompt is one <pre> holding the CLI\'s text exactly, beside a gutter of line numbers that is not part of it', async () => {
  const doc = dryRunSample();
  const { app } = await openDry(fakeApi(data(), { ok: true, doc }));
  const prompt = preOf(app, 'prompt');
  assert.ok(prompt, 'a <pre> for the prompt');
  assert.equal(prompt.textContent, doc.prompt.text, 'not a character different, markup and blank lines included');
  const nums = preOf(app, 'nums');
  assert.equal(nums.textContent, '1\n2\n3\n4\n5\n6\n7');
  assert.equal(nums.attrs['aria-hidden'], 'true', 'the numbers are for the eye; a screen reader reads the prompt');
  assert.equal(prompt.attrs.tabindex, '0', 'the prompt can be scrolled from the keyboard');
  assert.ok(prompt.textContent.includes('<b>line</b>'), 'the markup in the prompt is the characters it is');
  assert.deepEqual(prompt.children.map((c) => c.constructor.name), ['Text'], 'and the <pre> holds one text node, no elements');
  const tags = new Set(app.all().map((e) => e.tagName));
  for (const bad of ['img', 'script', 'iframe', 'a', 'style']) assert.ok(!tags.has(bad), `no <${bad}> element`);
});

test('Back returns to the overview, and Run again asks for the dry run again', async () => {
  const api = fakeApi(data());
  const { app } = await openDry(api);
  buttonNamed(app, 'Run again').click();
  await tick();
  assert.equal(api.calls.dryRun.length, 2);
  assert.ok(text(app).includes('Prompt for 05'));
  buttonNamed(app, '← ').click();
  await tick();
  assert.ok(!text(app).includes('Prompt for 05'));
  assert.ok(text(app).includes('landed · 6 to go'), 'the overview is back');
  assert.equal(api.calls.load.length, 1, 'going back reads nothing again');
});

test('a click on another batch in the rail leaves the dry run for that batch\'s overview', async () => {
  const api = fakeApi((b) => (b === '.scratch/c' ? data({ selected: '.scratch/c' }) : data()));
  const { app } = await openDry(api);
  app.all().find((e) => e.attrs['data-batch'] === '.scratch/c').click();
  await tick();
  assert.ok(!text(app).includes('Prompt for 05'));
  assert.ok(text(app).includes('Batch'));
});

test('a file changing on disk redraws the rail and keeps the dry run on screen', async () => {
  const api = fakeApi(data());
  const { app } = await openDry(api);
  const d = data();
  d.all.batches[1].counts = { done: 1, total: 3 };
  api.push(d);
  assert.ok(text(app).includes('Prompt for 05 · 7 lines'), 'still the dry run');
  assert.ok(text(app).includes('c1/3'), 'with the rail brought up to date');
  assert.equal(api.calls.dryRun.length, 1, 'and it did not ask foreman again on its own');
});

test('a push for a different batch than the dry run was of takes the window back to the overview', async () => {
  const api = fakeApi(data());
  const { app } = await openDry(api);
  api.push(data({ selected: '.scratch/c' }));
  assert.ok(!text(app).includes('Prompt for 05'));
});

test('while foreman works the screen says so, and a failure is shown in the CLI\'s own words, with Try again and Back', async () => {
  let release;
  const slow = new Promise((r) => { release = r; });
  const api = fakeApi(data(), () => slow);
  const { app } = await openDry(api);
  assert.ok(text(app).includes('Reading the dry run'));
  release({ ok: false, error: { kind: 'exit', message: 'foreman: the working tree is dirty.', tried: null } });
  await tick();
  assert.ok(text(app).includes('foreman reported a problem.'));
  assert.ok(text(app).includes('foreman: the working tree is dirty.'));
  assert.ok(buttonNamed(app, 'Try again'));
  buttonNamed(app, 'Back').click();
  await tick();
  assert.ok(text(app).includes('landed · 6 to go'));
});

test('a dry run that comes back after the person went elsewhere is thrown away', async () => {
  let release;
  const slow = new Promise((r) => { release = r; });
  const api = fakeApi((b) => (b === '.scratch/c' ? data({ selected: '.scratch/c' }) : data()), () => slow);
  const { app } = await openDry(api);
  app.all().find((e) => e.attrs['data-batch'] === '.scratch/c').click();
  await tick();
  release({ ok: true, doc: dryRunSample() });
  await tick();
  assert.ok(!text(app).includes('Prompt for 05'), 'the answer for the other batch does not take over the window');
});

test('a human ticket next: the sentence instead of a prompt, and no <pre> for one', async () => {
  const doc = dryRunSample();
  doc.prompt = null;
  doc.would_run.tickets = [];
  doc.would_run.remaining = doc.would_run.remaining.slice(2);
  const { app } = await openDry(fakeApi(data(), { ok: true, doc }));
  assert.ok(text(app).includes('07 try-it-on-a-real-repo is a human ticket, and it is next. A run stops there, so no prompt would be sent.'));
  assert.ok(text(app).includes('nothing would run'));
  assert.equal(preOf(app, 'prompt'), undefined);
});

test('warnings on the dry run are shown as the CLI printed them', async () => {
  const doc = dryRunSample();
  doc.warnings = ['batch/issues/05-ticket.md Checks: ghost.md, which is not a ticket in this batch'];
  const { app } = await openDry(fakeApi(data(), { ok: true, doc }));
  assert.ok(text(app).includes(doc.warnings[0]));
});
