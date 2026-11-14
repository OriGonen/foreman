'use strict';
// Which batch the window is on, and the reads that fill it. Two things ask for a read: the person
// (a click on the rail: `load`) and the watcher (a file changed: `refresh`). They can overlap — a
// read takes seconds under Git Bash — so a refresh that was running when the person clicked is
// thrown away rather than allowed to put the window back where it was.
//
// The chosen batch is a variable, nothing more: it is not stored anywhere and is gone when the
// window closes.
const M = require('./model.js');

function createOverview({ foreman, repoRoot }) {
  let selected = null;
  let lastAll = null;
  let lastStatus = null;     // { batch, status } of the latest read that got one
  let epoch = 0;             // changes whenever the person asks for something

  // The rail and the chosen batch's status. If the chosen batch cannot be read but the list says it
  // should be, that is thrown (the watcher tries once more: the loop may have renamed it a moment
  // ago); if the list itself says it is broken, that is an answer.
  async function read(wanted) {
    const all = await foreman.statusAll();
    lastAll = all;
    const pick = M.pickBatch(all, wanted);
    const data = { ok: true, repoRoot, all, selected: pick, status: null, statusError: null };
    if (pick === null) return data;
    try {
      data.status = await foreman.status(pick);
      lastStatus = { batch: pick, status: data.status };
    } catch (e) {
      const entry = all.batches.find((b) => b.path === pick);
      if (!entry || !entry.error) throw e;
      data.statusError = e.message;
    }
    return data;
  }

  return {
    get selected() { return selected; },

    // What the last read said about `batch`, for a page that needs a ticket's facts (the ticket page)
    // without asking foreman again; null if the last read was of another batch.
    statusOf(batch) { return lastStatus && lastStatus.batch === batch ? lastStatus.status : null; },

    // The person asked: show `wanted` (null: the first batch worth showing).
    async load(wanted) {
      epoch++;
      try {
        const data = await read(wanted);
        selected = data.selected;
        return data;
      } finally {
        epoch++;
      }
    },

    // A file changed: read what the window is on again. null when the person moved the window
    // while this was reading.
    async refresh() {
      const asked = epoch;
      const data = await read(selected);
      if (asked !== epoch) return null;
      selected = data.selected;      // follows a batch the loop renamed to DONE_
      return data;
    },

    // The directories to watch, repo-relative: every batch still being worked on, and the one the
    // window is on even if it is finished.
    async dirs() {
      if (!lastAll) return [];
      return lastAll.batches.filter((b) => !b.finished || b.path === selected).map((b) => b.path);
    },
  };
}

module.exports = { createOverview };
