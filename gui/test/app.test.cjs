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
const { sample, dryRunSample, reportSample, reportByTicketSample, reportRunSample } = require('./sample.cjs');

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

// What `foreman report --json` would answer for each question the screen can ask.
function reportAnswer(_batch, opts = {}) {
  if (opts.run) return { ok: true, doc: reportRunSample() };
  return { ok: true, doc: opts.byTicket ? reportByTicketSample() : reportSample() };
}

function fakeApi(first, dry = { ok: true, doc: dryRunSample() }, report = reportAnswer) {
  const calls = { load: [], open: [], dryRun: [], report: [] };
  let update = null;
  return {
    calls, push: (d) => update(d),
    load: async (b) => { calls.load.push(b); return typeof first === 'function' ? first(b) : first; },
    dryRun: async (b) => { calls.dryRun.push(b); return typeof dry === 'function' ? dry(b) : dry; },
    report: async (b, opts) => { calls.report.push({ batch: b, opts }); return typeof report === 'function' ? report(b, opts) : report; },
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

// ---- the report ----

// what the page built, as plain data: its objects come from another realm, which deepEqual tells apart
const plain = (v) => JSON.parse(JSON.stringify(v));
const railItem = (app, name) => app.all().find((e) => e.className.split(' ').includes('item') && e.textContent.startsWith(name));

async function openReport(api) {
  const b = boot(api);
  await tick();
  railItem(b.app, 'Report').click();
  await tick();
  return b;
}

const rowNamed = (app, id) => app.all().find((e) => e.attrs['data-run'] === id);

test('the rail has a Report entry, marked free, and a click asks for that batch\'s report, nothing more', async () => {
  const api = fakeApi(data());
  const b = boot(api);
  await tick();
  const entry = railItem(b.app, 'Report');
  assert.ok(entry, 'the rail has a Report entry');
  assert.ok(entry.all().some((e) => e.className.split(' ').includes('free')), 'marked free');
  assert.deepEqual(api.calls.report, [], 'nothing is read until it is asked for');
  entry.click();
  await tick();
  assert.deepEqual(plain(api.calls.report), [{ batch: '.scratch/b', opts: {} }], 'the default view, and no run: iterations come only when a run is opened');
});

test('the report: the bill with its totals and the ledger with a row for each run, newest first, marked free', async () => {
  const { app, document } = await openReport(fakeApi(data()));
  const t = text(app);
  for (const want of ['Report', 'batch', 'free', 'Total, all runs', '$6.95', '3 runs · 7 iterations · 48.2 model-minutes · 1 unreadable line',
    'landed', 'progressed', 'stalled', 'unproductive', 'checkpoint turns', 'limit hits',
    'billed tokens', '167,500', 'cache read', '5,820,000', 'cache write', '432,000', 'turns', '220', 'per iteration', '$0.99',
    '20261023T081014Z-1207', '20261022T140533Z-9020', '20261021T091200Z-4411', '1 landed', 'limit hit', '$4.25', '$2.00']) {
    assert.ok(t.includes(want), `the screen shows ${JSON.stringify(want)}`);
  }
  assert.ok(t.indexOf('20261023T081014Z-1207') < t.indexOf('20261022T140533Z-9020') && t.indexOf('20261022T140533Z-9020') < t.indexOf('20261021T091200Z-4411'), 'newest first');
  assert.equal(document.title, 'Foreman — report · .scratch/b');
  assert.ok(app.all().some((e) => e.attrs.title === '$6.9500'), 'the total carries the figure the plain report prints');
  assert.ok(app.all().some((e) => e.className.split(' ').includes('bill')), 'the bill');
});

test('on the report the rail marks Report, not a batch; a click on a batch leaves it for that batch\'s overview', async () => {
  const api = fakeApi(data());
  const { app } = await openReport(api);
  assert.ok(railItem(app, 'Report').className.split(' ').includes('on'));
  assert.equal(railItem(app, 'Report').attrs['aria-current'], 'page');
  assert.ok(app.all().filter((e) => e.attrs['data-batch']).every((e) => !e.className.split(' ').includes('on')));
  app.all().find((e) => e.attrs['data-batch'] === '.scratch/c').click();
  await tick();
  assert.deepEqual(api.calls.load, [null, '.scratch/c']);
  assert.ok(!text(app).includes('Total, all runs'), 'the report is gone');
});

test('a run is not opened until it is asked for; opening it fetches --run <id> once and shows each iteration with the CLI\'s word', async () => {
  const api = fakeApi(data());
  const { app } = await openReport(api);
  assert.equal(api.calls.report.length, 1, 'only the report itself so far');
  assert.ok(!text(app).includes('3 · 04 fourth'), 'no iterations on show');
  const row = rowNamed(app, '20261022T140533Z-9020');
  assert.equal(row.attrs['aria-expanded'], 'false');
  row.click();
  await tick();
  assert.deepEqual(plain(api.calls.report[1]), { batch: '.scratch/b', opts: { run: '20261022T140533Z-9020' } });
  const t = text(app);
  for (const want of ['1 · 03 third · progressed', '2 · 03 third · landed', '3 · 04 fourth · unproductive (error, limit)', '3 · 04 fourth · checkpoint', '$0.50', '$0.25']) {
    assert.ok(t.includes(want), `shows ${JSON.stringify(want)}`);
  }
  assert.equal(rowNamed(app, '20261022T140533Z-9020').attrs['aria-expanded'], 'true');
});

test('closing a run hides its iterations, and opening it again does not ask again', async () => {
  const api = fakeApi(data());
  const { app } = await openReport(api);
  rowNamed(app, '20261022T140533Z-9020').click();
  await tick();
  rowNamed(app, '20261022T140533Z-9020').click();
  await tick();
  assert.ok(!text(app).includes('3 · 04 fourth'), 'closed');
  rowNamed(app, '20261022T140533Z-9020').click();
  await tick();
  assert.ok(text(app).includes('3 · 04 fourth'), 'open again');
  assert.equal(api.calls.report.filter((c) => c.opts.run).length, 1, 'asked once');
});

test('while a run\'s iterations are being read the row says so, and a failure is said under that row, with the others untouched', async () => {
  let release;
  const slow = (b, o) => (o.run ? new Promise((r) => { release = () => r({ ok: false, error: { kind: 'exit', message: 'foreman: no such run' } }); }) : reportAnswer(b, o));
  const api = fakeApi(data(), undefined, slow);
  const { app } = await openReport(api);
  rowNamed(app, '20261022T140533Z-9020').click();
  await tick();
  assert.ok(text(app).includes('Reading the iterations…'));
  release();
  await tick();
  assert.ok(text(app).includes('foreman: no such run'), 'the CLI\'s own words');
  assert.ok(text(app).includes('$6.95'), 'the bill is still there');
  // asking again is a second try, not a stuck row
  rowNamed(app, '20261022T140533Z-9020').click();
  await tick();
  rowNamed(app, '20261022T140533Z-9020').click();
  await tick();
  assert.equal(api.calls.report.filter((c) => c.opts.run).length, 2, 'a failed read is read again when asked again');
});

test('By ticket asks for --by-ticket and shows a row for each ticket; going back to By run does not ask again', async () => {
  const api = fakeApi(data());
  const { app } = await openReport(api);
  buttonNamed(app, 'By ticket').click();
  await tick();
  assert.deepEqual(plain(api.calls.report[1]), { batch: '.scratch/b', opts: { byTicket: true } });
  const t = text(app);
  for (const want of ['01 first', '03 third', '04 fourth', '05 fifth']) assert.ok(t.includes(want), want);
  assert.ok(!t.includes('20261022T140533Z-9020'), 'the runs are not listed in this view');
  assert.equal(buttonNamed(app, 'By ticket').attrs['aria-pressed'], 'true');
  assert.equal(buttonNamed(app, 'By run').attrs['aria-pressed'], 'false');
  assert.equal(app.all().filter((e) => e.attrs['data-run']).length, 0, 'a ticket row has nothing to open');
  buttonNamed(app, 'By run').click();
  await tick();
  assert.equal(api.calls.report.length, 2, 'the first answer is kept');
  assert.ok(text(app).includes('20261022T140533Z-9020'));
});

test('the bill is the same in both views: the totals come from the CLI, not from the rows', async () => {
  const api = fakeApi(data());
  const { app } = await openReport(api);
  buttonNamed(app, 'By ticket').click();
  await tick();
  const t = text(app);
  assert.ok(t.includes('$6.95') && t.includes('167,500'));
});

test('Read again asks for the report again and forgets which runs were open', async () => {
  const api = fakeApi(data());
  const { app } = await openReport(api);
  rowNamed(app, '20261022T140533Z-9020').click();
  await tick();
  buttonNamed(app, 'Read again').click();
  await tick();
  assert.equal(api.calls.report.filter((c) => !c.opts.run).length, 2);
  assert.ok(!text(app).includes('3 · 04 fourth'), 'the run is closed again');
});

test('Back returns to the overview; the report and its rows are gone', async () => {
  const api = fakeApi(data());
  const { app } = await openReport(api);
  buttonNamed(app, '← b').click();
  await tick();
  assert.ok(text(app).includes('document-human-tickets'), 'the overview');
  assert.ok(!text(app).includes('Total, all runs'));
});

test('while foreman works the screen says so; a failure is shown in the CLI\'s own words, with Try again and Back', async () => {
  let release;
  const slow = () => new Promise((r) => { release = r; });
  const { app } = await openReport(fakeApi(data(), undefined, slow));
  assert.ok(text(app).includes('Reading the report…'));
  assert.ok(buttonNamed(app, 'Back'));
  release({ ok: false, error: { kind: 'exit', message: 'No run log at batch/foreman-runs.jsonl — nothing has been run for this batch yet.' } });
  await tick();
  assert.ok(text(app).includes('foreman reported a problem.'));
  assert.ok(text(app).includes('nothing has been run for this batch yet.'));
  assert.ok(buttonNamed(app, 'Try again') && buttonNamed(app, 'Back'));
});

test('Try again on a failed report asks again, and a second attempt that works shows the report', async () => {
  let n = 0;
  const flaky = (b, o) => (++n === 1 ? { ok: false, error: { kind: 'exit', message: 'boom' } } : reportAnswer(b, o));
  const api = fakeApi(data(), undefined, flaky);
  const { app } = await openReport(api);
  buttonNamed(app, 'Try again').click();
  await tick();
  assert.equal(api.calls.report.length, 2);
  assert.ok(text(app).includes('Total, all runs'));
});

test('a report that comes back after the person went elsewhere is thrown away', async () => {
  let release;
  const slow = () => new Promise((r) => { release = r; });
  const api = fakeApi(data(), undefined, slow);
  const { app } = await openReport(api);
  buttonNamed(app, 'Back').click();
  await tick();
  release({ ok: true, doc: reportSample() });
  await tick();
  assert.ok(!text(app).includes('Total, all runs'), 'it did not come back onto the overview');
  assert.ok(text(app).includes('document-human-tickets'));
});

test('a file changing on disk redraws the rail and keeps the report on screen, with its open runs', async () => {
  const api = fakeApi(data());
  const { app } = await openReport(api);
  rowNamed(app, '20261022T140533Z-9020').click();
  await tick();
  api.push(data({ all: { batches: [{ path: '.scratch/b', name: 'b', finished: false, counts: { done: 5, total: 10 }, human_remaining: 1, next: 'x', error: null }] } }));
  assert.ok(text(app).includes('Total, all runs'));
  assert.ok(text(app).includes('3 · 04 fourth'));
  assert.ok(text(app).includes('5/10'), 'the rail is fresh');
  assert.equal(api.calls.report.length, 2, 'a push does not read the report again');
});

test('a push for a different batch than the report was of takes the window back to the overview', async () => {
  const api = fakeApi(data());
  const { app } = await openReport(api);
  api.push(data({ selected: '.scratch/c', status: sample() }));
  assert.ok(!text(app).includes('Total, all runs'));
});

test('ticket names, run ids and CLI words that look like markup are drawn as the characters they are', async () => {
  const doc = reportRunSample();
  doc.rows[0].id = '<img src=x onerror=alert(1)>';
  doc.run.id = doc.rows[0].id;
  doc.run.iterations[0].ticket = 'batch/issues/01-<b>bold.md';
  doc.run.iterations[0].flags = ['<i>x</i>'];
  const api = fakeApi(data(), undefined, (b, o) => ({ ok: true, doc: o.run ? doc : { ...doc, run: undefined } }));
  const { app } = await openReport(api);
  assert.ok(text(app).includes('<img src=x onerror=alert(1)>'));
  rowNamed(app, '<img src=x onerror=alert(1)>').click();
  await tick();
  assert.ok(text(app).includes('01 <b>bold'));
  assert.ok(text(app).includes('<i>x</i>'));
  assert.equal(app.all().filter((e) => e.tagName === 'img').length, 0, 'no element came of it');
  assert.deepEqual(app.all().filter((e) => e.tagName === 'b').map((e) => e.textContent), ['FOREMAN'], 'the only <b> is the rail\'s own mark');
});

test('a batch with no run record yet is the CLI\'s own sentence, in the report\'s place', async () => {
  const none = () => ({ ok: false, error: { kind: 'exit', message: 'No run log at .scratch/b/foreman-runs.jsonl — nothing has been run for this batch yet.' } });
  const { app } = await openReport(fakeApi(data(), undefined, none));
  assert.ok(text(app).includes('nothing has been run for this batch yet.'));
});

test('the rail\'s Report is disabled, and says why, when there is no batch to report on', async () => {
  const empty = data({ selected: null, status: null, all: { batches: [] } });
  const b = boot(fakeApi(empty));
  await tick();
  assert.equal(railItem(b.app, 'Report').disabled, true);
});
