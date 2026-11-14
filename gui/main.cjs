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
const path = require('path');
const { pathToFileURL } = require('url');
const { app, BrowserWindow, ipcMain, shell, session, Menu, nativeTheme } = require('electron');
const { findGitBash } = require('./bash.cjs');
const { createForeman, findRepoRoot, ForemanError } = require('./foreman.cjs');
const { createWatcher } = require('./watch.cjs');
const { createOverview } = require('./overview.cjs');
const { createTicketFiles } = require('./ticket.cjs');
const { repoFromArgv, refuseNavigation, openWindowHandler, repoPath } = require('./guard.cjs');

const PAGE = path.join(__dirname, 'index.html');

let win = null;
let ctx = null;            // { repoRoot, overview } once Git Bash and the repository are known
let watcher = null;

function describe(e) {
  return { kind: e.kind || 'spawn', message: e.message || String(e), tried: e.tried || null };
}

async function setup() {
  const found = findGitBash();
  if (!found.bash) {
    throw new ForemanError('git-bash-missing',
      'foreman runs in Git Bash, and none was found. Install Git for Windows (https://gitforwindows.org), or set FOREMAN_BASH to its bash.exe.',
      { tried: found.tried });
  }
  const dir = path.resolve(repoFromArgv(process.argv, process.defaultApp) || process.cwd());
  const repoRoot = await findRepoRoot({ bash: found.bash, dir });
  const checkout = path.resolve(__dirname, '..');
  const foreman = createForeman({ bash: found.bash, checkout, repoRoot });
  const overview = createOverview({ foreman, repoRoot });
  // A ticket page reads from what the overview already read, and saves against a fresh answer.
  const tickets = createTicketFiles({ repoRoot, foreman, known: (b) => overview.statusOf(b) });
  ctx = { repoRoot, overview, foreman, tickets };
  watcher = createWatcher({
    // A change to anything in a batch — a status line flipped in an editor, the loop landing a
    // ticket — is a reason to read again.
    dirs: async () => (await overview.dirs()).map((p) => repoPath(repoRoot, p)),
    read: () => overview.refresh(),
    onResult: (data) => { if (data) push(data); },          // null: the person moved on meanwhile
    onError: (e) => push({ ok: false, error: describe(e) }),
  });
}

function push(data) {
  if (win && !win.isDestroyed()) win.webContents.send('overview:update', data);
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
    return data;
  } catch (e) {
    return { ok: false, error: describe(e) };
  }
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
