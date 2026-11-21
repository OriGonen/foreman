'use strict';
// What a run is asked to do, and what the confirmation says about it.
//
// Loaded two ways, like model.js: as a plain <script> (it puts `ForemanRunPlan` on the window) and
// with require() in main and the tests. No DOM, no Node in here. The page uses it to word the
// confirmation and to show the exact command; main uses it again, on what the page sent, to build
// the arguments of the process it starts — so the command that is shown and the command that runs
// are the same function of the same request, and a page that sends something odd gets it refused.
//
// A run's three budgets: the iteration count is the argument of `foreman run`; the spend cap and
// the time cap are FOREMAN_MAX_COST_USD and FOREMAN_MAX_MINUTES, which the CLI already ranks above
// foreman.conf. A cap edited in the confirmation is passed to that one run in its environment and
// shown as a prefix of the command. foreman.conf is never written.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./conf.js'));
  else root.ForemanRunPlan = factory(root.ForemanConf);
}(typeof self !== 'undefined' ? self : this, function (Conf) {

  const COST = 'FOREMAN_MAX_COST_USD';
  const MINUTES = 'FOREMAN_MAX_MINUTES';
  const MAX_ITERATIONS = 9999;

  // ---- the three fields, checked ----

  // A whole number of minutes (0: no cap). -> { ok: true, value: '90' } | { ok: false, message }.
  // The value is normalised — no leading zeros, which bash would read as octal — and is what goes
  // into the environment.
  function checkMinutes(text) {
    const s = String(text === undefined || text === null ? '' : text).trim();
    if (s === '') return { ok: false, message: 'Enter a whole number of minutes, or 0 for no cap.' };
    if (!/^\d{1,6}$/.test(s)) return { ok: false, message: 'Minutes must be a whole number, like 90. Use 0 for no cap.' };
    return { ok: true, value: String(parseInt(s, 10)) };
  }

  // Dollars with up to two decimals, with or without a leading $ (0: no cap).
  function checkDollars(text) {
    const s = String(text === undefined || text === null ? '' : text).trim().replace(/^\$\s*/, '');
    if (s === '') return { ok: false, message: 'Enter an amount in dollars, like 10 or 10.50, or 0 for no cap.' };
    const m = /^(\d{1,6})(?:\.(\d{1,2}))?$/.exec(s);
    if (!m) return { ok: false, message: 'Dollars with up to two decimals, like 10 or 10.50. Use 0 for no cap.' };
    return { ok: true, value: String(parseInt(m[1], 10)) + (m[2] === undefined ? '' : '.' + m[2]) };
  }

  // The iteration budget: a whole number from 1, or unlimited (the text `unlimited`, or null).
  function checkIterations(value) {
    if (value === null || value === 'unlimited') return { ok: true, value: null };
    const s = String(value === undefined ? '' : value).trim();
    if (!/^\d{1,4}$/.test(s) || parseInt(s, 10) < 1) {
      return { ok: false, message: `Iterations must be a whole number from 1 to ${MAX_ITERATIONS}, or unlimited.` };
    }
    return { ok: true, value: parseInt(s, 10) };
  }

  // The number a cap value stands for, for comparing an edit with the file's (10 and 10.00 are the
  // same cap). null (and 0) mean no cap.
  const capNumber = (v) => (v === null || v === undefined || v === '' ? 0 : Number(v));

  // ---- the request, and the command it makes ----

  // A request as the page sends it: { iterations: n | null, live: bool, caps: { cost, minutes } } where
  // a cap is a string (an edit) or absent/null (leave it to the file). Checked whole; a request that
  // is not understood is refused rather than adjusted. -> { ok: true, plan } | { ok: false, message }.
  function planFrom(request) {
    const r = request && typeof request === 'object' ? request : {};
    const it = checkIterations(r.iterations === undefined ? undefined : r.iterations);
    if (!it.ok) return it;
    const plan = { iterations: it.value, live: r.live !== false, caps: { cost: null, minutes: null } };
    const caps = r.caps && typeof r.caps === 'object' ? r.caps : {};
    if (caps.cost !== undefined && caps.cost !== null) {
      const c = checkDollars(caps.cost);
      if (!c.ok) return c;
      plan.caps.cost = c.value;
    }
    if (caps.minutes !== undefined && caps.minutes !== null) {
      const c = checkMinutes(caps.minutes);
      if (!c.ok) return c;
      plan.caps.minutes = c.value;
    }
    return { ok: true, plan };
  }

  // What follows `foreman` on the command line: run <batch> <n|--unlimited> [--live]. The batch has
  // been checked as a repo-relative path by whoever calls this (foreman.cjs checkBatchPath).
  function runArgs(batch, plan) {
    const args = ['run', batch, plan.iterations === null ? '--unlimited' : String(plan.iterations)];
    if (plan.live) args.push('--live');
    return args;
  }

  // The environment the run is given on top of what the app passes any CLI call: the edited caps only.
  function capEnv(plan) {
    const env = {};
    if (plan.caps.cost !== null) env[COST] = plan.caps.cost;
    if (plan.caps.minutes !== null) env[MINUTES] = plan.caps.minutes;
    return env;
  }

  // The command as the person would type it: the edited caps as a prefix, then `foreman run ...`.
  // `parts` is the same thing in pieces, for the page to colour the prefix.
  function command(batch, plan) {
    const prefix = Object.entries(capEnv(plan)).map(([k, v]) => `${k}=${v}`);
    const text = ['foreman', ...runArgs(batch, plan)].join(' ');
    return { prefix, text, full: [...prefix, text].join(' ') };
  }

  // ---- the confirmation ----

  const usd = (n) => '$' + Number(n).toFixed(2);

  // Where a cap's value comes from: the environment the app was started in (which the CLI ranks
  // first), foreman.conf (an active, uncommented line), or nowhere.
  function capSource(name, { env, confText }) {
    const { source } = Conf.knob(confText, name, env);
    if (source === 'environment') return { kind: 'environment', text: 'set in the environment' };
    if (source === 'conf') return { kind: 'conf', text: 'set in foreman.conf' };
    return { kind: 'none', text: 'not set · 0 = no cap' };
  }

  // "05 → 06, then stops at 07 (human)": how far `n` iterations can get through what is left, best
  // case — a ticket that takes a second turn uses a second iteration.
  function reach(remaining, n) {
    const list = Array.isArray(remaining) ? remaining : [];
    const label = (t) => (t.number ? t.number : t.name || '');
    const runs = list.filter((t) => t.state === 'run');
    const stop = list.find((t) => t.state === 'stop') || null;
    const taken = n === null ? runs : runs.slice(0, n);
    const parts = [{ text: taken.map(label).join(' → ') }];
    if (taken.length === 0 && stop) parts[0] = { text: 'nothing, ' };
    if (stop && taken.length === runs.length) {
      parts.push({ text: taken.length ? ', then stops at ' : 'stops at ' });
      parts.push({ text: `${label(stop)} (human)`, tone: 'rust' });
    } else if (taken.length < runs.length) {
      parts.push({ text: ', then the budget ends the run' });
    } else if (taken.length > 0) {
      parts.push({ text: ', then nothing is left' });
    }
    if (taken.length === 0 && !stop) parts[0] = { text: 'nothing is left to run' };
    return parts;
  }

  // The starting state of the confirmation, from what main read; and `view` to turn that and the
  // person's edits into what is drawn. `facts` is
  //   { dry: <dry-run --json>, confText, env: { FOREMAN_MAX_COST_USD, FOREMAN_MAX_MINUTES },
  //     inFlight: bool }
  // `edits` is { iterations: text | 'unlimited', cost: text | null, minutes: text | null, live: bool }.
  function start(facts) {
    const s = facts.dry.settings;
    return {
      iterations: s.budgets.iterations === null ? 'unlimited' : String(s.budgets.iterations),
      cost: null, minutes: null, live: true,
    };
  }

  function view(facts, edits, { resume = false } = {}) {
    const dry = facts.dry;
    const s = dry.settings;
    const wr = dry.would_run || { tickets: [], remaining: [], stops_at: null };
    const batch = dry.batch.path;
    const fileCap = (name, effective, parse) => {
      const src = capSource(name, facts);
      return { name, file: effective === null || effective === undefined ? 0 : effective, src, parse };
    };
    const cost = fileCap(COST, s.budgets.cost_usd, checkDollars);
    const minutes = fileCap(MINUTES, s.budgets.minutes, checkMinutes);

    // One cap: what the file gives, what the person typed, whether it is valid and differs, and how
    // it reads.
    const capField = (c, edited, noun, show) => {
      const base = c.file;
      const typed = edited === null || edited === undefined ? null : edited;
      let value = base, error = null, changed = false;
      if (typed !== null) {
        const chk = c.parse(typed);
        if (!chk.ok) error = chk.message;
        else { value = Number(chk.value); changed = value !== base; }
      }
      const raisedOrOff = changed && (value === 0 ? base > 0 : base > 0 && value > base);
      return {
        name: c.name, source: c.src, text: typed === null ? (base === 0 ? '' : String(base)) : typed,
        none: !error && value === 0, value, error, changed, rust: raisedOrOff, reset: changed || error ? show(base) : null,
        file: base,
        // a cap that is not set at all says so, in rust
        unset: base === 0 && !changed, noun,
      };
    };
    const costF = capField(cost, edits.cost, 'dollars', (b) => (b === 0 ? 'none' : usd(b)));
    const minF = capField(minutes, edits.minutes, 'minutes', (b) => (b === 0 ? 'none' : String(b)));

    const it = checkIterations(edits.iterations);
    const plan = { iterations: it.ok ? it.value : 1, live: edits.live !== false, caps: { cost: null, minutes: null } };
    if (costF.changed && !costF.error) plan.caps.cost = String(costF.text).trim().replace(/^\$\s*/, '');
    if (minF.changed && !minF.error) plan.caps.minutes = String(minF.text).trim();
    // The text the field holds is shown as typed; what goes to the run is the normalised value.
    if (plan.caps.cost !== null) plan.caps.cost = checkDollars(plan.caps.cost).value;
    if (plan.caps.minutes !== null) plan.caps.minutes = checkMinutes(plan.caps.minutes).value;

    const cmd = command(batch, plan);
    const spendCap = costF.error ? null : costF.value;
    const button = costF.error ? 'Start run' : (spendCap > 0 ? `Start run · up to ${usd(spendCap)}` : 'Start run · no spend cap');

    // Why Start is off, if it is — the first reason only, said beside the button. (The ignore line is
    // not one: without it the run's control directory is under .git.)
    let blocked = null;
    if (facts.inFlight) blocked = 'A run is already in flight in this batch';
    else if (!it.ok) blocked = it.message;
    else if (costF.error) blocked = costF.error;
    else if (minF.error) blocked = minF.error;
    else if (!wr.remaining.some((t) => t.state === 'run')) blocked = 'Nothing would run: there is no ticket an agent can take.';

    const first = wr.remaining.find((t) => t.state === 'run') || null;
    const label = (t) => (t.number ? `${t.number} ${t.slug}` : t.name);
    const stop = wr.remaining.find((t) => t.state === 'stop') || null;
    const modelLine = `${s.model} · exec ${String(s.exec).replace(/\s*\(.*\)$/, '')} · ${s.perms}`;
    return {
      title: resume ? 'Resume a run' : 'Start a run',
      batch, startsAt: first ? label(first) : (stop ? `${label(stop)} (human)` : 'nothing'),
      reach: reach(wr.remaining, it.ok ? it.value : 1),
      iterations: { text: String(edits.iterations === null ? 'unlimited' : edits.iterations), unlimited: it.ok && it.value === null, error: it.ok ? null : it.message, value: it.ok ? it.value : null },
      cost: costF, minutes: minF,
      live: edits.live !== false,
      model: modelLine, modelSource: 'foreman.conf',
      command: cmd, plan, button, blocked,
      edited: costF.changed || minF.changed,
      warnings: dry.warnings || [],
    };
  }

  // The words behind each ?, as designs/03-run-confirm.html (c2) has them. Plain text: the page sets
  // them with textContent, and draws the command names itself, so there is no markup in here.
  const HELP = {
    'starts at': { title: 'Starts at', body: 'The first ticket this run will work on: the first one in the order that is not done. The same ticket `foreman next` names.' },
    'can reach': { title: 'Can reach', body: 'How far the iteration budget gets before the run stops. A human ticket stops the run wherever it falls, whatever is left of the budget.' },
    iterations: { title: 'Iterations — across the whole run', body: 'How many iterations this run may use, counted across all tickets, not per ticket. One iteration is one turn of the agent on one ticket; a ticket that is not finished in one turn takes another. The run pauses after the last one. unlimited is --unlimited: only the spend and time caps stop it. You can add or take away iterations while it runs.', note: '<n> or --unlimited · argument' },
    'spend cap': { title: 'Spend cap — the whole run', body: 'The most this run may spend in total, across every iteration, not per iteration. It is checked before each iteration starts: the run begins no new one once it has spent the cap. The iteration already running is allowed to finish, so the bill can land a little over. FOREMAN_MAX_COST_USD; 0 means no cap.', note: COST },
    'time cap': { title: 'Time cap — the whole run', body: 'The most wall-clock time the whole run may take, in minutes, not each iteration. It is checked before each iteration starts, so an iteration already running is never cut off. FOREMAN_MAX_MINUTES; 0 means no cap.', note: MINUTES },
    'live tool calls': { title: 'Live tool calls', body: "Shows the agent's tool calls as they happen (--live). It changes only what you see, not what the run does or costs. You can switch it while the run goes, with L." },
    model: { title: 'Model', body: 'The model, where it runs and the permission mode, from foreman.conf (FOREMAN_MODEL, FOREMAN_EXEC, FOREMAN_PERMISSION_MODE). Shown, not editable here.' },
    runs: { title: 'Runs', body: 'The exact command the app will run. Copy it to run the same thing in a terminal.' },
  };

  return { checkMinutes, checkDollars, checkIterations, capNumber, planFrom, runArgs, capEnv, command, capSource, reach, start, view, HELP, COST, MINUTES, MAX_ITERATIONS };
}));
