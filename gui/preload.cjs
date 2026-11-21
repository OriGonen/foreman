'use strict';
// The page's only way out: a small, named API. No Node, no ipcRenderer and no channel names reach
// the page; what main answers is plain data.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('foreman', {
  // The overview of the batch the page is on (null: the first one worth showing) and the rail.
  load: (batch) => ipcRenderer.invoke('overview:load', batch === undefined ? null : batch),
  // Called with a fresh overview whenever a file in a watched batch changes.
  onUpdate: (callback) => {
    const listener = (_event, data) => callback(data);
    ipcRenderer.on('overview:update', listener);
    return () => ipcRenderer.removeListener('overview:update', listener);
  },
  // What a run of that batch would do, its settings and its exact prompt: `foreman dry-run --json`.
  // Free: nothing is sent. Answers { ok: true, doc } or { ok: false, error }.
  dryRun: (batch) => ipcRenderer.invoke('dryrun:load', batch),
  // What a batch has cost: `foreman report --json`. `opts` is { byTicket } or { run: <id> } (that
  // run's iterations); with neither, the totals and a row for each run. Free: it reads a file.
  // Answers { ok: true, doc } or { ok: false, error }.
  report: (batch, opts) => ipcRenderer.invoke('report:load', batch, opts === undefined ? {} : opts),
  // The Doctor sheet: `foreman doctor --json`. Free: nothing is sent and nothing is written.
  // Answers { ok: true, doc } or { ok: false, error }.
  doctor: () => ipcRenderer.invoke('doctor:load'),
  // Fix what it can: `foreman doctor --fix --json`. Appends the lines the sheet's plan listed to
  // .gitignore and .gitattributes (free; no sandbox, nothing sent) and answers with the sheet as
  // it was found plus `doc.fix`, what was appended. The page reads the sheet again afterwards.
  doctorFix: () => ipcRenderer.invoke('doctor:fix'),
  // A ticket's page: its text, the batch's progress.txt and, for a human ticket, its handoff file. The
  // ticket is named by its name (`03-ticket-page`, which a DONE_ rename does not change), never by a
  // path. Free: it reads files. Answers { ok: true, doc } or { ok: false, error }.
  ticket: (batch, name) => ipcRenderer.invoke('ticket:load', batch, name),
  // Save a human ticket's handoff file — the file its Handoff: line names, inside the repo, nothing
  // else. `base` is the text the editor was opened on (null: there was no file). Answers
  // { ok: true, saved: true, text } (the text as written, with the file's own line endings),
  // { ok: true, saved: false, conflict: true, disk } when the file is not `base` any more (nothing
  // was written; saving again with base = disk overwrites), or { ok: false, error }.
  saveHandoff: (batch, name, text, base) => ipcRenderer.invoke('ticket:save', batch, name, text, base === undefined ? null : base),
  // ---- starting, watching and steering a run ----
  // What the confirmation says: `dry-run --json`, whether a run is already going, the batch's
  // foreman.conf and the caps the app's environment carries. Free.
  // Answers { ok: true, doc } or { ok: false, error }.
  runConfirm: (batch) => ipcRenderer.invoke('run:confirm', batch),
  // Start a run — the only call that costs money. `request` is { iterations: n | null, live, caps: { cost,
  // minutes } } with a cap present only when edited for this run. Answers { ok: true, pid, command } once
  // the process exists (not when it ends) or { ok: false, error }.
  runStart: (batch, request) => ipcRenderer.invoke('run:start', batch, request),
  // The live screen's data for a run in flight (null if none): its control files, iterations and caps.
  runLoad: (batch) => ipcRenderer.invoke('run:load', batch),
  // Press + - L as the run's terminal keys do (foreman keys). Answers with the live data read back.
  runKeys: (batch, keys) => ipcRenderer.invoke('run:keys', batch, keys),
  // foreman stop (after this iteration) or, with now, foreman stop --now (waits for the run to end).
  runStop: (batch, now) => ipcRenderer.invoke('run:stop', batch, now === true),
  // Called with { batch, run } whenever a file of the run changes; run is null when it has ended.
  onRunUpdate: (callback) => {
    const listener = (_event, data) => callback(data);
    ipcRenderer.on('run:update', listener);
    return () => ipcRenderer.removeListener('run:update', listener);
  },
  // Called with { batch, code, signal, out } when a run the app started has ended (out: what it said).
  onRunExit: (callback) => {
    const listener = (_event, data) => callback(data);
    ipcRenderer.on('run:exit', listener);
    return () => ipcRenderer.removeListener('run:exit', listener);
  },
  // Compact view: resize the window to the small layout (true) or put the previous size back (false).
  compact: (on) => ipcRenderer.invoke('window:compact', on === true),
  // "Not a git repo": a folder picker. Answers { ok: true, chosen: true } once main has taken the folder (the page
  // then loads again), { ok: true, chosen: false } when cancelled. Nothing is remembered after the app closes.
  chooseFolder: () => ipcRenderer.invoke('repo:choose'),
  // "No batch": put the `foreman init` command on the clipboard. Answers true.
  copyInitCommand: () => ipcRenderer.invoke('clipboard:init'),
  // Open a repo-relative path (a ticket, a batch folder) with Windows' own default.
  open: (relativePath) => ipcRenderer.invoke('open', relativePath),
});
