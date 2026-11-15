'use strict';
// The main process. It owns every child process and every file read; the page asks for things by
// name (preload.cjs) and is answered with plain data. Nothing here decides anything about the
// batch — what is next, what a run would cost — that all comes from `foreman <command> --json`.
//
// The app keeps nothing: no settings, no cache, no remembered repository or window size. The
// batch the window is on is a variable, gone when it closes, and the files are the truth.
//
//   npm start -- C:\Projects\app        (in gui/)   opens on that repository
//
// With no repository given, the repository holding the current directory.
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const { app, BrowserWindow, ipcMain, shell, session, Menu, nativeTheme, dialog, clipboard } = require('electron');
const { findGitBash } = require('./bash.cjs');
const { createForeman, findRepoRoot, ForemanError } = require('./foreman.cjs');
const { createWatcher } = require('./watch.cjs');
const { createOverview } = require('./overview.cjs');
const { createTicketFiles } = require('./ticket.cjs');
const { createRunner } = require('./runner.cjs');
const { createLive, onlyControlFiles } = require('./live.cjs');
const { checkBatchPath } = require('./foreman.cjs');
const { createConditions } = require('./conditions.cjs');
const { INIT_COMMAND } = require('./states.js');
const { repoFromArgv, refuseNavigation, openWindowHandler, repoPath } = require('./guard.cjs');

const PAGE = path.join(__dirname, 'index.html');

let win = null;
let ctx = null;            // { repoRoot, overview } once Git Bash and the repository are known
let watcher = null;
let fullBounds = null;     // the window's size and place before the compact view; gone when the app closes
let chosenDir = null;      // the folder picked in "not a git repo", for this window's life only; nothing is stored
let lastOverview = null;   // the overview last sent, to send again when a slower read (the doctor) has news


function describe(e) {
  return { kind: e.kind || 'spawn', message: e.message || String(e), tried: e.tried || null, dir: e.dir || null };
}

async function setup() {
  const found = findGitBash();
  if (!found.bash) {
    throw new ForemanError('git-bash-missing',
      'foreman runs in Git Bash, and none was found. Install Git for Windows (https://gitforwindows.org), or set FOREMAN_BASH to its bash.exe.',
      { tried: found.tried });
  }
  const dir = path.resolve(chosenDir || repoFromArgv(process.argv, process.defaultApp) || process.cwd());
  const repoRoot = await findRepoRoot({ bash: found.bash, dir });
  const checkout = path.resolve(__dirname, '..');
  const foreman = createForeman({ bash: found.bash, checkout, repoRoot });
  const overview = createOverview({ foreman, repoRoot });
  // A ticket page reads from what the overview already read, and saves against a fresh answer.
  const tickets = createTicketFiles({ repoRoot, foreman, known: (b) => overview.statusOf(b) });
  const runner = createRunner({ bash: found.bash, checkout, repoRoot });
  const live = createLive({ repoRoot, foreman });
  // The two states that need a second read (a runner missing, a login expired). The doctor is read behind
  // the overview, and the window is sent the overview again when it has news.
  const conditions = createConditions({
    foreman, readConf, env: process.env,
    onChange: async (batch) => {
      const base = lastOverview;
      if (!base || base.selected !== batch || !ctx || ctx.conditions !== conditions) return;
      const shown = await conditions.decorate(base, { fresh: false });
      if (lastOverview === base) push(shown);       // not if a newer overview went out while this was reading
    },
  });
  ctx = { repoRoot, overview, foreman, tickets, runner, live, conditions };
  watcher = createWatcher({
    // A change to anything in a batch — a status line flipped in an editor, the loop landing a
    // ticket — is a reason to read again. A change only to a run's feed, activity or budget is a
    // reason to read the control directory again, and nothing else.
    dirs: async () => (await overview.dirs()).map((p) => repoPath(repoRoot, p)),
    read: async (changes) => {
      const batch = overview.selected;
      const known = batch ? overview.statusOf(batch) : null;
      if (known && known.run && known.run.in_flight && onlyControlFiles(changes)) {
        return { overview: null, run: await ctx.live.read({ batch, run: known.run, next: known.next, record: false }) };
      }
      const data = await overview.refresh();
      if (!data) return null;
      return { overview: await ctx.conditions.decorate(data, { fresh: false }), run: await liveOf(data, true) };
    },
    onResult: (r) => {                                       // null: the person moved on meanwhile
      if (!r) return;
      if (r.overview) push(r.overview);
      pushRun(r.overview ? r.overview.selected : overview.selected, r.run);
    },
    onError: (e) => push({ ok: false, error: describe(e) }),
  });
}

// The live screen's data for the batch an overview answer is of, or null when no run is in flight there.
async function liveOf(data, record) {
  if (!data || !data.ok || !data.status || !data.status.run || !data.status.run.in_flight) { ctx.live.forget(); return null; }
  return ctx.live.read({ batch: data.selected, run: data.status.run, next: data.status.next, record });
}

function push(data) {
  if (data && data.ok) lastOverview = data;
  if (win && !win.isDestroyed()) win.webContents.send('overview:update', data);
}
function pushRun(batch, run) {
  if (win && !win.isDestroyed()) win.webContents.send('run:update', { batch, run });
}

// Only our own page may ask main for anything.
const PAGE_URL = pathToFileURL(PAGE).href.toLowerCase();
function trusted(event) {
  return !!event.senderFrame && String(event.senderFrame.url).toLowerCase() === PAGE_URL;
}

ipcMain.handle('overview:load', async (event, batch) => {
  if (!trusted(event)) return { ok: false, error: describe(new Error('refused')) };
  try {
    if (!ctx) await setup();
    const data = await ctx.overview.load(typeof batch === 'string' ? batch : null);
    await watcher.start();
    const shown = await ctx.conditions.decorate(data, { fresh: true });
    if (shown && shown.ok) lastOverview = shown;
    return shown;
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
});

// "Not a git repo": pick the folder that holds the repo. The window is then opened on it afresh — what it
// was reading is let go, the folder is a variable and nothing more, and the page asks to load again.
// Cancelling the picker changes nothing.
ipcMain.handle('repo:choose', async (event) => {
  if (!trusted(event) || !win || win.isDestroyed()) return { ok: false, error: describe(new Error('refused')) };
  try {
    const picked = await dialog.showOpenDialog(win, { properties: ['openDirectory'], title: 'Choose the folder that holds your repository' });
    if (picked.canceled || !picked.filePaths || picked.filePaths.length === 0) return { ok: true, chosen: false };
    if (watcher) { watcher.stop(); watcher = null; }
    ctx = null;
    lastOverview = null;
    chosenDir = picked.filePaths[0];
    return { ok: true, chosen: true };
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
});

// "No batch": the command the state shows, put on the clipboard. The text is the app's constant, not
// anything the page sends.
ipcMain.handle('clipboard:init', (event) => {
  if (!trusted(event)) return false;
  clipboard.writeText(INIT_COMMAND);
  return true;
});

// A dry run is free: foreman prints what would run and the prompt, and sends nothing. The batch is
// checked as a repo-relative path before it is given to the CLI (foreman.cjs checkBatchPath).
ipcMain.handle('dryrun:load', async (event, batch) => {
  if (!trusted(event)) return { ok: false, error: describe(new Error('refused')) };
  try {
    if (!ctx) await setup();
    return { ok: true, doc: await ctx.foreman.dryRun(batch) };
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
});

// The report is free too: foreman reads the run record and sends nothing. `opts` is the page's
// question — by ticket, or one run's iterations — and is taken only as far as it is understood; the
// batch and the run id are checked before they reach the CLI (foreman.cjs).
ipcMain.handle('report:load', async (event, batch, opts) => {
  if (!trusted(event)) return { ok: false, error: describe(new Error('refused')) };
  try {
    if (!ctx) await setup();
    const o = opts && typeof opts === 'object' ? opts : {};
    return { ok: true, doc: await ctx.foreman.report(batch, { byTicket: o.byTicket === true, run: o.run === undefined ? null : o.run }) };
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
});

// The Doctor screen: `foreman doctor --json`, and `--fix --json` for Fix what it can. Both are free
// (nothing is sent, no sandbox starts); the fix appends only the lines the sheet's plan listed, to
// .gitignore and .gitattributes, and the CLI is what decides them — nothing is passed to it.
ipcMain.handle('doctor:load', async (event) => {
  if (!trusted(event)) return { ok: false, error: describe(new Error('refused')) };
  try {
    if (!ctx) await setup();
    return { ok: true, doc: await ctx.foreman.doctor() };
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
});

ipcMain.handle('doctor:fix', async (event) => {
  if (!trusted(event)) return { ok: false, error: describe(new Error('refused')) };
  try {
    if (!ctx) await setup();
    return { ok: true, doc: await ctx.foreman.doctorFix() };
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
});

// A ticket's page: its text, the batch's progress.txt and, for a human ticket, its handoff file. The
// page names a batch and a ticket; the file and the handoff path are found by main (ticket.cjs).
ipcMain.handle('ticket:load', async (event, batch, name) => {
  if (!trusted(event)) return { ok: false, error: describe(new Error('refused')) };
  try {
    if (!ctx) await setup();
    return { ok: true, doc: await ctx.tickets.load(batch, name) };
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
});

// The one thing the app writes: the handoff file the ticket names, inside the repository. `base` is
// the text the editor was opened on; if the file is not that any more, nothing is written and the
// answer is { ok: true, saved: false, conflict: true, disk } for the person to decide.
ipcMain.handle('ticket:save', async (event, batch, name, text, base) => {
  if (!trusted(event)) return { ok: false, error: describe(new Error('refused')) };
  try {
    if (!ctx) await setup();
    return { ok: true, ...(await ctx.tickets.save(batch, name, text, base === undefined ? null : base)) };
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
});

// ---- starting, watching and steering a run (ticket 10) ----
//
// The confirmation's facts: what a run would do (`dry-run --json`, free), whether the repository ignores
// the control directory, whether a run is already going, the batch's foreman.conf and the caps the
// app's own environment carries (for "where it is set"). The page words them (runplan.js).
function readConf(batch) {
  try { return fs.readFileSync(`${ctx.repoRoot}/${checkBatchPath(batch)}/foreman.conf`, 'utf8'); } catch { return ''; }
}

ipcMain.handle('run:confirm', async (event, batch) => {
  if (!trusted(event)) return { ok: false, error: describe(new Error('refused')) };
  try {
    if (!ctx) await setup();
    checkBatchPath(batch);
    const [dry, ignored] = await Promise.all([ctx.foreman.dryRun(batch), ctx.foreman.controlIgnored(batch)]);
    const known = ctx.overview.statusOf(batch);
    const env = { FOREMAN_MAX_COST_USD: process.env.FOREMAN_MAX_COST_USD, FOREMAN_MAX_MINUTES: process.env.FOREMAN_MAX_MINUTES };
    return { ok: true, doc: { dry, ignored, inFlight: !!(known && known.run && known.run.in_flight), confText: readConf(batch), env } };
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
});

// The one place a run is started. The request is checked again here (runplan.js), the control
// directory and the run in flight are asked afresh, and the process is detached: the window closing
// does not stop it.
ipcMain.handle('run:start', async (event, batch, request) => {
  if (!trusted(event)) return { ok: false, error: describe(new Error('refused')) };
  try {
    if (!ctx) await setup();
    checkBatchPath(batch);
    if (!(await ctx.foreman.controlIgnored(batch))) {
      throw new ForemanError('not-ignored', 'Starting from the app needs `doctor --fix`: the repository does not ignore **/.foreman-run/.');
    }
    const status = await ctx.foreman.status(batch);
    if (status.run && status.run.in_flight) throw new ForemanError('in-flight', 'A run is already in flight in this batch.');
    const started = await ctx.runner.start(batch, request, ({ code, signal }) => {
      if (win && !win.isDestroyed()) win.webContents.send('run:exit', { batch, code, signal, out: ctx.runner.readOut(batch) });
    });
    return { ok: true, ...started };
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
});

ipcMain.handle('run:load', async (event, batch) => {
  if (!trusted(event)) return { ok: false, error: describe(new Error('refused')) };
  try {
    if (!ctx) await setup();
    const known = ctx.overview.statusOf(checkBatchPath(batch));
    const run = known && known.run && known.run.in_flight
      ? await ctx.live.read({ batch, run: known.run, next: known.next, record: true }) : null;
    return { ok: true, run };
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
});

// `+` / `-` / `L`: foreman keys, which writes the control files as the terminal's keys do. What the
// bar then shows is read back from the control directory.
ipcMain.handle('run:keys', async (event, batch, keys) => {
  if (!trusted(event)) return { ok: false, error: describe(new Error('refused')) };
  try {
    if (!ctx) await setup();
    await ctx.foreman.keys(batch, keys);
    const known = ctx.overview.statusOf(batch);
    const run = known && known.run && known.run.in_flight
      ? await ctx.live.read({ batch, run: known.run, next: known.next, record: false }) : null;
    return { ok: true, run };
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
});

ipcMain.handle('run:stop', async (event, batch, now) => {
  if (!trusted(event)) return { ok: false, error: describe(new Error('refused')) };
  try {
    if (!ctx) await setup();
    return { ok: true, said: (await ctx.foreman.stop(batch, { now: now === true })).stdout };
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
});

// The compact view is a small window, and Full view puts the old size and place back. Neither is
// remembered after the app closes.
ipcMain.handle('window:compact', (event, on) => {
  if (!trusted(event) || !win || win.isDestroyed()) return false;
  if (on === true && fullBounds === null) {
    fullBounds = win.getBounds();
    win.setMinimumSize(360, 240);
    win.setSize(440, 300);
  } else if (on !== true && fullBounds !== null) {
    win.setMinimumSize(720, 480);
    win.setBounds(fullBounds);
    fullBounds = null;
  }
  return true;
});

ipcMain.handle('open', async (event, relativePath) => {
  if (!trusted(event) || !ctx) return 'refused';
  try {
    return (await shell.openPath(repoPath(ctx.repoRoot, relativePath))) || null;
  } catch (e) {
    return e.message;
  }
});

function createWindow() {
  win = new BrowserWindow({
    width: 1040, height: 700, minWidth: 720, minHeight: 480, show: false, autoHideMenuBar: true,
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#0d0c0b' : '#f4efe6',
    icon: path.join(__dirname, 'icon.ico'),
    title: 'Foreman',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true, nodeIntegration: false, sandbox: true, webSecurity: true,
      spellcheck: false, webviewTag: false,
    },
  });
  win.webContents.on('will-navigate', refuseNavigation);
  win.webContents.on('will-attach-webview', refuseNavigation);
  win.webContents.setWindowOpenHandler(openWindowHandler);
  win.once('ready-to-show', () => win.show());
  win.on('closed', () => { win = null; });
  win.loadFile(PAGE);
}

app.whenReady().then(() => {
  session.defaultSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  session.defaultSession.setPermissionCheckHandler(() => false);
  Menu.setApplicationMenu(null);
  createWindow();
});

app.on('window-all-closed', () => app.quit());
app.on('before-quit', () => { if (watcher) watcher.stop(); });
