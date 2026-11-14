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
  // Open a repo-relative path (a ticket, a batch folder) with Windows' own default.
  open: (relativePath) => ipcRenderer.invoke('open', relativePath),
});
