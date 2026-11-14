'use strict';
// What the overview shows, worked out from `foreman status --json` (and `--all` for the rail).
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
  function pickBatch(all, wanted) {
    const list = all.batches || [];
    if (wanted) {
      if (list.some((b) => b.path === wanted)) return wanted;
      const dir = wanted.includes('/') ? wanted.slice(0, wanted.lastIndexOf('/') + 1) : '';
      const name = basename(wanted);
      const moved = list.find((b) => b.finished && b.path.startsWith(dir)
        && !b.path.slice(dir.length).includes('/')
        && b.name.length > name.length && b.name.endsWith(name)
        && /[^A-Za-z0-9]$/.test(b.name.slice(0, b.name.length - name.length)));
      if (moved) return moved.path;
    }
    const open = list.find((b) => !b.finished && !b.error);
    if (open) return open.path;
    return list.length ? list[0].path : null;
  }

  return { usd, ticketRef, checksChip, stakes, blockers, lastRun, overview, dryRun, rail, pickBatch };
}));
