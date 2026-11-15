'use strict';
// The two empty/error states that cannot be told from `status --json` alone, and the reads that tell them
// (ticket 07). Both are the CLI's own facts, asked for through `foreman <command> --json`; this file only
// looks in the answers.
//
//   a runner missing  The batch's exec mode is FOREMAN_EXEC as the CLI resolves it — the environment, then
//                     the batch's foreman.conf, then `sandbox` — and whether the tool that mode needs is on
//                     PATH is in `doctor --json`, which says `sbx is not on PATH, and FOREMAN_EXEC=sandbox
//                     needs it` as a failing row. The doctor's rows are the union over every batch, so a
//                     row counts only when it names this batch's mode. (`dry-run --json` is not used: its
//                     preflight refuses on a dirty tree, which is when a person is mid-edit.)
//   a login expired   `status --json` says the last run ended as `needs_human` (exit 20, with the loop's own
//                     `# reason:`), and `report --json --run <id>` says the run's last record carried
//                     `auth-failed` — the same fact the loop stopped on.
//
// The doctor takes seconds, so it is never waited for: an overview is answered at once, the doctor is read
// behind it, and `onChange` says when it found something different, for the window to be sent again.
// A failing read is no state at all: nothing here is guessed.

const RUNNER_ROW = /^(\S+) is not on PATH, and FOREMAN_EXEC=(\S+) needs it$/;

// FOREMAN_EXEC for a batch, the way foreman-config.sh settles it: the environment first, then the last
// active `FOREMAN_EXEC=` line of foreman.conf (as the doctor reads it, legacy `RALPH_EXEC=` too), else the
// default, sandbox.
function execModeOf(confText, env = {}) {
  const fromEnv = env.FOREMAN_EXEC !== undefined ? String(env.FOREMAN_EXEC).trim() : '';
  if (fromEnv !== '') return fromEnv;
  let mode = '';
  if (typeof confText === 'string') {
    for (const line of confText.split('\n')) {
      const m = /^[ \t]*(?:export[ \t]+)?(?:FOREMAN|RALPH)_EXEC=(.*)$/.exec(line.replace(/\r$/, ''));
      if (m) mode = m[1].replace(/[ \t]+#.*$/, '').replace(/["']/g, '').trim();
    }
  }
  return mode === '' ? 'sandbox' : mode;
}

function runnersMissing(batch, doctorDoc, mode) {
  if (typeof mode !== 'string' || mode === '') return null;
  const sections = doctorDoc && Array.isArray(doctorDoc.sections) ? doctorDoc.sections : [];
  for (const sec of sections) {
    for (const r of sec.rows || []) {
      const m = r && r.result === 'fail' && typeof r.label === 'string' ? RUNNER_ROW.exec(r.label) : null;
      if (m && m[2] === mode) return { batch, tool: m[1], mode, message: r.label, fix: r.fix || null };
    }
  }
  return null;
}

// Whether the last run of the batch stopped because the agent's login failed.
const endedNeedingAHuman = (status) => !!(status && status.last_run && status.last_run.end === 'needs_human'
  && !(status.run && status.run.in_flight));

function loginExpired(batch, status, reportDoc) {
  if (!endedNeedingAHuman(status)) return null;
  const rows = reportDoc && reportDoc.run && Array.isArray(reportDoc.run.iterations) ? reportDoc.run.iterations : [];
  const last = rows[rows.length - 1];
  if (!last || !Array.isArray(last.flags) || !last.flags.includes('auth-failed')) return null;
  const run = status.last_run;
  return { batch, runId: run.id, exit: 20, message: run.reason || null };
}

function createConditions({ foreman, readConf = () => '', env = {}, onChange }) {
  const runners = new Map();         // batch -> the condition found (or null) by the latest doctor read
  const logins = new Map();          // `${batch}|${run}|${end}|${reason}` -> the condition (or null)
  const reading = new Map();         // batch -> the doctor read in progress

  function readRunners(batch) {
    if (reading.has(batch)) return reading.get(batch);
    const p = (async () => {
      let found;
      try {
        found = runnersMissing(batch, await foreman.doctor(), execModeOf(readConf(batch), env));
      } catch { return; }
      const before = runners.has(batch) ? runners.get(batch) : null;
      runners.set(batch, found);
      if (JSON.stringify(before) !== JSON.stringify(found) && typeof onChange === 'function') onChange(batch);
    })().finally(() => { reading.delete(batch); });
    reading.set(batch, p);
    return p;
  }

  async function login(batch, status) {
    if (!endedNeedingAHuman(status)) return null;
    const run = status.last_run;
    const key = `${batch}|${run.id}|${run.end}|${run.reason || ''}`;
    if (logins.has(key)) return logins.get(key);
    let found;
    try { found = loginExpired(batch, status, await foreman.report(batch, { run: run.id })); } catch { return null; }
    logins.set(key, found);
    return found;
  }

  return {
    // The overview answer with `conditions` added: { login, runners }. `fresh` (the person asked, as against
    // a file changing) starts a new doctor read behind it.
    async decorate(data, { fresh = false } = {}) {
      if (!data || !data.ok) return data;
      if (!data.status || !data.selected) return { ...data, conditions: { login: null, runners: null } };
      const known = runners.get(data.selected) || null;      // what is known now: the doctor is never waited for
      if (fresh) readRunners(data.selected);
      return { ...data, conditions: { login: await login(data.selected, data.status), runners: known } };
    },
    // Resolves when the doctor reads in progress have finished (for the tests).
    async settled() { await Promise.all([...reading.values()]); },
  };
}

module.exports = { execModeOf, runnersMissing, loginExpired, createConditions };
