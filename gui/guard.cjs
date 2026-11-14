'use strict';
// What the window refuses, and how it learns which repository it was opened on. No Electron in
// here, so both are tested with plain Node.
const win = require('path').win32;
const { checkBatchPath, ForemanError } = require('./foreman.cjs');

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

module.exports = { repoFromArgv, refuseNavigation, openWindowHandler, repoPath };
