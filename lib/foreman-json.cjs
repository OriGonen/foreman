#!/usr/bin/env node
// The `--json` side of foreman's read-only commands: `foreman status --json` and
// `foreman dry-run --json`.
//
// The loop works out the facts exactly as it does for the plain output (foreman-loop.sh, the
// functions beside `status_facts`) and hands them over as lines of `key<TAB>value` — it decides,
// this file only assembles. What it adds is what the plain output never needed: the title,
// status word and `Blocked by:` of each ticket (read from its file), what each ticket cost (from
// the run record, which is machine-readable already) and how the last run ended (from the run
// log's own closing lines). No picking, budgeting or landing is worked out here, so a window built
// on this object cannot disagree with `foreman status`.
//
//   node foreman-json.cjs status      < facts      one batch's object, on one line
//   node foreman-json.cjs status-all  < batches    every batch's counts, from each batch's own object
//   node foreman-json.cjs dry-run     < facts      what a run would do, its settings and its prompt
//   node foreman-json.cjs doctor      < facts      `foreman doctor`'s sheet: sections, rows, verdict, next
//
// Every object has `foreman_json` (a version, bumped only on an incompatible change) and the
// `command` it answers. Paths in it are repo-relative with forward slashes; the one absolute path,
// the repository root, is in the mixed form (C:/x), with no backslash.
//
// Facts, one per line (a `ticket` line has more fields, in this order):
//   repo      root                   mixed form
//   batch     path                   repo-relative
//   name      the batch's name
//   statusline  the status line's prefix, as foreman.conf sets it (default `**Status:**`)
//   doneprefix  the prefix a landed ticket's file is renamed with (may be empty)
//   runjsonl  / runlog               where the run record and the run log are
//   done      N   total  N           from `foreman next --count`
//   ticket    state  file  done  human  checks  handoff
//   humans    N                      human tickets remaining
//   runctl    path                   where this batch's run keeps its control directory, if it does
//   until     N  stop-file           where a run stops for a human, when it is not at the next ticket
//   sentback  name                   who sent the next (human) ticket back
//   warning   text
//
// `dry-run` takes the same lines, with these differences. A `ticket` line is one of the tickets
// still to do, its state `run` (a run would take it), `stop` (the first human ticket, where a run
// stops) or `later`; its `done` field is always 0, because a landed ticket is not listed. No `humans`,
// `until` or `sentback`, and instead:
//   stopreach  0|1                   whether the iteration budget gets as far as the `stop` ticket
//   exec / perms / model / effort    as `dry-run` prints them
//   live       on|off
//   cost / minutes / iterations      the budgets as numbers (0 is no limit)
//   budgets    text                  the `Budgets:` line's words, `cost=unlimited  time=...`
//   logjsonl / logrun                where the run record and the run log are
//   promptfor  file                  the ticket the prompt is for (none for a human ticket)
//   prompt     text                  the prompt, with \\ \n \t \r escaped so it is one line
//
// A `status` ticket that has run (it has a line in the run record) also has `stats`, worked out from
// the record by the same pass as `spent_usd`; one that has not has no such key:
//   iterations   how many (a checkpoint turn is a row of its own, not an iteration, as `report` counts)
//   cost_usd / duration_ms / turns   sums over every row, checkpoint turns included
//   tokens       { input, output, cache_read, cache_creation }, the sums
//   models       each distinct `model` the record names, in the order first seen (none for lines
//                written before the model was recorded, or with an empty one)
//   runs         a row per line, in order: run, kind, outcome (the word `foreman report` uses, from
//                foreman-report.cjs), cost_usd, duration_ms, started_at, finished_at
//
// `status` has `run`, always: the run in flight in this batch, read from its control directory when that
// is `<batch>/.foreman-run/` (the loop puts it there when the repository ignores that name):
//   in_flight    true while the pid in its `pid` file is alive
//   id / started_at / iteration / budget / live / control_dir / pid {msys, windows}
//                from the directory's files; budget is null when the run is unlimited. All null when
//                no run is in flight, which is also what a run with its control directory outside the
//                batch looks like: it cannot be seen from here.
// And `last_run` has `reason` after a stop for a human: the line the loop wrote as `# reason:`.
//
// Nothing here throws on a file that is not there: a ticket the loop renamed a moment ago has no
// fields until the next read, a batch that has never run has no spend and no last run.
'use strict';

const fs = require('fs');
const path = require('path');
// The report's own rule for how an iteration ended (the file exports it when it is required, not run).
const { outcomeOf } = require('./foreman-report.cjs');

const FOREMAN_JSON = 1;

// ---------------------------------------------------------------------------
// Reading what the loop hands over
// ---------------------------------------------------------------------------

function parseFacts(text) {
  const facts = { tickets: [], warnings: [] };
  for (const raw of String(text).split('\n')) {
    const line = raw.replace(/\r$/, '');
    if (!line) continue;
    const f = line.split('\t');
    switch (f[0]) {
      case 'ticket':
        facts.tickets.push({
          state: f[1], file: f[2], done: f[3] === '1', human: f[4] === '1',
          checks: f[5] || null, handoff: f[6] || null,
        });
        break;
      case 'warning': facts.warnings.push(f.slice(1).join('\t')); break;
      case 'until': facts.until = { tickets: Number(f[1]), stop: f[2] }; break;
      case 'done': facts.done = Number(f[1]); break;
      case 'total': facts.total = Number(f[1]); break;
      case 'humans': facts.humans = Number(f[1]); break;
      default: facts[f[0]] = f.slice(1).join('\t');
    }
  }
  return facts;
}

// ---------------------------------------------------------------------------
// A ticket's own file
// ---------------------------------------------------------------------------

// A ticket's name is its file's, without the done prefix and the extension: `07a-followup-x`.
function ticketName(file, donePrefix) {
  let base = file.split('/').pop();
  if (donePrefix && base.startsWith(donePrefix)) base = base.slice(donePrefix.length);
  return base.replace(/\.md$/i, '');
}

// `07a-followup-x` is number `07a`, slug `followup-x`. A name with no number is all slug.
function splitName(name) {
  const m = /^(\d+[a-z]*)-(.*)$/.exec(name);
  return m ? { number: m[1], slug: m[2] } : { number: null, slug: name };
}

// What a ticket's file says about itself, for display: its title (the first heading, without the
// number it starts with), its status word (the first word after the status line's prefix) and its
// `Blocked by:` line. All null when the file cannot be read.
function readTicketFile(text, statusLine) {
  const out = { title: null, status: null, blocked_by: null };
  if (text == null) return out;
  const blockedRe = /^(\*\*)?Blocked by:(\*\*)? *(.*)$/;
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\r$/, '');
    if (out.title === null) {
      const h = /^#\s+(.*\S)\s*$/.exec(line);
      if (h) { out.title = h[1].replace(/^\d+[a-z]*\s*[:.\u2013\u2014-]\s*/, ''); continue; }
    }
    if (out.status === null && statusLine && line.startsWith(statusLine)) {
      const word = line.slice(statusLine.length).trim().split(/\s+/)[0];
      if (word) out.status = word;
      continue;
    }
    if (out.blocked_by === null) {
      const b = blockedRe.exec(line);
      if (b && b[3].trim()) out.blocked_by = b[3].trim();
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// The run record: what each ticket cost
// ---------------------------------------------------------------------------

// A path as the record and the listing must both spell it to be the same ticket: forward
// slashes, and the done prefix off the file's name — the record is written before the loop renames
// a landed ticket, and the listing after.
function ticketKey(file, donePrefix) {
  const parts = String(file).replace(/\\/g, '/').split('/');
  const last = parts.length - 1;
  if (donePrefix && parts[last].startsWith(donePrefix)) parts[last] = parts[last].slice(donePrefix.length);
  return parts.join('/');
}

const cents = (n) => Math.round(n * 1e6) / 1e6;
// A number out of a record's field, 0 for anything else (as the report's `n`).
const finite = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : 0);

// What was spent, in total and per ticket, and in how many runs. `total` is null when the record
// holds no record at all (nothing spent is not 0, as `foreman status` says nothing about it);
// a line that is not a record is not counted.
//
// The same pass gives each ticket that has a line its `stats` (`byTicket` keeps the cost alone, as
// before; `stats` has the rest): what a finished ticket's page shows. The sums are over every row of
// the ticket, a checkpoint turn's included — it spent real money and took real time, which is how
// `foreman report` totals them — while `iterations` counts the iterations only, as the report does.
// `runs` has a row for each line, in order, with the report's own word for how it ended (see
// foreman-report.cjs). `models` is each distinct model, in the order first seen: a line written
// before `model` was recorded, or with an empty one, counts in the sums and adds none.
function readSpend(text, donePrefix) {
  const out = { total: null, runs: 0, byTicket: new Map(), stats: new Map() };
  if (text == null) return out;
  const runs = new Set();
  for (const line of text.split(/\r?\n/)) {
    let rec;
    try { rec = JSON.parse(line); } catch { continue; }
    if (!rec || typeof rec !== 'object') continue;
    const cost = Number(rec.cost_usd) || 0;
    out.total = (out.total || 0) + cost;
    if (typeof rec.run_id === 'string') runs.add(rec.run_id);
    if (typeof rec.ticket === 'string' && rec.ticket) {
      const key = ticketKey(rec.ticket, donePrefix);
      out.byTicket.set(key, (out.byTicket.get(key) || 0) + cost);
      let st = out.stats.get(key);
      if (!st) {
        st = {
          iterations: 0, cost_usd: 0, duration_ms: 0, turns: 0,
          tokens: { input: 0, output: 0, cache_read: 0, cache_creation: 0 }, models: [], runs: [],
        };
        out.stats.set(key, st);
      }
      const tokens = rec.tokens && typeof rec.tokens === 'object' ? rec.tokens : {};
      if (rec.kind !== 'checkpoint') st.iterations++;
      st.cost_usd += cost;
      st.duration_ms += finite(rec.duration_ms);
      st.turns += finite(rec.num_turns);
      for (const k of Object.keys(st.tokens)) st.tokens[k] += finite(tokens[k]);
      if (typeof rec.model === 'string' && rec.model && !st.models.includes(rec.model)) st.models.push(rec.model);
      st.runs.push({
        run: typeof rec.run_id === 'string' ? rec.run_id : null,
        kind: rec.kind === 'checkpoint' ? 'checkpoint' : 'iteration',
        outcome: outcomeOf(rec),
        cost_usd: cost,
        duration_ms: finite(rec.duration_ms),
        started_at: typeof rec.started_at === 'string' ? rec.started_at : null,
        finished_at: typeof rec.finished_at === 'string' ? rec.finished_at : null,
      });
    }
  }
  out.runs = runs.size;
  if (out.total !== null) out.total = cents(out.total);
  for (const [k, v] of out.byTicket) out.byTicket.set(k, cents(v));
  for (const st of out.stats.values()) st.cost_usd = cents(st.cost_usd);
  return out;
}

// ---------------------------------------------------------------------------
// The run log: how the last run ended
// ---------------------------------------------------------------------------

// The loop's own closing lines, in the order it writes them (see the end of foreman-loop.sh):
//   # run <id> started <time>
//   # ---- run <id> finished <time> ----
//   # complete | # paused: <why> | # stopped: waiting on a human — <ticket> | # stopped: needs a human
//   # reason: <why>            (after a needs-a-human stop)
// The last run is the last `started`. With no closing line after it the run is still going, or
// was killed, and has an id and no end.
function readLastRun(text) {
  if (text == null) return null;
  let run = null;
  let finished = false;
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\r$/, '');
    let m;
    if ((m = /^# run (\S+) started\b/.exec(line))) {
      run = { id: m[1], end: null, exit: null, reason: null };
      finished = false;
    } else if (!run) {
      continue;
    } else if (/^# ---- run \S+ finished\b/.test(line)) {
      finished = true;
    } else if (!finished) {
      continue;
    } else if (line === '# complete') {
      Object.assign(run, { end: 'complete', exit: 0, reason: null });
    } else if ((m = /^# paused: (.*)$/.exec(line))) {
      Object.assign(run, { end: 'paused', exit: 10, reason: m[1] });
    } else if ((m = /^# stopped: waiting on a human(?: [\u2014-] (.*))?$/.exec(line))) {
      Object.assign(run, { end: 'waiting_on_human', exit: 30, reason: m[1] || null });
    } else if (line === '# stopped: needs a human') {
      Object.assign(run, { end: 'needs_human', exit: 20, reason: null });
    } else if ((m = /^# reason: (.*)$/.exec(line)) && run.end === 'needs_human') {
      run.reason = m[1];
    }
  }
  return run;
}

// ---------------------------------------------------------------------------
// One batch
// ---------------------------------------------------------------------------

// Whether a process is alive, by the pid the loop wrote for it. `kill 0` sends nothing: it only asks
// (EPERM means it is there and not ours).
function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return Boolean(e) && e.code === 'EPERM';
  }
}

function defaultIo() {
  return {
    readFile: (p) => { try { return fs.readFileSync(p, 'utf8'); } catch { return null; } },
    alive: pidAlive,
  };
}

// ---------------------------------------------------------------------------
// The run in flight
// ---------------------------------------------------------------------------

// The files a run keeps in its control directory (see foreman-keys.sh), read while it is alive: its
// `pid` (the loop's MSYS pid and the Windows one, which is the one asked after: it is the same
// number off Windows), `run` (id and start), `iteration`, `budget` (0 is unlimited, and is null
// here), `live`. A directory that is not there, or whose pid is gone — a run killed too hard to
// remove it — is no run: `in_flight` false and the rest null. A run that keeps its control directory
// outside the batch is not seen here at all.
function readRun(dir, io) {
  const none = {
    in_flight: false, id: null, started_at: null, iteration: null, budget: null, live: null,
    control_dir: null, pid: null,
  };
  if (!dir) return none;
  const pids = (io.readFile(`${dir}/pid`) || '').trim().split(/\s+/).filter(Boolean).map(Number);
  if (pids.length === 0 || !pids.every((n) => Number.isInteger(n) && n > 0)) return none;
  const [msys, win = msys] = pids;
  if (!io.alive(win)) return none;
  const word = (name) => (io.readFile(`${dir}/${name}`) || '').trim();
  const [id = null, startedAt = null] = word('run').split(/\s+/);
  const whole = (name) => (/^\d+$/.test(word(name)) ? Number(word(name)) : null);
  const budget = whole('budget');
  return {
    in_flight: true,
    id,
    started_at: startedAt,
    iteration: whole('iteration'),
    budget: budget === 0 ? null : budget,
    live: word('live') === '1',
    control_dir: dir,
    pid: { msys, windows: win },
  };
}

function buildStatus(facts, io = defaultIo()) {
  const donePrefix = facts.doneprefix || '';
  const spend = readSpend(io.readFile(facts.runjsonl), donePrefix);

  const tickets = facts.tickets.map((t) => {
    const name = ticketName(t.file, donePrefix);
    const { number, slug } = splitName(name);
    const own = readTicketFile(io.readFile(t.file), facts.statusline);
    const key = ticketKey(t.file, donePrefix);
    const spent = spend.byTicket.get(key);
    const out = {
      file: t.file, name, number, slug, title: own.title, status: own.status, state: t.state,
      done: t.done, human: t.human, blocked_by: own.blocked_by, checks: t.checks,
      handoff: t.handoff, spent_usd: spent === undefined ? null : spent,
    };
    // Only a ticket that has run has `stats`; one that has not has no such key.
    const stats = spend.stats.get(key);
    if (stats) out.stats = stats;
    return out;
  });

  const nextTicket = tickets.find((t) => t.state === 'next');
  const next = nextTicket ? {
    file: nextTicket.file, human: nextTicket.human, handoff: nextTicket.handoff,
    sent_back_by: facts.sentback || null,
  } : null;

  const runUntil = facts.until && facts.until.stop ? {
    tickets: facts.until.tickets,
    stop: facts.until.stop,
    // The sentence `foreman status` prints, word for word (a smoke case holds the two together).
    text: `The loop will run ${facts.until.tickets} ticket(s), then stop at ${facts.until.stop.split('/').pop()} for a human.`,
  } : null;

  return {
    foreman_json: FOREMAN_JSON,
    command: 'status',
    repo_root: facts.repo || '',
    batch: { path: facts.batch, name: facts.name || path.posix.basename(facts.batch || '') },
    counts: { done: facts.done || 0, total: facts.total || 0 },
    next,
    human_remaining: facts.humans || 0,
    run_until: runUntil,
    warnings: facts.warnings,
    spent_usd: spend.total,
    runs: spend.runs,
    tickets,
    last_run: readLastRun(io.readFile(facts.runlog)),
    // The run in flight, from its control directory when that is in the batch.
    run: readRun(facts.runctl, io),
  };
}

// ---------------------------------------------------------------------------
// One dry run
// ---------------------------------------------------------------------------

// The inverse of the loop's `fact_escape`: one pass, so `\\n` (a backslash, then an n) is not
// mistaken for a newline.
function unescapeFact(text) {
  return String(text).replace(/\\([\\nrt])/g, (_, c) => (c === 'n' ? '\n' : c === 'r' ? '\r' : c === 't' ? '\t' : '\\'));
}

// A budget as a program wants it: a number, or null for "no limit" (the loop's 0, which is also what
// anything that is not a positive number means to it).
function budgetNumber(text) {
  const n = Number(text);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function buildDryRun(facts, io = defaultIo()) {
  const donePrefix = facts.doneprefix || '';
  const entry = (t) => {
    const name = ticketName(t.file, donePrefix);
    const { number, slug } = splitName(name);
    const own = readTicketFile(io.readFile(t.file), facts.statusline);
    return {
      file: t.file, name, number, slug, title: own.title, human: t.human, checks: t.checks, handoff: t.handoff,
    };
  };
  const remaining = facts.tickets.map((t) => ({ ...entry(t), state: t.state }));
  const tickets = remaining.filter((t) => t.state === 'run').map(({ state, ...rest }) => rest);
  const stopT = remaining.find((t) => t.state === 'stop');
  const stop = stopT ? (({ state, ...rest }) => rest)(stopT) : null;
  const hasPrompt = typeof facts.prompt === 'string' && !!facts.promptfor;
  const text = hasPrompt ? unescapeFact(facts.prompt) : null;
  const iterations = budgetNumber(facts.iterations);

  return {
    foreman_json: FOREMAN_JSON,
    command: 'dry-run',
    repo_root: facts.repo || '',
    batch: { path: facts.batch, name: facts.name || path.posix.basename(facts.batch || '') },
    counts: { done: facts.done || 0, total: facts.total || 0 },
    // What a run would take, in order: the tickets before the first human one that the iteration
    // budget reaches (the cost and time budgets cannot be known before the work is done); every
    // ticket still to do, as `foreman dry-run` lists them, each with its state (`run`, `stop` for the
    // first human ticket, or `later`); and the human ticket the run stops at, with whether the
    // budget gets there.
    would_run: {
      tickets,
      remaining,
      stops_at: stop ? { ...stop, reached: facts.stopreach === '1' } : null,
    },
    settings: {
      exec: facts.exec || '',
      perms: facts.perms || '',
      model: facts.model || '',
      effort: facts.effort || '',
      live: facts.live === 'on',
      budgets: {
        cost_usd: budgetNumber(facts.cost), minutes: budgetNumber(facts.minutes), iterations,
        text: facts.budgets || '',
      },
      logs: { jsonl: facts.logjsonl || '', log: facts.logrun || '' },
    },
    warnings: facts.warnings,
    // The exact prompt `foreman dry-run` prints between its two marker lines, for the first ticket
    // that would run. null when the next ticket is a human one, or nothing is left: no prompt would
    // be sent. `lines` is how many lines the plain output shows.
    prompt: hasPrompt ? { for: facts.promptfor, text, lines: text.split('\n').length } : null,
  };
}

// ---------------------------------------------------------------------------
// Every batch
// ---------------------------------------------------------------------------

// Input, one line per batch: `batch<TAB>path<TAB>finished(0|1)<TAB>exit<TAB>payload`, where the
// payload is that batch's own `status --json` object when it exited 0, and what it said on stderr
// (newlines turned into spaces) when it did not. A batch that cannot be read is listed with the
// CLI's message, so a broken batch does not hide the others. The first line is `repo<TAB>root`.
function buildStatusAll(text) {
  let repo = '';
  const batches = [];
  for (const raw of String(text).split('\n')) {
    const line = raw.replace(/\r$/, '');
    if (!line) continue;
    const f = line.split('\t');
    if (f[0] === 'repo') { repo = f.slice(1).join('\t'); continue; }
    if (f[0] !== 'batch') continue;
    const [, p, fin, code] = f;
    const payload = f.slice(4).join('\t');
    const entry = {
      path: p, name: path.posix.basename(p), finished: fin === '1',
      counts: null, human_remaining: null, next: null, error: null,
    };
    let one = null;
    if (code === '0') { try { one = JSON.parse(payload); } catch { /* reported below */ } }
    if (one && one.counts) {
      entry.name = one.batch.name;
      entry.counts = one.counts;
      entry.human_remaining = one.human_remaining;
      entry.next = one.next ? one.next.file : null;
    } else {
      entry.error = (code === '0' ? 'foreman printed something that is not JSON' : payload.trim()) || `foreman exited ${code}`;
    }
    batches.push(entry);
  }
  return { foreman_json: FOREMAN_JSON, command: 'status', all: true, repo_root: repo, batches };
}

// ---------------------------------------------------------------------------
// The doctor's sheet
// ---------------------------------------------------------------------------

// Input, from foreman-doctor.sh under --json: one fact to a line, `key<TAB>value...`, each value
// escaped as `unescapeFact` undoes. In the order the doctor found them:
//   repo / date / rev          the title (repo in the mixed form)
//   check  section state text detail   state is ok, miss, fix (a miss `--fix` writes), stale or info
//   fix    text                the fix of the check before it
//   note   text                more words for the check before it
//   plan   file text why       what `--fix` would append, with the reason (listed whether or not --fix ran)
//   appended  file text        what `--fix` did append
//   fixrun N                   `--fix` ran; N checks still need something after it
//   advice label command       the next command
//   credential name set|unset  whether it is there, never what it is
// Rows are ok, warn or fail as the box's marks are: stale is a warn, miss and fix are fails, and an
// `info` line (a line with no mark of its own) is not a row but kept under its section.
const DOCTOR_SECTIONS = [
  ['machine', 'Machine'], ['repository', 'Repository'], ['skill', 'Skill'], ['batches', 'Batches'],
  ['rename', 'From before the rename to foreman'],
];
const DOCTOR_RESULT = { ok: 'ok', stale: 'warn', miss: 'fail', fix: 'fail' };

function buildDoctor(text) {
  const out = { repo: '', date: '', rev: '' };
  const plan = [];
  const appended = [];
  const credentials = [];
  const checks = [];
  let advice = null;
  let remaining = null;
  for (const raw of String(text).split('\n')) {
    const line = raw.replace(/\r$/, '');
    if (!line) continue;
    const f = line.split('\t').map(unescapeFact);
    const last = checks[checks.length - 1];
    switch (f[0]) {
      case 'repo': case 'date': case 'rev': out[f[0]] = f[1] || ''; break;
      case 'check': checks.push({ section: f[1], state: f[2], label: f[3] || '', detail: f[4] || '', fix: null, notes: [] }); break;
      case 'fix': if (last && last.fix === null) last.fix = f[1] || null; break;
      case 'note': if (last) last.notes.push(f[1] || ''); break;
      case 'plan': plan.push({ file: f[1], text: f[2], why: f[3] || '' }); break;
      case 'appended': appended.push({ file: f[1], text: f[2] }); break;
      case 'fixrun': remaining = Number(f[1]) || 0; break;
      case 'advice': if (!advice) advice = { label: f[1], command: f[2] || '' }; break;
      case 'credential': credentials.push({ name: f[1], state: f[2] === 'set' ? 'set' : 'unset' }); break;
      default: break;
    }
  }
  const sections = [];
  for (const [id, title] of DOCTOR_SECTIONS) {
    const mine = checks.filter((c) => c.section === id);
    const rows = mine.filter((c) => c.state !== 'info').map((c) => ({
      result: DOCTOR_RESULT[c.state] || 'warn', label: c.label, detail: c.detail, fix: c.fix,
      auto: c.state === 'fix', notes: c.notes,
    }));
    const info = mine.filter((c) => c.state === 'info').map((c) => c.label);
    if (rows.length || info.length) sections.push({ id, title, rows, info });
  }
  const real = checks.filter((c) => c.state !== 'info');
  const count = (state) => real.filter((c) => c.state === state).length;
  const fixable = count('fix');
  const blockers = count('miss');
  const passed = fixable + blockers === 0;
  const detail = passed ? 'ready to run' : blockers ? `${blockers} ${blockers === 1 ? 'blocker' : 'blockers'}` : `${fixable} to fix`;
  const result = {
    foreman_json: FOREMAN_JSON, command: 'doctor', repo: out.repo, rev: out.rev, date: out.date,
    sections,
    counts: { ok: count('ok'), warn: count('stale'), fail: fixable + blockers },
    verdict: { passed, label: passed ? 'PASSED' : 'NOT PASSED', detail, fixable, blockers },
    next: advice,
    plan,
    credentials,
  };
  if (remaining !== null) result.fix = { appended, remaining };
  return result;
}

module.exports = {
  FOREMAN_JSON, parseFacts, ticketName, splitName, readTicketFile, ticketKey, readSpend,
  readLastRun, readRun, buildStatus, buildStatusAll, buildDryRun, buildDoctor, unescapeFact,
};

if (require.main === module) {
  const mode = process.argv[2];
  const chunks = [];
  process.stdin.on('data', (d) => chunks.push(d));
  process.stdin.on('end', () => {
    const input = Buffer.concat(chunks).toString('utf8');
    let result;
    if (mode === 'status') result = buildStatus(parseFacts(input));
    else if (mode === 'status-all') result = buildStatusAll(input);
    else if (mode === 'dry-run') result = buildDryRun(parseFacts(input));
    else if (mode === 'doctor') result = buildDoctor(input);
    else { process.stderr.write('usage: foreman-json.cjs status|status-all|dry-run|doctor < facts\n'); process.exit(2); }
    process.stdout.write(JSON.stringify(result) + '\n');
  });
}
