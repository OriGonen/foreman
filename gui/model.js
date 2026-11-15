'use strict';
// What the screens show, worked out from `foreman status --json` (and `--all` for the rail), `dry-run --json`
// and `report --json`.
//
// Loaded two ways: as a plain <script> in the page (it puts `ForemanModel` on the window) and with
// require() in the tests. No DOM and no Node in here — it takes the objects the CLI printed and
// returns plain data; app.js turns that into elements.
//
// This is the only place the app words things, and it works nothing out that the CLI has not: the
// next ticket, the human ticket that stops a run, the counts and the spend all arrive in the JSON.
// What is left is how to show them — which glyph, which chip, which fraction.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ForemanModel = factory();
}(typeof self !== 'undefined' ? self : this, function () {

  // 1.12 -> "$1.12". Nothing (not "$0.00") for a cost that is not known.
  function usd(n) {
    return typeof n === 'number' && isFinite(n) ? '$' + n.toFixed(2) : '';
  }

  // The number a ticket file starts with ("07a" in "07a-followup-x.md"), else its name.
  function ticketRef(file) {
    const base = String(file).split('/').pop().replace(/\.md$/i, '').replace(/^[A-Za-z]+_(?=\d)/, '');
    const m = /^(\d+[a-z]?)(?=-|$)/i.exec(base);
    return m ? m[1] : base;
  }

  function checksChip(checks) { return 'followup · checks ' + ticketRef(checks); }

  // One character a ticket, in order: d landed · > next · h human · f followup · . to go.
  // The same alphabet the design's dome takes (designs/source/canvas.js).
  function stakes(tickets) {
    return tickets.map((t) => {
      if (t.done) return 'd';
      if (t.state === 'next') return '>';
      if (t.human) return 'h';
      if (t.checks) return 'f';
      return '.';
    }).join('');
  }

  // "Blocked by:" as the ticket wrote it. A list of ticket numbers is shown number by number, each
  // with whether that ticket has landed; anything else is the author's sentence and is kept whole.
  function blockers(text, tickets) {
    if (text == null) return [];
    const s = String(text).trim();
    if (s === '' || /^none\b/i.test(s)) return [];
    if (!/^\d+[a-z]?(\s*(,|&|and)\s*\d+[a-z]?)*$/i.test(s)) return [{ text: s }];
    return s.split(/\s*(?:,|&|\band\b)\s*/i).map((ref) => {
      const hit = tickets.find((t) => String(t.number).toLowerCase() === ref.toLowerCase());
      return { ref, landed: !!(hit && hit.done) };
    });
  }

  // How the last run ended, in the loop's own words (`status --json` gives them as last_run).
  function lastRun(run) {
    if (!run) return null;
    let end;
    switch (run.end) {
      case null: case undefined: end = 'no closing line'; break;
      case 'complete': end = 'complete'; break;
      case 'paused': end = 'paused: ' + (run.reason || 'budget reached'); break;
      case 'waiting_on_human': end = 'stopped: waiting on a human' + (run.reason ? ' — ' + run.reason : ''); break;
      case 'needs_human': end = 'stopped: needs a human' + (run.reason ? ' — ' + run.reason : ''); break;
      default: end = String(run.end);
    }
    return run.id + ' · ' + end;
  }

  function basename(p) { return String(p).split('/').pop(); }

  function row(t) {
    const human = t.human && !t.done;
    let kind = 'todo', glyph = '·', chip = null;
    if (t.done) { kind = 'done'; glyph = '✓'; }
    else if (t.state === 'next') { kind = 'next'; glyph = '▶'; }
    else if (human) glyph = '✋';
    if (human) chip = { cls: 'human', text: 'human' };
    else if (kind === 'next') chip = { cls: 'next', text: 'next' };
    else if (t.checks && !t.done) chip = { cls: 'followup', text: checksChip(t.checks) };
    let meta = usd(t.spent_usd);
    if (meta === '' && human && t.handoff) meta = basename(t.handoff);
    return {
      file: t.file, num: t.number, slug: t.slug, kind, glyph, chip, meta,
    };
  }

  // Everything the batch screen draws.
  function overview(status) {
    const tickets = status.tickets || [];
    const done = status.counts ? status.counts.done : 0;
    const total = status.counts ? status.counts.total : 0;

    const nextT = status.next ? tickets.find((t) => t.file === status.next.file) : null;
    const next = status.next ? {
      file: status.next.file,
      name: nextT ? nextT.number + ' ' + nextT.slug : basename(status.next.file).replace(/\.md$/i, ''),
      human: !!status.next.human,
      blockedBy: nextT ? blockers(nextT.blocked_by, tickets) : [],
      lastRun: lastRun(status.last_run),
      sentBackBy: status.next.sent_back_by || null,
    } : null;

    const humanT = tickets.find((t) => t.human && !t.done);
    const human = humanT ? {
      file: humanT.file,
      name: humanT.number + ' ' + humanT.slug,
      handoff: humanT.handoff || null,
      remaining: status.human_remaining || 0,
      note: status.run_until ? status.run_until.text : null,
    } : null;

    const runs = status.runs || 0;
    return {
      title: status.batch.path,
      dome: {
        landed: done, total, toGo: Math.max(total - done, 0),
        p: total > 0 ? done / total : 0,
        stakes: stakes(tickets),
      },
      spent: runs > 0 && typeof status.spent_usd === 'number'
        ? `${usd(status.spent_usd)} spent in ${runs} ${runs === 1 ? 'run' : 'runs'}` : null,
      next,
      human,
      warnings: status.warnings || [],
      rows: tickets.map(row),
    };
  }

  // ---- the dry run (`foreman dry-run --json`) ----

  const ticketLabel = (t) => (t.number ? t.number + ' ' + t.slug : t.name);

  // A budget as the screen words it: the loop's own number, or "unlimited" for the null that means
  // no limit.
  const limit = (v, prefix = '', suffix = '') => (typeof v === 'number' ? prefix + v + suffix : 'unlimited');

  // Everything the dry run screen draws. The CLI decided what would run and built the prompt; this
  // only words it. The prompt is passed on exactly as it came.
  function dryRun(doc) {
    const wr = doc.would_run || { tickets: [], remaining: [], stops_at: null };
    const s = doc.settings;
    const done = doc.counts ? doc.counts.done : 0;
    const total = doc.counts ? doc.counts.total : 0;

    // One character a ticket, as the overview's dome takes them: the landed ones, then the rest in
    // the order they are still to run, the first of which is next. The batch's file list is not in a
    // dry run's answer, only its landed count, so the landed ones are drawn as a run of `d`.
    const stakeOf = (t, i) => (i === 0 ? '>' : t.human ? 'h' : t.checks ? 'f' : '.');
    const stakes = 'd'.repeat(done) + wr.remaining.map(stakeOf).join('');

    const would = wr.tickets.map((t, i) => ({
      file: t.file, num: t.number, slug: t.slug,
      kind: i === 0 ? 'next' : 'todo', glyph: i === 0 ? '▶' : '',
      chip: t.checks ? { cls: 'followup', text: checksChip(t.checks) } : null,
    }));

    const stop = wr.stops_at ? {
      file: wr.stops_at.file, name: ticketLabel(wr.stops_at), handoff: wr.stops_at.handoff || null,
      text: (wr.stops_at.reached ? (wr.tickets.length > 0 ? 'then the run stops at ' : 'the run stops at ')
        : 'the iteration budget ends the run before ') + ticketLabel(wr.stops_at) + ', a human ticket',
    } : null;

    const settings = [
      ['exec', s.exec], ['perms', s.perms], ['model', s.model], ['effort', s.effort],
      ['live', s.live ? 'on' : 'off'],
      ['budgets', `cost ${limit(s.budgets.cost_usd, '$')} · time ${limit(s.budgets.minutes, '', 'm')} · iterations ${limit(s.budgets.iterations)}`],
      ['logs', [s.logs.jsonl, s.logs.log]],
    ];

    let prompt = null;
    let nothing = null;
    if (doc.prompt) {
      const n = doc.prompt.lines;
      const first = wr.tickets[0];
      prompt = {
        file: doc.prompt.for,
        label: `Prompt for ${first ? first.number || first.name : ticketRef(doc.prompt.for)} · ${n} ${n === 1 ? 'line' : 'lines'}`,
        text: doc.prompt.text,
        numbers: Array.from({ length: n }, (_, i) => i + 1).join('\n'),
      };
    } else if (wr.stops_at && wr.remaining.length > 0 && wr.remaining[0].state === 'stop') {
      nothing = `${ticketLabel(wr.stops_at)} is a human ticket, and it is next. A run stops there, so no prompt would be sent.`;
    } else if (wr.remaining.length === 0) {
      nothing = 'Every ticket in this batch has landed. Nothing would run.';
    } else {
      nothing = 'Nothing would run, so no prompt would be sent.';
    }

    return {
      title: doc.batch.path,
      dome: { landed: done, total, toGo: Math.max(total - done, 0), p: total > 0 ? done / total : 0, stakes },
      summary: would.length === 0 ? 'nothing would run' : `${would.length} would run`,
      would, stop, settings,
      warnings: doc.warnings || [],
      prompt, nothing,
    };
  }

  // ---- the report (`foreman report --json`) ----

  const count = (v) => Number(v || 0).toLocaleString('en-US');
  const plural = (n, one, many) => `${count(n)} ${n === 1 ? one : many || one + 's'}`;
  const exact = (v) => '$' + Number(v || 0).toFixed(4);          // what the plain report prints

  // "batch/issues/DONE_07a-followup-x.md" -> "07a followup-x": how the order names a ticket. Anything
  // that is not a numbered ticket file (the `(unknown)` of a record with none) is kept as it is.
  function ticketName(file) {
    if (file === null || file === undefined || file === '') return '(no ticket)';
    const base = basename(file).replace(/\.md$/i, '').replace(/^[A-Za-z]+_(?=\d)/, '');
    const m = /^(\d+[a-z]?)-(.+)$/i.exec(base);
    return m ? m[1] + ' ' + m[2] : base;
  }

  // The words under a ledger row's name: how many iterations, and how they came out. Counts that are
  // none are left out, as the plain report leaves them out.
  function ledgerParts(row) {
    const parts = [{ text: count(row.iterations), tone: '' }];
    if (row.landed) parts.push({ text: count(row.landed) + ' landed', tone: 'ok' });
    if (row.progressed) parts.push({ text: count(row.progressed) + ' progressed', tone: '' });
    if (row.stalled) parts.push({ text: count(row.stalled) + ' stalled', tone: '' });
    if (row.unproductive) parts.push({ text: count(row.unproductive) + ' unproductive', tone: '' });
    if (row.limit_hits) parts.push({ text: row.limit_hits === 1 ? 'limit hit' : count(row.limit_hits) + ' limit hits', tone: 'rust' });
    if (row.checkpoints) parts.push({ text: plural(row.checkpoints, 'checkpoint turn'), tone: 'dim' });
    return parts;
  }

  // Everything the Report screen draws: the bill, and the ledger. Every figure is the CLI's own
  // sum; this words them and decides nothing about what an iteration was.
  function report(doc) {
    const t = doc.totals;
    const outcomes = [{ label: 'landed', value: count(t.landed), tone: 'ok' }];
    if (t.progressed) outcomes.push({ label: 'progressed', value: count(t.progressed), tone: '' });
    if (t.stalled) outcomes.push({ label: 'stalled', value: count(t.stalled), tone: '' });
    outcomes.push({ label: 'unproductive', value: count(t.unproductive), tone: '' });
    if (t.checkpoints) outcomes.push({ label: 'checkpoint turns', value: count(t.checkpoints), tone: '' });
    if (t.limit_hits) outcomes.push({ label: 'limit hits', value: count(t.limit_hits), tone: 'rust' });

    const tk = t.tokens;
    const bill = {
      total: usd(t.cost_usd),
      exact: exact(t.cost_usd),
      sub: [plural(t.runs, 'run'), plural(t.iterations, 'iteration'), t.minutes.toFixed(1) + ' model-minutes']
        .concat(t.unreadable ? [plural(t.unreadable, 'unreadable line')] : []).join(' · '),
      outcomes,
      tokens: [
        { label: 'billed tokens', value: count(tk.billed), hint: `in ${count(tk.input)} · out ${count(tk.output)}` },
        { label: 'cache read', value: count(tk.cache_read) },
        { label: 'cache write', value: count(tk.cache_write) },
        { label: 'turns', value: count(t.turns) },
      ],
      perIteration: t.per_iteration ? usd(t.per_iteration.cost_usd) : null,
      perIterationHint: t.per_iteration ? count(t.per_iteration.billed_tokens) + ' billed tokens' : null,
    };

    const byRun = doc.by !== 'ticket';
    const dearest = doc.rows.reduce((m, r) => Math.max(m, r.cost_usd), 0);
    const rows = doc.rows.map((r) => ({
      id: r.id,
      label: byRun ? r.id : ticketName(r.id),
      title: byRun ? 'started ' + r.started_at : r.id,
      parts: ledgerParts(r),
      cost: usd(r.cost_usd),
      exact: exact(r.cost_usd),
      // never rounded away to nothing: a run that cost something has a bar
      frac: r.cost_usd > 0 && dearest > 0 ? Math.max(r.cost_usd / dearest, 0.02) : 0,
      hot: r.limit_hits > 0,
      expandable: byRun,
    }));
    // The log is oldest first; the newest run is the one asked about. Tickets stay as first attempted.
    if (byRun) rows.reverse();
    return { title: doc.batch.path, by: byRun ? 'run' : 'ticket', bill, rows };
  }

  // The iterations of the run `--run <id>` was asked about, each as its number, its ticket and the
  // CLI's outcome word — kept whole, with what went wrong beside it. The colour is a way of showing
  // the word, not a second opinion about it.
  const OUTCOME_TONE = { landed: 'ok', unproductive: 'rust', checkpoint: 'dim' };
  function reportIterations(doc) {
    if (!doc.run) return [];
    return doc.run.iterations.map((i) => ({
      label: [i.iteration, ticketName(i.ticket), i.outcome + (i.flags && i.flags.length ? ` (${i.flags.join(', ')})` : '')].join(' · '),
      tone: OUTCOME_TONE[i.outcome] || '',
      cost: usd(i.cost_usd),
      exact: exact(i.cost_usd),
      limit: !!i.limit_hit,
    }));
  }

  // ---- the ticket page (`foreman status --json`, and the files main read for it) ----

  const REMINDER = 'Record where a secret is stored (a password manager entry, an env var name), never its value.';

  // 1710000 -> "28m 30s". Seconds are rounded; an hour or more drops them.
  function duration(ms) {
    if (typeof ms !== 'number' || !isFinite(ms)) return '';
    const total = Math.round(ms / 1000);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const sec = total % 60;
    if (h > 0) return `${h}h ${String(m).padStart(2, '0')}m`;
    return m > 0 ? `${m}m ${sec}s` : `${sec}s`;
  }

  // 310000 -> "310k", 1250000 -> "1.3M", 842 -> "842".
  function compact(n) {
    n = Number(n);
    if (!isFinite(n) || n <= 0) return '0';
    const trim = (v) => (v >= 10 ? String(Math.round(v)) : v.toFixed(1).replace(/\.0$/, ''));
    if (n < 1000) return String(Math.round(n));
    if (n < 999500) return trim(n / 1000) + 'k';
    return trim(n / 1e6) + 'M';
  }

  const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

  // The entries of progress.txt that are about one ticket. An entry is what follows a heading
  // (`## 07 — what happened`); it belongs to the ticket when its heading starts with the ticket's
  // number, or when anywhere in it the ticket is named in full (`07-try-it-on-a-real-repo`, with or
  // without a path or `DONE_`). A file with no headings at all is read a line at a time, where a line
  // that has the number as a word of its own is the ticket's. What comes before the first heading is
  // nobody's. Everything stays as it was written, apart from the `#` marks on a heading.
  function ticketNotes(progress, ticket) {
    if (typeof progress !== 'string' || progress === '' || !ticket) return [];
    const number = ticket.number ? escapeRe(String(ticket.number)) : null;
    const named = ticket.name ? new RegExp(`(?<![A-Za-z0-9])(?:DONE_)?${escapeRe(ticket.name)}(?![A-Za-z0-9-])`, 'i') : null;
    const headed = number ? new RegExp(`^(?:DONE_)?${number}(?![A-Za-z0-9])`, 'i') : null;
    const word = number ? new RegExp(`(?<![A-Za-z0-9.\\-])${number}(?![A-Za-z0-9])`, 'i') : null;

    const lines = progress.split(/\r\n|\r|\n/);
    const heading = (l) => /^#{1,6}\s+(.*?)\s*$/.exec(l);
    const out = [];
    if (!lines.some((l) => heading(l))) {
      for (const l of lines) {
        if (l.trim() !== '' && ((named && named.test(l)) || (word && word.test(l)))) out.push({ title: null, text: l.trim() });
      }
      return out;
    }
    let cur = null;
    const entries = [];
    for (const l of lines) {
      const h = heading(l);
      if (h) { cur = { title: h[1], body: [] }; entries.push(cur); } else if (cur) cur.body.push(l);
    }
    for (const e of entries) {
      const text = e.body.join('\n').replace(/^\s*\n/, '').trimEnd();
      if ((headed && headed.test(e.title)) || (named && (named.test(e.title) || named.test(text)))) out.push({ title: e.title, text });
    }
    return out;
  }

  const GLYPH = { landed: ['✓', 'ok'], progressed: ['↗', ''], stalled: ['⏸', 'rust'], checkpoint: ['⋯', 'dim'], unproductive: ['✗', 'rust'] };

  // Everything the ticket page draws, except the files' own text, which is passed on as it is. `doc`
  // is what main read (ticket text, progress.txt, the handoff) or null while it is being read.
  function ticketPage(status, name, doc) {
    const tickets = status && status.tickets;
    const t = Array.isArray(tickets) ? tickets.find((x) => x.name === name) : null;
    if (!t) return null;
    const plain = (text, tone = '') => ({ text, tone });
    const human = t.human && !t.done;
    const stats = t.stats || null;

    let chip = null;
    if (t.done) chip = { cls: 'landed', text: 'done' };
    else if (human) chip = { cls: 'human', text: 'human' };
    else if (t.state === 'next') chip = { cls: 'next', text: 'next' };
    else if (t.checks) chip = { cls: 'followup', text: checksChip(t.checks) };

    const labelOf = (x) => x.number + ' ' + x.slug;
    const facts = [{ label: 'Status', parts: [plain(t.status, t.done ? 'ok' : '')] }];

    const blocked = blockers(t.blocked_by, tickets);
    const blockedParts = [];
    if (blocked.length === 0) blockedParts.push(plain('nothing'));
    for (const [i, b] of blocked.entries()) {
      if (i > 0) blockedParts.push(plain(', '));
      if (b.text !== undefined) { blockedParts.push(plain(b.text)); continue; }
      const hit = tickets.find((x) => String(x.number).toLowerCase() === b.ref.toLowerCase());
      blockedParts.push(plain(b.ref));
      blockedParts.push(b.landed ? plain(' landed', 'muted')
        : hit && hit.human ? plain(' human, not done', 'rust') : plain(' not landed yet', 'muted'));
    }
    facts.push({ label: 'Blocked by', parts: blockedParts });

    if (t.checks) {
      const ref = ticketRef(t.checks);
      const hit = tickets.find((x) => String(x.number).toLowerCase() === ref.toLowerCase());
      facts.push({ label: 'Checks', parts: [plain(hit ? labelOf(hit) : ref)] });
    }
    const checkedBy = t.number ? tickets.filter((x) => x.checks && ticketRef(x.checks).toLowerCase() === String(t.number).toLowerCase()) : [];
    if (checkedBy.length) facts.push({ label: 'Checked by', parts: [plain(checkedBy.map(labelOf).join(', '))] });
    if (t.handoff) facts.push({ label: 'Handoff', parts: [plain(t.handoff)] });
    if (typeof t.spent_usd === 'number') {
      const n = stats ? stats.iterations : null;
      facts.push({ label: 'Spend', parts: [plain(usd(t.spent_usd) + (n === null ? '' : ` · ${n} ${n === 1 ? 'iteration' : 'iterations'}`))] });
    }

    let side;
    if (t.human) {
      side = { kind: 'handoff', path: t.handoff || null, reminder: REMINDER };
    } else if (t.done && stats) {
      const models = Array.isArray(stats.models) && stats.models.length ? stats.models.join(' → ') : 'not recorded';
      const tk = stats.tokens || {};
      let iteration = 0;
      side = {
        kind: 'stats',
        cards: [
          { k: 'Cost', v: usd(stats.cost_usd), mono: false },
          { k: 'Runtime', v: duration(stats.duration_ms), mono: false },
          { k: 'Model', v: models, mono: true },
          { k: 'Iterations', v: count(stats.iterations), mono: false },
          { k: 'Turns', v: count(stats.turns), mono: false },
          { k: 'Tokens in / out', v: `${compact(tk.input)} / ${compact(tk.output)}`, mono: true },
        ],
        iterations: (stats.runs || []).map((r) => {
          if (r.kind !== 'checkpoint') iteration++;
          const [glyph, tone] = GLYPH[r.outcome] || ['·', ''];
          return {
            n: String(iteration || 1), glyph, tone, outcome: r.outcome,
            label: 'run ' + (r.run || '(unknown)') + (r.kind === 'checkpoint' ? ' · checkpoint turn' : ''),
            meta: [duration(r.duration_ms), usd(r.cost_usd)].filter(Boolean).join(' · '),
          };
        }),
      };
    } else if (t.done) {
      side = { kind: 'nostats', text: 'none yet' };
    } else {
      const sentBack = status.next && status.next.file === t.file && status.next.sent_back_by;
      side = {
        kind: 'knows',
        // `run` is null until the control directory exists, and then in flight or not is not known.
        rows: [
          ['Iterations', stats ? `${stats.iterations} · ${usd(stats.cost_usd)}` : 'none yet'],
          ['In flight', status.run && status.run.in_flight === false ? 'no' : 'not known yet'],
          ['Sent back', sentBack ? 'by ' + sentBack : 'no'],
        ],
      };
    }

    return {
      name: labelOf(t), num: t.number || t.name, file: t.file, chip, facts, side,
      text: doc && typeof doc.text === 'string' ? doc.text : null,
      notes: doc ? ticketNotes(doc.progress, t) : [],
    };
  }

  // ---- the doctor (`foreman doctor --json`) ----

  const joinAnd = (parts) => (parts.length > 1 ? parts.slice(0, -1).join(', ') + ' and ' + parts[parts.length - 1] : parts[0] || '');
  // "5 lines to .gitignore and 1 line to .gitattributes": what a plan or a report of it comes to.
  const linesIn = (text) => String(text).split('\n').map((l) => l.replace(/\r$/, '')).filter((l, i, all) => !(i === all.length - 1 && l === ''));
  const linesTo = (list) => joinAnd(list.map((p) => `${plural(linesIn(p.text).length, 'line', 'lines')} to ${p.file}`));

  // The marks are the terminal's: ■ passed, ! a warning or something --fix writes, ✗ something only
  // the person can do.
  function doctorRow(r) {
    const fail = r.result === 'fail';
    const needsYou = fail && !r.auto;
    return {
      mark: needsYou ? '✗' : r.result === 'ok' ? '■' : '!',
      tone: needsYou ? 'err' : r.result === 'ok' ? 'ok' : 'acc',
      label: r.label, detail: r.detail || '', fix: r.fix || null, auto: !!r.auto, notes: r.notes || [],
      result: r.result,
    };
  }

  // Everything the Doctor screen draws. The CLI did the inspecting and gave the verdict, the next
  // command and the plan for --fix; this words them.
  function doctor(doc) {
    const sections = (doc.sections || []).map((s) => ({
      id: s.id, title: s.title, info: s.info || [], rows: (s.rows || []).map(doctorRow),
    }));
    const rows = sections.flatMap((s) => s.rows);
    const legend = [];
    if (rows.some((r) => r.result === 'ok')) legend.push({ mark: '■', tone: 'ok', text: 'passed' });
    if (rows.some((r) => r.result === 'fail' && r.auto)) legend.push({ mark: '!', tone: 'acc', text: '--fix can do it' });
    if (rows.some((r) => r.result === 'fail' && !r.auto)) legend.push({ mark: '✗', tone: 'err', text: 'needs you' });
    if (rows.some((r) => r.result === 'warn')) legend.push({ mark: '!', tone: 'acc', text: 'worth a look' });

    const v = doc.verdict || {};
    const plan = (doc.plan || []).filter((p) => p && typeof p.file === 'string');
    const done = doc.fix && Array.isArray(doc.fix.appended) ? doc.fix.appended.filter((p) => p && typeof p.file === 'string') : [];
    return {
      meta: [doc.repo, doc.rev ? 'foreman ' + doc.rev : '', doc.date].filter(Boolean).join(' · '),
      sections, legend,
      stamp: { label: v.label || '', detail: v.detail || '', tone: v.passed ? 'ok' : 'err' },
      next: doc.next ? { label: doc.next.label, command: doc.next.command } : null,
      fix: plan.length ? {
        files: plan.map((p) => ({ file: p.file, lines: linesIn(p.text), why: p.why || '' })),
        summary: `Appends ${linesTo(plan)}. Nothing else is written.`,
      } : null,
      applied: done.length ? {
        text: `Appended ${linesTo(done)}.`,
        then: 'Review the diff and commit it: a run refuses to start on a dirty tree.',
      } : null,
    };
  }

  // The rail: every batch in the repo, the finished (DONE_) ones last and dimmed.
  function rail(all, selected) {
    const entries = (all.batches || []).map((b) => {
      const c = b.counts;
      return {
        path: b.path, name: b.name,
        label: b.error ? '!' : b.finished ? '✓' : c ? `${c.done}/${c.total}` : '',
        frac: c && c.total > 0 ? c.done / c.total : 0,
        on: b.path === selected, done: !!b.finished, error: b.error || null,
      };
    });
    return entries.filter((e) => !e.done).concat(entries.filter((e) => e.done));
  }

  // Which batch to show. The one asked for, if it is still listed. If the loop renamed it to its
  // DONE_ name while the window was open, the finished batch in the same directory whose name is
  // the old one with something non-alphanumeric in front. Otherwise the first batch that is not
  // finished and can be read, else the first there is.
  // The finished batch the loop renamed `wanted` to, or null: the one in the same directory whose name is
  // the old one with something non-alphanumeric in front. null too when `wanted` is itself listed.
  function renamedTo(all, wanted) {
    const list = (all && all.batches) || [];
    if (!wanted || list.some((b) => b.path === wanted)) return null;
    const dir = wanted.includes('/') ? wanted.slice(0, wanted.lastIndexOf('/') + 1) : '';
    const name = basename(wanted);
    const moved = list.find((b) => b.finished && b.path.startsWith(dir)
      && !b.path.slice(dir.length).includes('/')
      && b.name.length > name.length && b.name.endsWith(name)
      && /[^A-Za-z0-9]$/.test(b.name.slice(0, b.name.length - name.length)));
    return moved ? moved.path : null;
  }

  function pickBatch(all, wanted) {
    const list = all.batches || [];
    if (wanted) {
      if (list.some((b) => b.path === wanted)) return wanted;
      const moved = renamedTo(all, wanted);
      if (moved) return moved;
    }
    const open = list.find((b) => !b.finished && !b.error);
    if (open) return open.path;
    return list.length ? list[0].path : null;
  }

  return { usd, ticketRef, checksChip, stakes, blockers, lastRun, overview, dryRun, report, reportIterations, ticketName, ticketNotes, ticketPage, duration, compact, doctor, rail, pickBatch, renamedTo };
}));
