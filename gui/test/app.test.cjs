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
const { sample, statsSample, dryRunSample, reportSample, reportByTicketSample, reportRunSample, doctorSample } = require('./sample.cjs');

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
    const compound = /^([a-z0-9]*)((?:\.[\w-]+)+)$/.exec(sel);      // pre.src, .bx.on
    if (compound) {
      const have = this.className.split(/\s+/);
      return (compound[1] === '' || compound[1] === this.tagName) && compound[2].slice(1).split('.').every((c) => have.includes(c));
    }
    const attr = /^\[([\w-]+)\]$/.exec(sel);
    if (attr) return attr[1] in this.attrs;
    const eq = /^\[([\w-]+)="([^"]*)"\]$/.exec(sel);
    if (eq) return this.attrs[eq[1]] === eq[2];
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
  const win = { document, foreman: api, listeners: {} };
  win.addEventListener = (type, fn) => { (win.listeners[type] = win.listeners[type] || []).push(fn); };
  win.window = win;
  vm.createContext(win);
  for (const f of ['model.js', 'art.js', 'preview.js', 'app.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', f), 'utf8'), win, { filename: f });
  }
  return { app, document, window: win };
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

function fakeApi(first, dry = { ok: true, doc: dryRunSample() }, report = reportAnswer, tk = {}, dr = {}) {
  const calls = { load: [], open: [], dryRun: [], report: [], ticket: [], save: [], doctor: 0, doctorFix: 0 };
  let update = null;
  return {
    calls, push: (d) => update(d),
    load: async (b) => { calls.load.push(b); return typeof first === 'function' ? first(b) : first; },
    dryRun: async (b) => { calls.dryRun.push(b); return typeof dry === 'function' ? dry(b) : dry; },
    report: async (b, opts) => { calls.report.push({ batch: b, opts }); return typeof report === 'function' ? report(b, opts) : report; },
    open: async (p) => { calls.open.push(p); return null; },
    doctor: async () => { calls.doctor++; const r = dr.doctor === undefined ? { ok: true, doc: doctorSample() } : dr.doctor; return typeof r === 'function' ? r(calls.doctor) : r; },
    doctorFix: async () => { calls.doctorFix++; const r = dr.fix === undefined ? { ok: true, doc: { ...doctorSample(), fix: { appended: doctorSample().plan.map((p) => ({ file: p.file, text: p.text })), remaining: 0 } } } : dr.fix; return typeof r === 'function' ? r(calls.doctorFix) : r; },
    ticket: async (b, n) => { calls.ticket.push([b, n]); return tk.ticket ? tk.ticket(b, n) : { ok: false, error: { kind: 'exit', message: 'no ticket handler' } }; },
    saveHandoff: async (b, n, text, base) => { calls.save.push({ batch: b, name: n, text, base }); return tk.save ? tk.save(b, n, text, base) : { ok: true, saved: true, text }; },
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

// ---- the ticket page (design 02: b, b1, b2, b3) ----

const HUMAN = '07-try-it-on-a-real-repo';
const HANDOFF = '.scratch/b/handoff/07-try-it-on-a-real-repo.md';
const TICKET_TEXT = '# 07: try it on a real repo\n\n**Status:** ready-for-human\n\nRun a 3-ticket batch with `foreman run`.\n\n- [ ] The run stops at the human ticket\n- [x] A rerun stops again, free\n';

function ticketDoc(name, over = {}) {
  const human = name === HUMAN;
  return {
    name, file: `.scratch/b/issues/${name}.md`, text: TICKET_TEXT,
    progress: '## 07 — human ticket\n- waits on a person\n\n## 08 — other\n- not this one\n',
    handoff: human ? { path: HANDOFF, text: '## What I did\nran it\n', error: null } : null,
    ...over,
  };
}
// The api a ticket page needs: `docs` is what main would read, by ticket name; `disk` is that, mutable.
function ticketApi(over = {}) {
  const st = { docs: {}, saves: [], ...over };
  const tk = {
    ticket: (b, n) => (st.docs[n] ? { ok: true, doc: structuredClone(st.docs[n]) } : { ok: true, doc: ticketDoc(n) }),
    save: over.save,
  };
  return { st, tk };
}
const rowFor = (app, name) => app.all().find((e) => e.tagName === 'button' && e.attrs['data-ticket'] === name);
const editorOf = (app) => app.all().find((e) => e.tagName === 'textarea');
const tags = (app) => new Set(app.all().map((e) => e.tagName));
const sw = (app, label) => buttons(app).find((b) => b.textContent === label && b.attrs['aria-pressed'] !== undefined);

async function openPage(name, { api = null, d = data(), tk = ticketApi().tk } = {}) {
  const fake = api || fakeApi(d, undefined, undefined, tk);
  const { app, document, window } = boot(fake);
  await tick();
  rowFor(app, name).click();
  await tick();
  return { app, document, window, api: fake };
}

test('a click on a ticket in the order opens its page, which reads that ticket once', async () => {
  const { app, api, document } = await openPage(HUMAN);
  assert.deepEqual(api.calls.ticket, [['.scratch/b', HUMAN]]);
  assert.ok(text(app).includes('07 try-it-on-a-real-repo'));
  assert.equal(document.title, 'Foreman — 07 try-it-on-a-real-repo');
  assert.ok(buttonNamed(app, '← b'), 'a way back, named for the batch');
  assert.ok(buttonNamed(app, 'Open ticket in editor'));
});

test('the facts strip: status, blocked by, checked by, handoff — as text', async () => {
  const { app } = await openPage(HUMAN);
  const strip = app.querySelector('.facts').textContent;
  for (const want of ['Status', 'ready-for-human', 'Blocked by', 'nothing', 'Checked by', '07a followup-try-the-followup-skill', 'Handoff', HANDOFF]) {
    assert.ok(strip.includes(want), want);
  }
});

test('Preview is the default: a heading, bold, code, bullets and boxes, built as elements', async () => {
  const { app } = await openPage(HUMAN);
  const md = app.querySelector('.md');
  assert.ok(md, 'the preview');
  assert.ok(!app.querySelector('.src'), 'not the Markdown view');
  const kinds = md.all().map((e) => e.tagName);
  for (const k of ['h1', 'b', 'code', 'ul', 'li', 'p']) assert.ok(kinds.includes(k), k);
  assert.equal(md.querySelector('.bx.on').textContent, '✓');
  assert.equal(md.querySelectorAll('.bx').length, 2);
  assert.equal(sw(app, 'Preview').attrs['aria-pressed'], 'true');
  assert.equal(sw(app, 'Markdown').attrs['aria-pressed'], 'false');
  assert.ok(md.textContent.includes('try it on a real repo'));
  assert.ok(!md.textContent.includes('# 07'), 'the # is the heading, not text');
});

test('Markdown shows the file\'s own text in the mono font; the notes and the editor are the same in both', async () => {
  const { app } = await openPage(HUMAN);
  const editor = editorOf(app);
  const notesBefore = app.querySelector('.notes').textContent;
  sw(app, 'Markdown').click();
  const src = app.querySelector('pre.src');
  assert.ok(src, 'the Markdown view');
  assert.equal(src.textContent, TICKET_TEXT, 'the text exactly');
  assert.ok(!app.querySelector('.md'));
  assert.equal(sw(app, 'Markdown').attrs['aria-pressed'], 'true');
  assert.equal(app.querySelector('.notes').textContent, notesBefore);
  assert.equal(editorOf(app), editor, 'the very same editor, with whatever is in it');
  sw(app, 'Preview').click();
  assert.ok(app.querySelector('.md'));
});

test('the notes are this ticket\'s own, from progress.txt, as text', async () => {
  const { app } = await openPage(HUMAN);
  const notes = app.querySelector('.notes').textContent;
  assert.ok(notes.includes('07 — human ticket'));
  assert.ok(notes.includes('- waits on a person'));
  assert.ok(!notes.includes('not this one'));
});

test('a ticket nothing in progress.txt mentions says so', async () => {
  const { app } = await openPage('06-doctor-human-warnings');
  assert.ok(app.querySelector('.notes').textContent.includes('nothing mentions 06 yet'));
});

test('a <script>, an <img onerror> and a javascript: link in the ticket, the notes and the handoff are characters, in both views', async () => {
  const evil = '<script>alert(1)</script><img src=x onerror="alert(2)">[x](javascript:alert(3))';
  const doc = ticketDoc(HUMAN, {
    text: `# ${evil}\n\n${evil}\n\n- ${evil}\n- [x] ${evil}\n\n\`${evil}\` **${evil}**\n`,
    progress: `## 07 — ${evil}\n- ${evil}\n`,
    handoff: { path: HANDOFF, text: evil, error: null },
  });
  const { tk } = ticketApi({ docs: { [HUMAN]: doc } });
  const { app } = await openPage(HUMAN, { tk });
  const check = (where) => {
    assert.ok(text(app).includes(evil), where + ': the characters are there');
    for (const bad of ['img', 'script', 'iframe', 'a', 'style', 'link', 'object']) assert.ok(!tags(app).has(bad), `${where}: no <${bad}>`);
    for (const e of app.all()) assert.ok(!Object.keys(e.attrs).some((k) => /^on/i.test(k) || k === 'href' || k === 'src'), where + ': no handler, href or src');
  };
  check('preview');
  assert.equal(editorOf(app).value, evil, 'the editor holds the handoff text as a value');
  sw(app, 'Markdown').click();
  check('markdown');
});

test('a human ticket: the handoff in an editor beside the ticket, with the reminder above it', async () => {
  const { app } = await openPage(HUMAN);
  const ed = editorOf(app);
  assert.ok(ed, 'an editor');
  assert.equal(ed.value, '## What I did\nran it\n');
  const side = app.querySelector('.handoff');
  const kids = side.all();
  const note = kids.find((e) => e.className.includes('lock'));
  assert.equal(note.textContent, 'Record where a secret is stored (a password manager entry, an env var name), never its value.');
  assert.ok(kids.indexOf(note) < kids.indexOf(ed), 'the reminder is above the editor');
  assert.equal(ed.attrs.title, HANDOFF, 'the editor says which file it is');
  assert.ok(app.querySelector('.ticketcols').all().includes(ed), 'in the same row as the ticket');
  assert.ok(!app.querySelector('.stats'));
});

test('Save is off until something is typed; then it sends the text and the text the editor was opened on, and says it saved', async () => {
  const { app, api } = await openPage(HUMAN);
  assert.equal(buttonNamed(app, 'Save handoff').disabled, true, 'nothing to save');
  const ed = editorOf(app);
  ed.value = '## What I did\nran it, twice\n';
  for (const fn of ed.listeners.input || []) fn({ target: ed });
  assert.equal(buttonNamed(app, 'Save handoff').disabled, false);
  assert.ok(app.querySelector('.handoff').textContent.includes('unsaved'));
  buttonNamed(app, 'Save handoff').click();
  await tick();
  assert.deepEqual(api.calls.save, [{ batch: '.scratch/b', name: HUMAN, text: '## What I did\nran it, twice\n', base: '## What I did\nran it\n' }]);
  assert.ok(app.querySelector('.handoff').textContent.includes('saved'));
  assert.ok(!app.querySelector('.handoff').textContent.includes('unsaved'));
  assert.equal(buttonNamed(app, 'Save handoff').disabled, true, 'saved: nothing more to save');
  assert.equal(editorOf(app), ed);
  assert.equal(ed.value, '## What I did\nran it, twice\n');
});

test('after a save the file\'s own line endings are what the next save is based on, and the editor is not unsaved', async () => {
  const { tk } = ticketApi({ save: (b, n, text) => ({ ok: true, saved: true, text: text.replace(/\n/g, '\r\n') }) });
  const { app, api } = await openPage(HUMAN, { tk });
  const ed = editorOf(app);
  ed.value = 'a\nb\n';
  for (const fn of ed.listeners.input) fn({});
  buttonNamed(app, 'Save handoff').click();
  await tick();
  ed.value = 'a\nb\nc\n';
  for (const fn of ed.listeners.input) fn({});
  buttonNamed(app, 'Save handoff').click();
  await tick();
  assert.equal(api.calls.save[1].base, 'a\r\nb\r\n');
});

test('a refused save is shown as text, and what the person typed is still there', async () => {
  const { tk } = ticketApi({ save: () => ({ ok: false, error: { kind: 'bad-handoff', message: 'refusing "../x.md": reaches out of the repository with ..' } }) });
  const { app } = await openPage(HUMAN, { tk });
  const ed = editorOf(app);
  ed.value = 'mine';
  for (const fn of ed.listeners.input) fn({});
  buttonNamed(app, 'Save handoff').click();
  await tick();
  assert.ok(text(app).includes('refusing "../x.md": reaches out of the repository with ..'));
  assert.equal(ed.value, 'mine');
  assert.equal(buttonNamed(app, 'Save handoff').disabled, false, 'it can be tried again');
});

test('a handoff path the check refused: the refusal in place of the editor, as text', async () => {
  const doc = ticketDoc(HUMAN, { handoff: { path: '../x.md', text: null, error: 'refusing "../x.md": reaches out of the repository with ..' } });
  const { tk } = ticketApi({ docs: { [HUMAN]: doc } });
  const { app } = await openPage(HUMAN, { tk });
  assert.ok(!editorOf(app));
  assert.ok(text(app).includes('reaches out of the repository'));
  assert.ok(!buttonNamed(app, 'Save handoff') || buttonNamed(app, 'Save handoff').disabled);
});

test('a handoff file that is not there yet opens an empty editor, and says it is new', async () => {
  const doc = ticketDoc(HUMAN, { handoff: { path: HANDOFF, text: null, error: null } });
  const { tk } = ticketApi({ docs: { [HUMAN]: doc } });
  const { app, api } = await openPage(HUMAN, { tk });
  assert.equal(editorOf(app).value, '');
  assert.ok(app.querySelector('.handoff').textContent.includes('not written yet'));
  buttonNamed(app, 'Save handoff').click();
  await tick();
  assert.equal(api.calls.save[0].base, null);
});

test('the file changed on disk while the editor is clean: the editor shows the new text', async () => {
  const st = ticketApi();
  const { app, api } = await openPage(HUMAN, { tk: st.tk });
  const ed = editorOf(app);
  st.st.docs[HUMAN] = ticketDoc(HUMAN, { handoff: { path: HANDOFF, text: 'edited elsewhere\n', error: null }, text: '# 07 changed\n' });
  api.push(data());
  await tick();
  assert.equal(api.calls.ticket.length, 2, 'the page was read again');
  assert.equal(editorOf(app), ed);
  assert.equal(ed.value, 'edited elsewhere\n');
  assert.ok(app.querySelector('.md').textContent.includes('07 changed'));
  assert.equal(buttonNamed(app, 'Save handoff').disabled, true);
});

test('the file changed on disk while the editor has unsaved changes: the draft stays, and the page says so', async () => {
  const st = ticketApi();
  const { app, api } = await openPage(HUMAN, { tk: st.tk });
  const ed = editorOf(app);
  ed.value = 'my draft';
  for (const fn of ed.listeners.input) fn({});
  st.st.docs[HUMAN] = ticketDoc(HUMAN, { handoff: { path: HANDOFF, text: 'edited elsewhere\n', error: null } });
  api.push(data());
  await tick();
  assert.equal(ed.value, 'my draft', 'not touched');
  assert.ok(app.querySelector('.handoff').textContent.includes('changed on disk'));
  assert.equal(api.calls.save.length, 0);
});

test('Save of a file that changed asks first; Overwrite saves against what is on disk now', async () => {
  let n = 0;
  const { tk } = ticketApi({ save: (b, name, text, base) => (n++ === 0 ? { ok: true, saved: false, conflict: true, disk: 'theirs\n' } : { ok: true, saved: true, text }) });
  const { app, api } = await openPage(HUMAN, { tk });
  const ed = editorOf(app);
  ed.value = 'mine';
  for (const fn of ed.listeners.input) fn({});
  buttonNamed(app, 'Save handoff').click();
  await tick();
  assert.ok(text(app).includes('changed on disk since you opened it'));
  assert.ok(buttonNamed(app, 'Overwrite') && buttonNamed(app, 'Load from disk') && buttonNamed(app, 'Keep editing'));
  assert.equal(api.calls.save.length, 1);
  assert.equal(ed.value, 'mine');
  buttonNamed(app, 'Overwrite').click();
  await tick();
  assert.deepEqual(api.calls.save[1], { batch: '.scratch/b', name: HUMAN, text: 'mine', base: 'theirs\n' });
  assert.ok(!buttonNamed(app, 'Overwrite'), 'the question is answered');
  assert.ok(app.querySelector('.handoff').textContent.includes('saved'));
});

test('Load from disk takes the file\'s text and drops the draft; Keep editing leaves the draft and the question closes', async () => {
  const { tk } = ticketApi({ save: () => ({ ok: true, saved: false, conflict: true, disk: 'theirs\n' }) });
  const { app, api } = await openPage(HUMAN, { tk });
  const ed = editorOf(app);
  ed.value = 'mine';
  for (const fn of ed.listeners.input) fn({});
  buttonNamed(app, 'Save handoff').click();
  await tick();
  buttonNamed(app, 'Keep editing').click();
  assert.equal(ed.value, 'mine');
  assert.ok(!buttonNamed(app, 'Overwrite'));
  buttonNamed(app, 'Save handoff').click();
  await tick();
  buttonNamed(app, 'Load from disk').click();
  assert.equal(ed.value, 'theirs\n');
  assert.ok(!buttonNamed(app, 'Overwrite'));
  assert.equal(buttonNamed(app, 'Save handoff').disabled, true);
  assert.equal(api.calls.save.length, 2, 'neither wrote anything');
});

test('the editor, its text, its focus and its selection survive a redraw', async () => {
  const { app, document, api } = await openPage(HUMAN);
  const ed = editorOf(app);
  ed.value = 'half-typed';
  ed.selectionStart = 2; ed.selectionEnd = 5; ed.scrollTop = 33;
  ed.focus();
  api.push(data());
  await tick();
  assert.equal(editorOf(app), ed);
  assert.equal(ed.value, 'half-typed');
  assert.equal(document.activeElement, ed);
  assert.equal(ed.selectionStart, 2);
  assert.equal(ed.selectionEnd, 5);
  assert.equal(ed.scrollTop, 33);
});

test('the ticket text keeps its scroll position across a redraw', async () => {
  const { app, api } = await openPage(HUMAN);
  app.querySelector('[data-scroll="ticket"]').scrollTop = 120;
  api.push(data());
  await tick();
  assert.equal(app.querySelector('[data-scroll="ticket"]').scrollTop, 120);
});

test('an agent ticket that has not run: what the loop knows, and no editor', async () => {
  const { app } = await openPage('06-doctor-human-warnings');
  assert.ok(!editorOf(app));
  const side = app.querySelector('.knows').textContent;
  for (const want of ['What the loop knows', 'Iterations', 'none yet', 'In flight', 'Sent back']) assert.ok(side.includes(want), want);
});

test('a ticket that landed and ran: run stats from status --json, and an iteration row for each line', async () => {
  const d = data();
  d.status.tickets[2].stats = statsSample();
  const { app } = await openPage('03-stop-on-waiting-human', { d });
  const stats = app.querySelector('.stats').textContent;
  for (const want of ['Cost', '$4.62', 'Runtime', '28m 30s', 'Model', 'claude-sonnet-5-5', 'Iterations', 'Turns', '112', 'Tokens in / out', '310k / 46k']) assert.ok(stats.includes(want), want);
  const rows = app.querySelectorAll('.iterline');
  assert.equal(rows.length, 4);
  assert.ok(rows[1].textContent.includes('stalled'));
  assert.ok(rows[2].textContent.includes('checkpoint turn'));
  assert.ok(rows[3].textContent.includes('landed') && rows[3].textContent.includes('8m 25s · $1.30'));
  assert.ok(!app.querySelector('.knows'));
  assert.ok(!editorOf(app));
});

test('a ticket that landed and never ran says none yet, and a human one that landed shows its handoff, not stats', async () => {
  const none = await openPage('02-handoff-file-path');
  assert.ok(none.app.querySelector('.nostats').textContent.includes('none yet'));
  const d = data();
  d.status.tickets[6].done = true; d.status.tickets[6].state = 'done'; d.status.tickets[6].status = 'done';
  d.status.tickets[6].stats = statsSample();
  const human = await openPage(HUMAN, { d });
  assert.ok(editorOf(human.app));
  assert.ok(!human.app.querySelector('.stats'));
});

test('Open ticket in editor opens the ticket file; nothing on the page changes a status line', async () => {
  const { app, api } = await openPage(HUMAN);
  buttonNamed(app, 'Open ticket in editor').click();
  assert.deepEqual(api.calls.open, ['.scratch/b/issues/07-try-it-on-a-real-repo.md']);
  for (const b of buttons(app)) {
    assert.ok(!/mark (it )?(as )?done|implemented|flip|set status/i.test(b.textContent), `no control: ${b.textContent}`);
  }
  assert.ok(text(app).includes('set the ticket\'s status line to implemented in your editor'), 'it says how, in words');
});

test('Back returns to the overview, and the order\'s rows are clickable again', async () => {
  const { app } = await openPage(HUMAN);
  buttonNamed(app, '← b').click();
  assert.ok(app.querySelector('.tlist'));
  assert.ok(!app.querySelector('.ticketcols'));
});

test('Fill in handoff on the overview opens the human ticket\'s page', async () => {
  const api = fakeApi(data(), undefined, undefined, ticketApi().tk);
  const { app } = boot(api);
  await tick();
  buttonNamed(app, 'Fill in handoff').click();
  await tick();
  assert.deepEqual(api.calls.ticket, [['.scratch/b', HUMAN]]);
  assert.ok(editorOf(app));
});

test('leaving with unsaved changes asks first: Keep editing stays, Discard goes', async () => {
  const { app } = await openPage(HUMAN);
  const ed = editorOf(app);
  ed.value = 'draft';
  for (const fn of ed.listeners.input) fn({});
  buttonNamed(app, '← b').click();
  assert.ok(app.querySelector('.ticketcols'), 'still on the page');
  assert.ok(text(app).includes('unsaved changes'));
  buttonNamed(app, 'Keep editing').click();
  assert.equal(editorOf(app).value, 'draft');
  buttonNamed(app, '← b').click();
  buttonNamed(app, 'Discard').click();
  assert.ok(app.querySelector('.tlist'));
});

test('another batch in the rail, with unsaved changes, asks the same; a clean page just goes', async () => {
  const api = fakeApi((b) => data({ selected: b || '.scratch/b' }), undefined, undefined, ticketApi().tk);
  const { app } = boot(api);
  await tick();
  rowFor(app, HUMAN).click();
  await tick();
  const ed = editorOf(app);
  ed.value = 'draft';
  for (const fn of ed.listeners.input) fn({});
  app.all().find((e) => e.attrs['data-batch'] === '.scratch/c').click();
  await tick();
  assert.ok(app.querySelector('.ticketcols'), 'still there');
  assert.deepEqual(api.calls.load, [null]);
  buttonNamed(app, 'Discard').click();
  await tick();
  assert.deepEqual(api.calls.load, [null, '.scratch/c']);
  assert.ok(!app.querySelector('.ticketcols'));
});

test('while the ticket is being read the page says so; a failure is in foreman\'s words, with Try again and Back', async () => {
  let release;
  const gate = new Promise((r) => { release = r; });
  let fail = true;
  const { tk } = ticketApi({ });
  const wrapped = { ticket: async (b, n) => { await gate; return fail ? { ok: false, error: { kind: 'read', message: 'could not read x.md: gone' } } : tk.ticket(b, n); } };
  const api = fakeApi(data(), undefined, undefined, wrapped);
  const { app } = boot(api);
  await tick();
  rowFor(app, HUMAN).click();
  assert.ok(text(app).includes('Reading the ticket…'));
  release();
  await tick();
  assert.ok(text(app).includes('could not read x.md: gone'));
  fail = false;
  buttonNamed(app, 'Try again').click();
  await tick();
  assert.ok(editorOf(app));
  assert.equal(api.calls.ticket.length, 2);
});

test('a read that comes back after the person went back is thrown away', async () => {
  let release;
  const gate = new Promise((r) => { release = r; });
  const { tk } = ticketApi();
  const api = fakeApi(data(), undefined, undefined, { ticket: async (b, n) => { await gate; return tk.ticket(b, n); } });
  const { app } = boot(api);
  await tick();
  rowFor(app, HUMAN).click();
  buttonNamed(app, 'Back').click();
  release();
  await tick();
  assert.ok(app.querySelector('.tlist'), 'still on the overview');
  assert.ok(!editorOf(app));
});

test('a ticket that is not in the batch any more says so, with the way back', async () => {
  const { app, api } = await openPage(HUMAN);
  const d = data();
  d.status.tickets = d.status.tickets.filter((t) => t.name !== HUMAN);
  api.push(d);
  await tick();
  assert.ok(text(app).includes('is not in this batch any more'));
  assert.ok(buttonNamed(app, 'Back'));
});

test('a push for a different batch takes the window back to the overview', async () => {
  const { app, api } = await openPage(HUMAN);
  api.push(data({ selected: '.scratch/c', status: { ...sample(), batch: { path: '.scratch/c', name: 'c' } } }));
  await tick();
  assert.ok(app.querySelector('.tlist') || text(app).length > 0);
  assert.ok(!app.querySelector('.ticketcols'));
});

test('on the ticket page the rail marks no tool; Report from there opens the report', async () => {
  const { app, api } = await openPage('06-doctor-human-warnings');
  const report = app.all().find((e) => e.attrs['data-tool'] === 'report');
  assert.equal(report.attrs['aria-current'], 'false');
  report.click();
  await tick();
  assert.equal(api.calls.report.length, 1);
  assert.ok(!app.querySelector('.ticketcols'));
});

test('Ctrl+S in the editor saves, when there is something to save; other keys do nothing', async () => {
  const { app, api } = await openPage(HUMAN);
  const ed = editorOf(app);
  const press = (e) => { let stopped = false; for (const fn of ed.listeners.keydown || []) fn({ preventDefault() { stopped = true; }, ...e }); return stopped; };
  assert.equal(press({ ctrlKey: true, key: 's' }), false, 'nothing to save: the key is left alone');
  ed.value = 'changed';
  for (const fn of ed.listeners.input) fn({});
  assert.equal(press({ key: 's' }), false);
  assert.equal(press({ ctrlKey: true, key: 'x' }), false);
  assert.equal(api.calls.save.length, 0);
  assert.equal(press({ ctrlKey: true, key: 's' }), true);
  await tick();
  assert.equal(api.calls.save.length, 1);
  assert.equal(api.calls.save[0].text, 'changed');
});

test('coming back to the window re-reads the ticket page, for a handoff the watcher does not see; elsewhere it reads nothing', async () => {
  const st = ticketApi();
  const { app, api, window } = await openPage(HUMAN, { tk: st.tk });
  assert.equal(api.calls.ticket.length, 1);
  st.st.docs[HUMAN] = ticketDoc(HUMAN, { handoff: { path: HANDOFF, text: 'from elsewhere\n', error: null } });
  for (const fn of window.listeners.focus) fn({});
  await tick();
  assert.equal(api.calls.ticket.length, 2);
  assert.equal(editorOf(app).value, 'from elsewhere\n');
  buttonNamed(app, '← b').click();
  for (const fn of window.listeners.focus) fn({});
  await tick();
  assert.equal(api.calls.ticket.length, 2, 'on the overview there is nothing to re-read');
});


// ---- the doctor ----

async function openDoctor(api) {
  const b = boot(api);
  await tick();
  railItem(b.app, 'Doctor').click();
  await tick();
  return b;
}
const trackOf = (app) => app.querySelector('.track');
const runnerOf = (app) => app.querySelector('.runner');
const classes = (e) => e.className.split(/\s+/);

test('the rail has a Doctor entry, marked free, above Report; nothing is read until it is clicked, and then once', async () => {
  const api = fakeApi(data());
  const b = boot(api);
  await tick();
  const entry = railItem(b.app, 'Doctor');
  assert.ok(entry, 'the rail has a Doctor entry');
  assert.ok(entry.all().some((e) => classes(e).includes('free')), 'marked free');
  const tools = b.app.all().filter((e) => e.attrs['data-tool']).map((e) => e.attrs['data-tool']);
  assert.deepEqual(tools, ['doctor', 'report']);
  assert.equal(api.calls.doctor, 0);
  entry.click();
  await tick();
  assert.equal(api.calls.doctor, 1);
  assert.equal(api.calls.doctorFix, 0, 'reading the sheet writes nothing');
});

test('while foreman inspects: the track with the inspector on it, a sentence that says nothing is sent or written, and no sheet yet', async () => {
  let release;
  const api = fakeApi(data(), undefined, undefined, undefined, { doctor: () => new Promise((r) => { release = r; }) });
  const { app, document } = await openDoctor(api);
  assert.ok(trackOf(app), 'the track is there');
  assert.ok(!classes(trackOf(app)).includes('inspected'), 'and it is the one that is running');
  assert.ok(runnerOf(app), 'with the inspector on it');
  assert.equal(trackOf(app).attrs['aria-label'], 'inspecting');
  assert.ok(text(app).includes('inspecting…'));
  assert.ok(text(app).includes('Nothing is sent and nothing is written'));
  assert.ok(!text(app).includes('Machine'), 'no sheet');
  assert.equal(document.title, 'Foreman — doctor');
  assert.equal(buttonNamed(app, 'Run again').disabled, true, 'one inspection at a time');
  release({ ok: true, doc: doctorSample() });
  await tick();
  assert.ok(text(app).includes('Machine'));
});

test('the sheet: the sections in order, every row, its fix, the stamp, the next command and the title', async () => {
  const { app } = await openDoctor(fakeApi(data()));
  const t = text(app);
  assert.deepEqual(app.all().filter((e) => e.attrs['data-section']).map((e) => e.attrs['data-section']), ['machine', 'repository', 'skill', 'batches'], 'the terminal\'s order');
  assert.deepEqual(app.all().filter((e) => e.attrs['data-section']).map((e) => e.firstChild.textContent), ['Machine', 'Repository', 'Skill', 'Batches']);
  for (const want of ['git', 'bash 5.2.26 (4+ required)', 'foreman-runs.log not ignored', 'run state would show up as changes',
    'foreman doctor --fix appends it to .gitignore', 'run: bash C:/tools/foreman/install.sh', 'gui', '3 of 14 done',
    'NOT PASSED', '1 to fix', 'foreman doctor --fix', 'C:/Projects/app · foreman d0d6874 · 2026-10-21', 'Site inspection']) {
    assert.ok(t.includes(want), `the sheet shows ${JSON.stringify(want)}`);
  }
  const stamp = app.querySelector('.stamp');
  assert.ok(stamp && stamp.textContent.includes('NOT PASSED') && stamp.textContent.includes('1 to fix'));
  assert.ok(classes(stamp).includes('err'), 'a failing sheet is stamped in the error colour');
  const marks = app.all().filter((e) => classes(e).includes('mark')).map((e) => e.textContent);
  assert.ok(marks.includes('■') && marks.includes('!'));
  assert.ok(app.all().some((e) => classes(e).includes('mono') && e.textContent === 'fix foreman doctor --fix'), 'the next command has its label');
});

test('a passing sheet is stamped PASSED in the ok colour and offers no fix', async () => {
  const { app } = await openDoctor(fakeApi(data(), undefined, undefined, undefined, { doctor: { ok: true, doc: doctorSample('ready') } }));
  const stamp = app.querySelector('.stamp');
  assert.ok(stamp.textContent.includes('PASSED') && stamp.textContent.includes('ready to run') && !stamp.textContent.includes('NOT'));
  assert.ok(classes(stamp).includes('ok'));
  assert.ok(text(app).includes('foreman run .scratch/gui'));
  assert.equal(buttonNamed(app, 'Fix what it can'), undefined);
});

test('a blocker --fix cannot write is a ✗ row with what to do, and there is no Fix button for it', async () => {
  const { app } = await openDoctor(fakeApi(data(), undefined, undefined, undefined, { doctor: { ok: true, doc: doctorSample('blocked') } }));
  assert.ok(text(app).includes('1 blocker'));
  assert.ok(text(app).includes('Add to other/foreman.conf: FOREMAN_CLAUDE_ARGS'));
  assert.ok(app.all().some((e) => classes(e).includes('mark') && e.textContent === '✗'));
  assert.equal(buttonNamed(app, 'Fix what it can'), undefined);
});

test('once the sheet is filled in the inspector has stopped: the track is marked inspected and says so', async () => {
  const { app } = await openDoctor(fakeApi(data()));
  assert.ok(classes(trackOf(app)).includes('inspected'));
  assert.equal(trackOf(app).attrs['aria-label'], 'inspected');
  assert.ok(!text(app).includes('inspecting…'));
});

test('the inspector is CSS only: app.js has no timer and the stylesheet plays the run once, still under reduced motion', () => {
  const js = fs.readFileSync(path.join(__dirname, '..', 'app.js'), 'utf8');
  assert.ok(!/setTimeout|setInterval|requestAnimationFrame/.test(js), 'no timer in app.js');
  const css = fs.readFileSync(path.join(__dirname, '..', 'app.css'), 'utf8');
  assert.match(css, /\.runner\s*\{[^}]*animation:\s*run-across[^;}]*forwards/, 'the run across and back is one pass');
  assert.match(css, /@keyframes run-across/); assert.match(css, /@keyframes stride\b/); assert.match(css, /@keyframes drip/);
  const reduced = /@media \(prefers-reduced-motion: reduce\)\s*\{([^@]*?\})\s*\}/.exec(css);
  assert.ok(reduced && /\.runner/.test(reduced[1]) && /animation:\s*none/.test(reduced[1]), 'reduced motion stops him');
  assert.ok(!/@import|url\(http/.test(css), 'no library');
});

test('Run again reads the sheet again and the inspector runs again: a new track, not the old one', async () => {
  const api = fakeApi(data());
  const { app } = await openDoctor(api);
  const first = trackOf(app);
  buttonNamed(app, 'Run again').click();
  assert.ok(trackOf(app) && trackOf(app) !== first, 'the track is built again');
  assert.ok(!classes(trackOf(app)).includes('inspected'), 'and is running');
  await tick();
  assert.equal(api.calls.doctor, 2);
  assert.ok(classes(trackOf(app)).includes('inspected'));
});

test('a file changing while the inspection runs does not redraw it, so the run is not restarted; the sheet comes in once it is read', async () => {
  let release;
  const api = fakeApi(data(), undefined, undefined, undefined, { doctor: () => new Promise((r) => { release = r; }) });
  const { app } = await openDoctor(api);
  const track = trackOf(app);
  api.push(data());
  await tick();
  assert.equal(trackOf(app), track, 'the same track: the run goes on');
  release({ ok: true, doc: doctorSample() });
  await tick();
  assert.ok(text(app).includes('Machine'));
});

test('a push that arrives after the sheet is up redraws it without reading again', async () => {
  const api = fakeApi(data());
  const { app } = await openDoctor(api);
  api.push(data());
  await tick();
  assert.equal(api.calls.doctor, 1);
  assert.ok(text(app).includes('NOT PASSED'));
});

test('Fix what it can opens what it will append, and nothing is written until it is confirmed', async () => {
  const api = fakeApi(data());
  const { app } = await openDoctor(api);
  const fix = buttonNamed(app, 'Fix what it can');
  assert.ok(fix, 'the button is there');
  assert.ok(fix.all().some((e) => classes(e).includes('free')), 'marked free');
  fix.click();
  const t = text(app);
  for (const want of ['.gitignore', '# Foreman: per-batch run state.', '**/foreman-runs.log', 'does not ignore foreman',
    'Appends 5 lines to .gitignore. Nothing else is written.']) assert.ok(t.includes(want), `the plan shows ${JSON.stringify(want)}`);
  assert.equal(api.calls.doctorFix, 0, 'nothing has run');
  const go = buttonNamed(app, 'Append these lines');
  assert.ok(go && go.all().some((e) => classes(e).includes('free')), 'the confirmation is marked free too');
  buttonNamed(app, 'Cancel').click();
  assert.ok(!text(app).includes('Appends 5 lines'), 'cancelled: the plan is closed');
  assert.equal(api.calls.doctorFix, 0);
  assert.equal(api.calls.doctor, 1);
});

test('confirming runs the fix once, reads the sheet again, and says what was appended and where', async () => {
  const fixed = { ok: true, doc: doctorSample('ready') };
  const api = fakeApi(data(), undefined, undefined, undefined, { doctor: (n) => (n === 1 ? { ok: true, doc: doctorSample() } : fixed) });
  const { app } = await openDoctor(api);
  buttonNamed(app, 'Fix what it can').click();
  buttonNamed(app, 'Append these lines').click();
  await tick(); await tick();
  assert.equal(api.calls.doctorFix, 1);
  assert.equal(api.calls.doctor, 2, 'the sheet was read again after the fix');
  const t = text(app);
  assert.ok(t.includes('Appended 5 lines to .gitignore.'));
  assert.ok(t.includes('a run refuses to start on a dirty tree'));
  assert.ok(app.querySelector('.stamp').textContent.includes('PASSED'), 'the sheet shown is the one read after');
  assert.ok(!text(app).includes('Appends 5 lines'), 'the plan is closed');
  assert.equal(buttonNamed(app, 'Fix what it can'), undefined, 'nothing left to fix');
});

test('the confirmation cannot be pressed twice while the fix runs', async () => {
  let release;
  const api = fakeApi(data(), undefined, undefined, undefined, { fix: () => new Promise((r) => { release = r; }) });
  const { app } = await openDoctor(api);
  buttonNamed(app, 'Fix what it can').click();
  const go = buttonNamed(app, 'Append these lines');
  go.click();
  assert.equal(buttonNamed(app, 'Append').disabled || buttonNamed(app, 'Appending').disabled, true);
  go.click();
  assert.equal(api.calls.doctorFix, 1);
  release({ ok: true, doc: { ...doctorSample(), fix: { appended: [], remaining: 0 } } });
  await tick(); await tick();
  assert.equal(api.calls.doctorFix, 1);
});

test('a fix that fails says so in foreman\'s words, leaves the sheet and the plan where they were, and can be tried again', async () => {
  const api = fakeApi(data(), undefined, undefined, undefined, { fix: { ok: false, error: { kind: 'exit', message: 'foreman doctor: could not write .gitignore' } } });
  const { app } = await openDoctor(api);
  buttonNamed(app, 'Fix what it can').click();
  buttonNamed(app, 'Append these lines').click();
  await tick(); await tick();
  assert.ok(text(app).includes('foreman doctor: could not write .gitignore'));
  assert.ok(text(app).includes('NOT PASSED'), 'the sheet is still there');
  assert.ok(buttonNamed(app, 'Append these lines') && !buttonNamed(app, 'Append these lines').disabled, 'and it can be pressed again');
  assert.equal(api.calls.doctor, 1, 'no re-read of a sheet nothing changed under');
});

test('no batch: the Doctor still opens, which is what it is for, and says what to do', async () => {
  const none = data({ selected: null, status: null, all: { batches: [] } });
  const doc = doctorSample('ready');
  doc.sections[3] = { id: 'batches', title: 'Batches', rows: [], info: ['none — no directory here has a foreman.conf.', 'Create one:  foreman init <batch-dir>'] };
  const api = fakeApi(none, undefined, undefined, undefined, { doctor: { ok: true, doc } });
  const b = boot(api);
  await tick();
  assert.ok(text(b.app).includes('No batch here.'));
  const entry = railItem(b.app, 'Doctor');
  assert.equal(entry.disabled, false, 'not greyed out');
  entry.click();
  await tick();
  assert.ok(text(b.app).includes('Create one:  foreman init <batch-dir>'));
  assert.ok(text(b.app).includes('PASSED'));
});

test('on the Doctor the rail marks Doctor, not a batch; a batch in the rail leaves it, and Back does too', async () => {
  const api = fakeApi(data());
  const { app } = await openDoctor(api);
  assert.equal(app.all().find((e) => e.attrs['data-tool'] === 'doctor').attrs['aria-current'], 'page');
  assert.equal(app.all().find((e) => e.attrs['data-tool'] === 'report').attrs['aria-current'], 'false');
  assert.ok(app.all().filter((e) => e.attrs['data-batch']).every((e) => e.attrs['aria-current'] === 'false'));
  buttonNamed(app, 'Back').click();
  await tick();
  assert.ok(!text(app).includes('Site inspection') && text(app).includes('landed · 6 to go'), 'the overview is back');
  railItem(app, 'Doctor').click();
  await tick();
  app.all().find((e) => e.attrs['data-batch'] === '.scratch/c').click();
  await tick();
  assert.ok(!text(app).includes('Site inspection'));
});

test('Doctor from the report, the dry run and the ticket page replaces them, and Report from the Doctor replaces it', async () => {
  const api = fakeApi(data());
  const { app } = await openDoctor(api);
  railItem(app, 'Report').click();
  await tick();
  assert.ok(text(app).includes('Total, all runs') && !text(app).includes('Site inspection'));
  railItem(app, 'Doctor').click();
  await tick();
  assert.ok(text(app).includes('Site inspection') && !text(app).includes('Total, all runs'));
});

test('a failure to read the sheet is in foreman\'s words, with Try again and Back, and no track', async () => {
  const api = fakeApi(data(), undefined, undefined, undefined, { doctor: { ok: false, error: { kind: 'exit', message: 'foreman doctor: not inside a git repository.' } } });
  const { app } = await openDoctor(api);
  assert.ok(text(app).includes('foreman reported a problem.') && text(app).includes('not inside a git repository'));
  assert.ok(buttonNamed(app, 'Try again') && buttonNamed(app, 'Back'));
  assert.ok(!trackOf(app));
  buttonNamed(app, 'Try again').click();
  await tick();
  assert.equal(api.calls.doctor, 2);
});

test('a read that comes back after the person left the Doctor is thrown away', async () => {
  let release;
  const api = fakeApi(data(), undefined, undefined, undefined, { doctor: () => new Promise((r) => { release = r; }) });
  const { app } = await openDoctor(api);
  buttonNamed(app, 'Back').click();
  await tick();
  release({ ok: true, doc: doctorSample() });
  await tick();
  assert.ok(!text(app).includes('Site inspection') && text(app).includes('landed · 6 to go'));
});

test('what the sheet says is text: a label, a fix and a line to append with markup in them are characters', async () => {
  const doc = doctorSample();
  doc.sections[0].rows[0].label = '<img src=x onerror=alert(1)>';
  doc.sections[1].rows[1].fix = '<script>alert(2)</script>';
  doc.plan[0].text = '<b>bold</b>\n';
  const { app } = await openDoctor(fakeApi(data(), undefined, undefined, undefined, { doctor: { ok: true, doc } }));
  assert.ok(text(app).includes('<img src=x onerror=alert(1)>') && text(app).includes('<script>alert(2)</script>'));
  assert.ok(!app.all().some((e) => e.tagName === 'img' || e.tagName === 'script'));
  buttonNamed(app, 'Fix what it can').click();
  assert.ok(text(app).includes('<b>bold</b>') && !app.all().some((e) => e.tagName === 'b' && e.textContent === 'bold'));
});
