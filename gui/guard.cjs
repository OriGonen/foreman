'use strict';
// What the window refuses, and how it learns which repository it was opened on. No Electron in
// here, so both are tested with plain Node.
const fs = require('fs');
const win = require('path').win32;
const { checkBatchPath, ForemanError } = require('./foreman.cjs');
const { resolveInside } = require('./ticket.cjs');

// `npm start -- C:\Projects\app` runs `electron . C:\Projects\app`: with a default app (run from a
// folder) the first argument is Electron itself and the second the app's folder; the repository is
// the first argument after those that is not a flag. null when none was given.
function repoFromArgv(argv, defaultApp) {
  const rest = argv.slice(defaultApp ? 2 : 1);
  const repo = rest.find((a) => typeof a === 'string' && a !== '' && !a.startsWith('-'));
  return repo === undefined ? null : repo;
}

// The window loads one page and never leaves it: a link, a form or a script asking to go
// elsewhere is refused, and window.open opens nothing. (The one thing that leaves the window,
// `shell.openPath`, is main's own call and takes a path, never a URL from the page.)
function refuseNavigation(event) { event.preventDefault(); }
function openWindowHandler() { return { action: 'deny' }; }

// A path the page asks main to open (a ticket, a batch folder): repo-relative with forward slashes
// and inside the repository, the same rule the CLI is held to (foreman.cjs checkBatchPath). Joined
// to the root the Windows way, for `shell.openPath`. Throws ForemanError('bad-batch') otherwise.
function repoPath(repoRoot, rel) {
  checkBatchPath(rel);
  const root = win.normalize(String(repoRoot).replace(/\//g, '\\'));
  const full = win.join(root, ...rel.split('/'));
  if (full !== root && !full.toLowerCase().startsWith(root.replace(/\\?$/, '\\').toLowerCase())) {
    throw new ForemanError('bad-batch', `outside the repository: ${JSON.stringify(rel)}`);
  }
  return full;
}

// What the app asks the desktop to open: a ticket or handoff (.md), a note or the run's log (.txt,
// .log), or a folder (the batch's). Never a program or a shortcut, which the default handler would run.
const OPENABLE = new Set(['.md', '.txt', '.log']);

// The real path of a repo-relative file or folder that may be opened, for `shell.openPath`, or a
// ForemanError. Held to the same rule as the handoff file (ticket.cjs resolveInside: symlinks followed
// and still inside the repository, no `:` in a name, nothing in .git), and to the extension list above.
function openablePath(repoRoot, rel, io = fs) {
  checkBatchPath(rel);
  const full = resolveInside(repoRoot, rel, io);
  let isDir = false;
  try { isDir = io.statSync(full).isDirectory(); } catch { /* not there: the extension decides */ }
  if (isDir) return full;
  const ext = win.extname(full).toLowerCase();
  if (!OPENABLE.has(ext)) {
    throw new ForemanError('bad-open', `the app opens only ${[...OPENABLE].join(', ')} files and folders, not ${JSON.stringify(rel)}`);
  }
  return full;
}

module.exports = { repoFromArgv, refuseNavigation, openWindowHandler, repoPath, openablePath, OPENABLE };
