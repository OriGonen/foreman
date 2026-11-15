'use strict';
// What the live run screen shows, worked out from what main read (live.cjs) and `status --json`.
// Loaded like model.js: as a <script> (`ForemanRunView` on the window) and with require() in the tests.
// No DOM, no Node. It words what the files say and decides nothing about the run: an outcome is the
// CLI's word (`report --run`), the running iteration is the one the loop's `iteration` file names.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ForemanRunView = factory();
}(typeof self !== 'undefined' ? self : this, function () {

  const usd = (n) => '$' + Number(n).toFixed(2);
  const pad = (n) => String(n).padStart(2, '0');

  // 1500000 -> "25m00s", 48000 -> "0m48s"; "" for what is not known.
  function clock(ms) {
    if (typeof ms !== 'number' || !isFinite(ms) || ms < 0) return '';
    const s = Math.round(ms / 1000);
    return `${Math.floor(s / 60)}m${pad(s % 60)}s`;
  }
  // 144 seconds -> "02:24", the running iteration's own clock.
  function mmss(sec) { return sec < 0 || !isFinite(sec) ? '' : `${pad(Math.floor(sec / 60))}:${pad(Math.floor(sec % 60))}`; }
  const minutes = (ms) => `${Math.max(0, Math.floor(ms / 60000))}m`;

  function ticketName(file) {
    if (file === null || file === undefined || file === '') return '(no ticket)';
    const base = String(file).split('/').pop().replace(/\.md$/i, '').replace(/^[A-Za-z]+_(?=\d)/, '');
    const m = /^(\d+[a-z]?)-(.+)$/i.exec(base);
    return m ? m[1] + ' ' + m[2] : base;
  }

  // How an iteration came out, in the screen's marks: glyph, tone of the glyph, the chip.
  const OUTCOME = {
    landed: { glyph: '✓', tone: 'ok', chip: 'landed' },
    progressed: { glyph: '↗', tone: 'acc', chip: 'followup' },
    stalled: { glyph: '⏸', tone: 'rust', chip: 'human' },
    unproductive: { glyph: '✗', tone: 'err', chip: 'err' },
    checkpoint: { glyph: '⟲', tone: 'muted', chip: 'followup' },
  };

  function row(r, budget) {
    const o = OUTCOME[r.outcome] || { glyph: '·', tone: 'muted', chip: 'todo' };
    const checkpoint = r.kind === 'checkpoint';
    const word = checkpoint ? 'checkpoint turn' : String(r.outcome || 'ended');
    return {
      kind: 'done', glyph: o.glyph, tone: o.tone,
      num: checkpoint ? '' : `${r.iteration}/${budget === null ? '∞' : budget === undefined ? '?' : budget}`,
      label: ticketName(r.ticket), chip: { cls: o.chip, text: word },
      meta: [clock(r.duration_ms), typeof r.cost_usd === 'number' ? usd(r.cost_usd) : ''].filter(Boolean).join(' · '),
      flags: Array.isArray(r.flags) ? r.flags : [],
    };
  }

  // `live` is what live.read answered; `ctx` is { status, now, caps, starting }:
  //   status    the batch's `status --json` (its counts, its next ticket, its run)
  //   now       Date.now(), so a test can say what time it is
  //   caps      { cost, minutes } the run was started with, when the app started it; else live.caps
  //   ended     the run is over: its list is the record's, and no row is still running
  function screen(live, ctx) {
    const status = ctx.status || {};
    const run = live.run;
    const ctl = live.control;
    const now = ctx.now;
    const caps = ctx.caps || live.caps || { cost: null, minutes: null };

    const budget = ctl && ctl.budget !== undefined ? ctl.budget : run.budget;
    const finishedIter = live.iterations.filter((r) => r.kind === 'iteration').reduce((m, r) => Math.max(m, r.iteration || 0), 0);
    const iteration = (ctl && ctl.iteration !== null ? ctl.iteration : null) || run.iteration || 0;
    const liveOn = ctl && ctl.live !== undefined ? ctl.live : !!run.live;
    const steerable = !!run.control_dir;

    const rows = live.iterations.map((r) => row(r, budget));
    let running = null;
    if (!ctx.ended && (iteration > finishedIter || rows.length === 0)) {
      const t = live.next || status.next || null;
      const started = ctl && ctl.activity ? ctl.activity.epoch * 1000 : null;
      running = {
        kind: 'running', glyph: '⠹', tone: 'acc', num: iteration ? `${iteration}/${budget === null ? '∞' : budget === undefined ? '?' : budget}` : '',
        label: iteration === 0 ? 'starting…' : t ? ticketName(t.file) : 'working',
        activity: ctl && ctl.activity ? ctl.activity.label : '',
        feed: liveOn && ctl ? ctl.feed.slice(-6) : [], feedOff: !liveOn,
        chip: { cls: 'next', text: 'running' },
        meta: started !== null ? mmss((now - started) / 1000) : '',
      };
      rows.push(running);
    }

    const spent = live.iterations.reduce((s, r) => s + (typeof r.cost_usd === 'number' ? r.cost_usd : 0), 0);
    const spentShown = live.iterations.length === 0 && ctl && ctl.spent ? ctl.spent.spent : spent;
    const started = Date.parse(run.started_at);
    // an ended run's time is what its iterations took (the clock does not run on after it)
    const took = live.iterations.reduce((s, r) => s + (typeof r.duration_ms === 'number' ? r.duration_ms : 0), 0);
    const elapsed = ctx.ended ? (live.iterations.length ? took : null) : isFinite(started) ? Math.max(0, now - started) : null;
    const counts = status.counts || { done: 0, total: 0 };
    const meter = (value, cap) => (cap ? Math.min(1, value / cap) : 0);
    const capText = (n, fmt) => (n ? ` / ${fmt(n)}` : ' · no cap');
    const money = (n) => (Number.isInteger(n) ? '$' + n : usd(n));

    return {
      batch: (status.batch && status.batch.name) || String(live.batch).split('/').pop(),
      batchPath: live.batch,
      run: { id: run.id, startedAt: isFinite(started) ? new Date(started) : null },
      done: `${counts.done} of ${counts.total}`,
      dome: { p: counts.total > 0 ? counts.done / counts.total : 0 },
      elapsed: elapsed === null ? '' : clock(elapsed),
      rows, running, steerable,
      bar: {
        iteration: iteration ? `${iteration} of ${budget === null ? 'unlimited' : budget === undefined ? '?' : budget}` : 'starting',
        budget: budget === undefined ? null : budget, unlimited: budget === null,
        // - can go no lower than the iteration already running; + is meaningless when unlimited
        minusOff: budget !== null && budget !== undefined && budget <= Math.max(iteration, 1),
        plusOff: budget === null,
        spent: { text: usd(spentShown) + capText(caps.cost, money), frac: meter(spentShown, caps.cost), hot: caps.cost ? spentShown / caps.cost >= 0.85 : false },
        time: { text: (elapsed === null ? '—' : minutes(elapsed)) + capText(caps.minutes, (n) => n + 'm'), frac: elapsed === null ? 0 : meter(elapsed / 60000, caps.minutes), hot: caps.minutes && elapsed !== null ? elapsed / 60000 / caps.minutes >= 0.85 : false },
        live: liveOn,
        disabledWhy: steerable ? null : 'Steering needs `doctor --fix`',
      },
      // The compact view: the dome, the running ticket and its last activity, the meters, − / +, Stop.
      compact: {
        line: running ? running.label : '', activity: running ? (running.feed.length ? `${running.feed[running.feed.length - 1].tm} ${running.feed[running.feed.length - 1].tool} ${running.feed[running.feed.length - 1].text}`.trim() : running.activity) : '',
        progress: `${counts.done} of ${counts.total} · iteration ${iteration || '—'} of ${budget === null ? '∞' : budget === undefined ? '?' : budget}`,
      },
    };
  }

  return { screen, clock, mmss, ticketName, OUTCOME };
}));
