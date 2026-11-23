'use strict';
// How a run ended, as a scene (designs/05-run-end.html, take b1): the one place the app maps what the
// loop wrote — `status --json`'s `last_run` (its end word, its exit code, its reason) — to the scene
// that is shown and the next steps it offers. The app has no end-state logic of its own beyond this
// mapping: the exit code the loop wrote picks the scene, and the reason is the loop's own line, passed
// through untouched.
//
// Loaded like model.js and states.js: as a <script> (`ForemanRunEnd` on the window) and with require() in
// the tests. No DOM, no Node, no CLI.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ForemanRunEnd = factory();
}(typeof self !== 'undefined' ? self : this, function () {

  const FREE = { cls: 'free', text: 'free' };
  const PAID = { cls: 'paid', text: 'costs money' };

  const usd = (n) => '$' + Number(n).toFixed(2);
  const pad = (n) => String(n).padStart(2, '0');
  const basename = (p) => String(p).split('/').pop();
  const slugOf = (file) => basename(file).replace(/\.md$/i, '').replace(/^[A-Za-z]+_(?=\d)/, '');

  // 1710000 -> "28m30s", 4320000 -> "1h 12m"
  function clock(ms) {
    if (typeof ms !== 'number' || !isFinite(ms) || ms < 0) return '';
    const s = Math.round(ms / 1000);
    if (s >= 3600) return `${Math.floor(s / 3600)}h ${pad(Math.floor((s % 3600) / 60))}m`;
    return `${Math.floor(s / 60)}m${pad(s % 60)}s`;
  }

  // "04-fourth.md" -> "04 fourth", the way the screens name a ticket.
  function ticketName(file) {
    const base = slugOf(file);
    const m = /^(\d+[a-z]?)-(.+)$/i.exec(base);
    return m ? m[1] + ' ' + m[2] : base;
  }

  // The run's own numbers from what `report --run` listed: the iterations (not the checkpoint turns),
  // what the whole run cost and how long it took.
  function statsOf(rows) {
    const list = Array.isArray(rows) ? rows : [];
    const cost = list.reduce((s, r) => s + (typeof r.cost_usd === 'number' ? r.cost_usd : 0), 0);
    const ms = list.reduce((s, r) => s + (typeof r.duration_ms === 'number' ? r.duration_ms : 0), 0);
    return { iterations: list.filter((r) => r.kind === 'iteration').length, cost, ms, any: list.length > 0 };
  }

  // The path a ticket has now: the record names the file as it was when the iteration ran, and a landed ticket
  // has been renamed since (DONE_01-x.md). The status lists it by its name without the prefix.
  function currentFile(status, file) {
    const hit = (status.tickets || []).find((t) => t.name && t.name === slugOf(file));
    return hit && hit.file ? hit.file : file;
  }

  const act = (o) => o;
  const SHOW = act({ do: 'iterations', label: 'Show iterations' });

  // The human ticket the loop stopped at: the first one not done, else the one it would take next.
  function humanTicket(status) {
    const tickets = status.tickets || [];
    const h = tickets.find((t) => t.human && !t.done);
    if (h) return { file: h.file, name: (h.number ? h.number + ' ' : '') + (h.slug || slugOf(h.file)) };
    if (status.next) return { file: status.next.file, name: ticketName(status.next.file) };
    return null;
  }

  // `ctx`:
  //   status    `status --json` of the batch, read after the run
  //   runId     the run that was watched (its id), or null for one that was never seen in flight
  //   before    when runId is null: the id of the last run before this one began (the run is the one whose
  //             footer is new since then)
  //   watched   the batch path the run was watched at (it differs from status.batch.path after a rename)
  //   rows      `report --run`'s iterations, for the numbers and the ticket it last worked on
  //   exit      { code, out } of the process, when the app started it
  //   login     ticket 07's login-expired condition for this batch, or null
  // Answers { kind: 'scene', scene, code, heading, sentence, message, facts, art, actions } or
  // { kind: 'text', heading, said, actions } for an end the loop's words do not cover, or null when the
  // status does not hold this run's ending (yet).
  function choose(ctx) {
    const status = ctx && ctx.status;
    const last = status && status.last_run;
    if (!last) return null;
    const mine = ctx.runId ? last.id === ctx.runId : last.id !== ctx.before;
    if (!mine) return null;

    const exit = ctx.exit || null;
    const outText = exit && exit.out ? String(exit.out) : '';
    const unknown = (heading, said) => ({
      kind: 'text', heading,
      said: [said, outText, exit && exit.code !== null && exit.code !== undefined ? `(exit ${exit.code})` : ''].filter(Boolean).join('\n\n'),
      actions: [SHOW],
    });
    if (last.end === null || last.end === undefined) {
      return unknown('The run ended without a closing line in the log', 'The loop did not write how it ended, so the app cannot tell whether it finished, paused or stopped.');
    }

    const rows = Array.isArray(ctx.rows) ? ctx.rows : [];
    const stats = statsOf(rows);
    const batch = (status.batch && status.batch.path) || ctx.watched;
    const done = status.counts ? status.counts.done : 0;
    const total = status.counts ? status.counts.total : 0;
    const reason = typeof last.reason === 'string' && last.reason !== '' ? last.reason : null;
    const next = status.next ? ticketName(status.next.file) : null;

    if (last.exit === 0 && last.end === 'complete') {
      const facts = [`${done} of ${total} landed`];
      if (batch !== ctx.watched) facts.push(`now ${batch}`);
      if (stats.any) facts.push(`${stats.iterations} ${stats.iterations === 1 ? 'iteration' : 'iterations'}`, usd(stats.cost), clock(stats.ms));
      return {
        kind: 'scene', scene: 'done', code: 0, cap: 'exit 0 · batch done', heading: 'The batch is done', sentence: null, message: null,
        facts: facts.filter(Boolean).join(' · '), art: { kind: 'done', flags: done },
        actions: [act({ do: 'report', label: 'Report', tag: FREE, primary: true }), SHOW],
      };
    }

    if (last.exit === 10 && last.end === 'paused') {
      return {
        kind: 'scene', scene: 'paused', code: 10, cap: 'exit 10 · paused', heading: `Paused — ${reason || 'budget reached'}`,
        sentence: (next ? `next up: ${next}. ` : '') + 'Nothing is lost.', message: null, facts: null, art: { kind: 'paused', flags: 0 },
        actions: [act({ do: 'resume', label: 'Resume…', tag: PAID, primary: true }), act({ do: 'dry-run', label: 'Dry run', tag: FREE }), SHOW],
      };
    }

    if (last.exit === 20 && last.end === 'needs_human') {
      const lastRow = rows.filter((r) => r && r.ticket).pop();
      const ticket = lastRow ? currentFile(status, lastRow.ticket) : status.next ? status.next.file : null;
      const scene = {
        kind: 'scene', scene: 'problem', code: 20, cap: 'exit 20 · needs a human', heading: 'It needs you to look',
        sentence: 'Look at the ticket and the log, then resume.', message: reason, facts: null, art: { kind: 'problem', flags: 0 },
        login: !!ctx.login,
        actions: [],
      };
      if (ctx.login) { scene.actions = [SHOW]; return scene; }
      if (ticket) scene.actions.push(act({ do: 'open-ticket', label: 'Open ticket', file: ticket }));
      scene.actions.push(act({ do: 'open-log', label: 'Open the log', file: `${batch}/foreman-runs.log` }),
        act({ do: 'doctor', label: 'Doctor', tag: FREE }), act({ do: 'resume', label: 'Resume…', tag: PAID }), SHOW);
      return scene;
    }

    if (last.exit === 30 && last.end === 'waiting_on_human') {
      const human = humanTicket(status);
      const actions = [];
      if (human) actions.push(act({ do: 'handoff', label: 'Fill in handoff', file: human.file, primary: true }), act({ do: 'open-file', label: 'Open ticket in editor', file: human.file }));
      actions.push(act({ do: 'resume', label: 'Resume…', tag: PAID }), SHOW);
      return {
        kind: 'scene', scene: 'human', code: 30, cap: 'exit 30 · waiting on a human', heading: 'Waiting on you' + (human ? ': ' + human.name : ''),
        sentence: 'Do the ticket, fill in its handoff file, then set its status line to implemented. Resuming before that stops here again, at no cost.',
        message: reason, facts: null, art: { kind: 'human', flags: 0 }, actions,
      };
    }

    return unknown('The run ended', `The loop's last line was “${last.end}”${reason ? ': ' + reason : ''}.`);
  }

  return { choose, clock, ticketName, statsOf };
}));
