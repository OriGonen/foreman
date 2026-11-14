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

  return { usd, ticketRef, checksChip, stakes, blockers, lastRun, overview, rail, pickBatch };
}));
