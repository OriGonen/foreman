'use strict';
// Rebuilds the live run screen from files, whenever it is asked to: the run's control directory
// (`<batch>/.foreman-run/`, or under the git directory when the repository does not ignore that:
// budget, iteration, live, activity, feed — see lib/foreman-ctl.sh), the
// iterations the run has finished with the words the CLI uses for how each came out (`report --json
// --run <id>`, which reads foreman-runs.jsonl), and the run that `status --json` found in flight. It
// keeps nothing the files do not have, apart from the last report it read — an iteration only ends
// when the record changes, and the feed's every line is not a reason to ask the CLI again.
//
// A file that is not there, is half-written (the loop writes by temp file and mv, but the feed is
// appended to), or says something odd reads as absent, never as an error: the screen shows what it
// has and the next change reads again.
const nodeFs = require('fs');
const path = require('path');
const Conf = require('./conf.js');
// The control directory's names. The app runs from the git checkout (ADR 0004, `main.cjs` finds bin/foreman
// at `..`), so lib/ is always beside it.
const Ctl = require('../lib/foreman-ctl.cjs');

function readText(fs, p) { try { return fs.readFileSync(p, 'utf8'); } catch { return null; } }

const whole = (t) => (t !== null && /^\s*\d+\s*$/.test(t) ? Number(t) : null);

// `00:41 · Write README.md` -> { tm: '00:41', tool: 'Write', text: 'README.md' }. A line that is not in
// that shape is shown whole, as text.
function parseFeed(text) {
  if (!text) return [];
  return text.split('\n').map((l) => l.replace(/\r$/, '')).filter((l) => l.trim() !== '').slice(-200).map((l) => {
    const m = /^(\d+:\d{2}(?::\d{2})?) · (.*)$/.exec(l);
    if (!m) return { tm: '', tool: '', text: l };
    const sp = m[2].indexOf(' ');
    return sp < 0 ? { tm: m[1], tool: m[2], text: '' } : { tm: m[1], tool: m[2].slice(0, sp), text: m[2].slice(sp + 1) };
  });
}

// What the control directory says now. `dir` is a full path.
function readControl(dir, fs = nodeFs) {
  const file = (name) => readText(fs, Ctl.filePath(dir, name));
  const budgetText = file(Ctl.FILES.budget);
  const budgetN = whole(budgetText);
  const liveText = file(Ctl.FILES.live);
  const act = (file(Ctl.FILES.activity) || '').trim();
  const am = /^(\d+)\s*(.*)$/.exec(act);
  const spent = /^([0-9]*\.?[0-9]+)\s+([0-9]*\.?[0-9]+)\s*$/.exec(file(Ctl.FILES.spent) || '');
  return {
    // null is unlimited (a budget file of 0); undefined, that the file was not readable
    budget: budgetN === null ? undefined : budgetN === 0 ? null : budgetN,
    iteration: whole(file(Ctl.FILES.iteration)),
    live: liveText === null ? undefined : liveText.trim() === '1',
    activity: am ? { epoch: Number(am[1]), label: am[2] } : null,
    feed: parseFeed(file(Ctl.FILES.feed)),
    spent: spent ? { spent: Number(spent[1]), max: Number(spent[2]) } : null,
  };
}

// The caps as foreman.conf spells them, for a run the app did not start (a terminal's, or one from
// before the app was reopened), whose own environment cannot be seen: an active `FOREMAN_MAX_COST_USD=25`
// line, or one in the environment the app has. null is no cap, or one the app cannot tell.
function capsFromConf(confText, env = {}) {
  const pick = (name) => {
    const { source, value } = Conf.knob(confText, name, env);
    // What conf.js could not settle (`$(cat x)`) is not a number, and is no cap.
    const n = source === null || (source === 'conf' && !/^[0-9]+(?:\.[0-9]+)?$/.test(value)) ? 0 : Number(value);
    return Number.isFinite(n) && n > 0 ? n : null;
  };
  return { cost: pick('FOREMAN_MAX_COST_USD'), minutes: pick('FOREMAN_MAX_MINUTES') };
}

function createLive({ repoRoot, foreman, fs = nodeFs, env = process.env }) {
  let lastReport = null;                 // { batch, runId, rows, error } of the latest read of the record

  async function iterations(batch, runId) {
    try {
      const doc = await foreman.report(batch, { run: runId });
      const rows = doc && doc.run && Array.isArray(doc.run.iterations) ? doc.run.iterations : [];
      lastReport = { batch, runId, rows, error: null };
    } catch (e) {
      // A run that has not finished its first iteration has nothing in the record to report on.
      lastReport = { batch, runId, rows: [], error: e && e.message ? e.message : String(e) };
    }
    return lastReport;
  }

  return {
    // The screen's data for the run `status.run` describes, or null when no run is in flight. With
    // `record` false the report is not asked for again: a feed line or a key press changed, not the
    // record. `next` is `status.next` (the ticket the loop would take, which is the one running).
    async read({ batch, run, next = null, record = true }) {
      if (!run || !run.in_flight) { lastReport = null; return null; }
      const dir = run.control_dir ? Ctl.fullPath(repoRoot, run.control_dir) : null;
      const control = dir ? readControl(dir, fs) : null;
      let rep = lastReport && lastReport.batch === batch && lastReport.runId === run.id ? lastReport : null;
      if (record || !rep) rep = await iterations(batch, run.id);
      const conf = Conf.readBatchConf(fs, `${repoRoot}/${batch}`);
      return {
        batch, run, next, control,
        iterations: rep.rows, iterationsError: rep.error,
        caps: capsFromConf(conf, env),
        at: Date.now(),
      };
    },
    forget() { lastReport = null; },
  };
}

// Of everything that can change in a watched batch, the files a run's control directory keeps while it
// goes (the feed, the activity line, the budget...) are the many, and cost nothing to read: main reads
// them from disk, with no process. The ones that say a run began or ended (`pid`, `run`) and anything
// outside the directory (a ticket, the record, the log) are a reason to ask foreman again. `changes` is
// what watch.cjs hands its read: [{ dir, name }]. `controlDir` is the run's control directory when it
// is watched on its own (controlWatchDir): a change there, named relative to it, is one of its files.
const CONTROL_PREFIX = `${Ctl.DIRNAME}/`;
const STARTS_OR_ENDS = new Set([Ctl.FILES.pid, Ctl.FILES.run]);
function onlyControlFiles(changes, controlDir = null) {
  const one = (c) => {
    if (!c || typeof c.name !== 'string') return false;
    if (controlDir && c.dir === controlDir) return !STARTS_OR_ENDS.has(c.name);
    return c.name.startsWith(CONTROL_PREFIX) && !STARTS_OR_ENDS.has(c.name.slice(CONTROL_PREFIX.length));
  };
  return Array.isArray(changes) && changes.length > 0 && changes.every(one);
}

// The directory to watch for a run in flight besides the batches, as a Windows path (the way main
// spells the batches it watches): its control directory when that is not in the batch, which is when
// the repository does not ignore `.foreman-run/` and the loop keeps it under the git directory
// (lib/foreman-ctl.sh ctl_dir). null otherwise: a `<batch>/.foreman-run/` is in the batch's own watch.
function controlWatchDir(repoRoot, run) {
  if (!run || !run.in_flight || !run.control_dir) return null;
  const dir = String(run.control_dir);
  if (dir === Ctl.DIRNAME || dir.endsWith(`/${Ctl.DIRNAME}`)) return null;
  return path.win32.normalize(Ctl.fullPath(repoRoot, dir).replace(/\//g, '\\'));
}

module.exports = { onlyControlFiles, controlWatchDir, createLive, readControl, parseFeed, capsFromConf };
