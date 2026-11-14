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
  // Open a repo-relative path (a ticket, a batch folder) with Windows' own default.
  open: (relativePath) => ipcRenderer.invoke('open', relativePath),
});
