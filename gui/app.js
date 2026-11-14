'use strict';
// The screens. Everything on them is built with createElement and textContent — ticket names, the
// CLI's words, a stderr line: they are text, never markup, so nothing in a ticket can run here.
// What to show is decided in model.js; this file only turns it into elements.
(function () {
  const api = window.foreman;
  const M = window.ForemanModel;
  const A = window.ForemanArt;
  const P = window.ForemanPreview;
  const app = document.getElementById('app');

  // h('div', { cls: 'row', text: 'x', on: { click: fn }, attrs: { title: 't' } }, child, ...)
  function h(tag, props, ...kids) {
    const e = document.createElement(tag);
    const p = props || {};
    if (p.cls) e.className = p.cls;
    if (p.text !== undefined) e.textContent = p.text;
    for (const [k, v] of Object.entries(p.attrs || {})) e.setAttribute(k, v);
    for (const [k, fn] of Object.entries(p.on || {})) e.addEventListener(k, fn);
    for (const kid of kids) if (kid !== null && kid !== undefined && kid !== false) e.append(kid);
    return e;
  }
  const span = (cls, text) => h('span', { cls, text });
  const chip = (c) => span('chip ' + c.cls, c.text);
  const NOT_YET = 'Arrives with its own ticket; not built yet.';

  function button(label, { cls = '', tag = null, onClick = null, title = null } = {}) {
    const b = h('button', { cls: 'btn ' + cls, attrs: { type: 'button' } }, label);
    if (tag) b.append(span(tag.cls, tag.text));
    if (onClick) b.addEventListener('click', onClick);
    else { b.disabled = true; b.title = title || NOT_YET; }
    return b;
  }

  // ---- the rail ----

  function railView(data, select) {
    const reporting = view === 'report';
    const entries = M.rail(data.all, reporting ? null : data.selected);
    const rail = h('nav', { cls: 'rail', attrs: { 'aria-label': 'Batches' } });
    const where = data.repoRoot.split('/').filter(Boolean).slice(-1)[0] || data.repoRoot;
    rail.append(
      h('div', { cls: 'mark' }, A.dome({ w: 34, stakes: 'dddd>.hf.', p: 0.4 }),
        h('div', {}, h('b', { text: 'FOREMAN' }), h('small', { text: where, attrs: { title: data.repoRoot } }))),
      h('div', { cls: 'label', text: 'Batches' }),
    );
    for (const e of entries) {
      const item = h('button', {
        cls: 'item' + (e.on ? ' on' : '') + (e.done ? ' done' : '') + (e.error ? ' bad' : ''),
        attrs: { type: 'button', 'data-batch': e.path, title: e.error || e.path, 'aria-current': e.on ? 'page' : 'false' },
        on: { click: () => select(e.path) },
      }, span('name', e.name), span('n', e.label));
      rail.append(item);
      if (!e.done) {
        const bar = h('div', { cls: 'mini' }, h('i'));
        bar.firstChild.style.width = Math.round(e.frac * 100) + '%';
        rail.append(bar);
      }
    }
    // Tools: what the app can tell about a batch without running it. Doctor arrives with its own ticket.
    const report = h('button', {
      cls: 'item' + (reporting ? ' on' : ''),
      attrs: { type: 'button', 'data-tool': 'report', 'aria-current': reporting ? 'page' : 'false' },
      on: { click: () => leaving(openReport) },
    }, 'Report', span('free', 'free'));
    if (!data.selected) { report.disabled = true; report.title = 'There is no batch to report on.'; }
    const read = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    rail.append(h('div', { cls: 'spacer' }), h('div', { cls: 'label', text: 'Tools' }), report,
      h('div', { cls: 'foot', text: 'read from disk · ' + read }));
    return rail;
  }

  // ---- the batch overview (design 01, take a) ----

  function nextCard(o) {
    const card = h('div', { cls: 'card grow col nextcard' }, h('div', { cls: 'label', text: 'Next' }));
    if (!o.next) {
      const all = o.dome.total > 0 && o.dome.landed >= o.dome.total;
      card.append(h('div', { cls: 'muted', text: all ? 'Every ticket has landed.' : 'Nothing is ready to run next.' }));
      return card;
    }
    card.append(h('div', { cls: 'row' }, chip({ cls: 'next', text: 'next' }), h('span', { cls: 'mono name', text: o.next.name })));

    const kv = h('div', { cls: 'kv' });
    kv.append(h('span', { text: 'Blocked by' }), blockedBy(o.next.blockedBy));
    if (o.next.sentBackBy) kv.append(h('span', { text: 'Sent back by' }), h('span', { text: o.next.sentBackBy }));
    if (o.next.lastRun) kv.append(h('span', { text: 'Last run' }), h('span', { text: o.next.lastRun }));
    card.append(kv);

    card.append(h('div', { cls: 'row' }, button('Open ticket', { onClick: () => api.open(o.next.file) })));
    return card;
  }

  function blockedBy(list) {
    const out = h('span');
    if (list.length === 0) { out.textContent = 'nothing'; return out; }
    list.forEach((b, i) => {
      if (i > 0) out.append(', ');
      if (b.text !== undefined) out.append(b.text);
      else out.append(b.ref + ' ', span(b.landed ? 'ok' : 'muted', b.landed ? '✓ landed' : 'not landed'));
    });
    return out;
  }

  function humanCard(o) {
    const hm = o.human;
    const text = h('div', { cls: 'grow' }, h('b', { cls: 'mono', text: hm.name }));
    text.append(hm.note
      ? ' is a human ticket. ' + hm.note
      : ' is a human ticket, and it is next: a run stops there until you mark it done.');
    return h('div', { cls: 'card warm row humanbar' }, chip({ cls: 'human', text: 'human' }), text,
      button('Fill in handoff', { onClick: () => openTicket(ticketNameOf(hm.file)) }));
  }

  function warningsCard(warnings) {
    const card = h('div', { cls: 'card bad col warnings' }, h('div', { cls: 'label', text: warnings.length === 1 ? 'Warning' : 'Warnings' }));
    for (const w of warnings) card.append(h('pre', { cls: 'said', text: w }));
    return card;
  }

  // The name main finds a ticket by (`03-ticket-page`): the same through a DONE_ rename.
  function ticketNameOf(file) {
    const hit = data && data.status ? data.status.tickets.find((t) => t.file === file) : null;
    return hit ? hit.name : String(file).split('/').pop().replace(/\.md$/i, '').replace(/^[A-Za-z]+_(?=\d)/, '');
  }

  function orderList(rows) {
    const list = h('div', { cls: 'card flush tlist', attrs: { 'aria-label': 'Order' } });
    for (const r of rows) {
      const name = ticketNameOf(r.file);
      list.append(h('button', {
        cls: 't ' + r.kind, attrs: { type: 'button', title: r.file, 'data-ticket': name }, on: { click: () => openTicket(name) },
      }, span('g ' + (r.kind === 'done' ? 'ok' : r.kind === 'next' ? 'acc' : r.glyph === '✋' ? 'rust' : 'dim'), r.glyph),
      span('num', r.num), span('slug', r.slug), r.chip ? chip(r.chip) : span('', ''), span('meta', r.meta)));
    }
    return list;
  }

  function overviewView(data) {
    const o = M.overview(data.status);
    const head = h('div', { cls: 'row' },
      h('div', { cls: 'grow' }, h('div', { cls: 'label', text: 'Batch' }), h('div', { cls: 'h1 mono title', text: o.title })),
      button('Open folder', { cls: 'quiet', onClick: () => api.open(data.status.batch.path) }),
      button('Dry run', { tag: { cls: 'free', text: 'free' }, onClick: openDryRun }),
      button('Start run…', { cls: 'primary', tag: { cls: 'paid', text: 'costs money' } }));

    const dome = h('div', { cls: 'card domecard' },
      A.dome({ w: 190, p: o.dome.p, stakes: o.dome.stakes }),
      h('div', { cls: 'col' },
        h('div', { cls: 'big' }, String(o.dome.landed) + ' ', span('muted of', 'of ' + o.dome.total)),
        h('div', { cls: 'muted', text: `landed · ${o.dome.toGo} to go` }),
        o.spent ? h('div', { cls: 'small dim mono', text: o.spent }) : null));

    const main = h('main', { cls: 'main' }, head,
      h('div', { cls: 'row top wrap' }, dome, nextCard(o)));
    if (o.human) main.append(humanCard(o));
    if (o.warnings.length) main.append(warningsCard(o.warnings));
    main.append(orderList(o.rows));
    return main;
  }

  // ---- states that fill the pane ----

  function paneView(sentence, said, ...buttons) {
    const pane = h('main', { cls: 'main pane' }, h('div', { cls: 'h1', text: sentence }));
    if (said) pane.append(h('pre', { cls: 'said', text: said }));
    if (buttons.length) pane.append(h('div', { cls: 'row' }, ...buttons));
    return pane;
  }

  function failureView(error, retry = () => start(null), ...more) {
    const tried = Array.isArray(error.tried) && error.tried.length ? '\n\nLooked at, in order:\n  ' + error.tried.join('\n  ') : '';
    const sentence = {
      'git-bash-missing': 'Git Bash was not found.',
      'not-a-repo': 'This folder is not a git repository.',
      spawn: 'foreman could not be started.',
      exit: 'foreman reported a problem.',
      parse: 'foreman answered with something this app cannot read.',
      version: 'foreman and this app do not match.',
    }[error.kind] || 'Something went wrong.';
    return paneView(sentence, error.message + tried, button('Try again', { onClick: retry }), ...more);
  }

  // ---- the dry run (design 06, take a) ----

  function dryRunView(data) {
    const back = button('Back', { cls: 'quiet', onClick: leaveDryRun });
    if (dry.state === 'loading') return paneView('Reading the dry run…', 'foreman is working out what a run would do. Nothing is sent.', back);
    if (dry.state === 'error') return failureView(dry.error, openDryRun, back);

    const d = M.dryRun(dry.doc);
    const read = dry.at.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    const head = h('div', { cls: 'row' },
      button('← ' + data.status.batch.name, { cls: 'quiet', onClick: leaveDryRun }),
      h('div', { cls: 'h2 grow' }, 'Dry run ', span('free', 'free')),
      span('small muted', 'no prompt is sent · no sandbox starts'),
      span('small dim mono', 'read ' + read),
      button('Run again', { onClick: openDryRun }),
      button('Start run…', { cls: 'primary', tag: { cls: 'paid', text: 'costs money' }, title: 'Starting a run is a later ticket.' }));

    const would = h('div', { cls: 'card col' },
      h('div', { cls: 'row' }, A.dome({ w: 80, p: d.dome.p, stakes: d.dome.stakes }),
        h('div', {}, h('b', { text: `${d.dome.landed} of ${d.dome.total}` }), ' done', h('div', { cls: 'small muted', text: d.summary }))),
      h('div', { cls: 'label', text: 'Would run' }));
    for (const r of d.would) {
      would.append(h('div', { cls: 'mono small wouldrow' + (r.kind === 'next' ? '' : ' muted'), attrs: { title: r.file } },
        span(r.kind === 'next' ? 'acc' : '', r.glyph || '\u00a0'), ' ' + r.num + ' ' + r.slug, r.chip ? ' ' : null, r.chip ? chip(r.chip) : null));
    }
    if (d.stop) would.append(h('div', { cls: 'small rust', text: '✋ ' + d.stop.text }));

    const kv = h('div', { cls: 'kv' });
    for (const [k, v] of d.settings) {
      kv.append(span('', k), Array.isArray(v) ? h('div', {}, ...v.map((x) => h('div', { text: x }))) : span('', v));
    }
    const side = h('div', { cls: 'col side' }, would,
      h('div', { cls: 'card col' }, h('div', { cls: 'label', text: 'Settings' }), kv));
    if (d.warnings.length) side.append(warningsCard(d.warnings));

    const card = h('div', { cls: 'card col grow promptcard' });
    if (d.prompt) {
      card.append(
        h('div', { cls: 'label', text: d.prompt.label }),
        // The prompt is one <pre> holding the CLI's text as it came; the numbers are a second one
        // beside it (not selectable, hidden from a screen reader), so copying the prompt copies
        // the prompt.
        h('div', { cls: 'code' },
          h('pre', { cls: 'nums', attrs: { 'aria-hidden': 'true' }, text: d.prompt.numbers }),
          h('pre', { cls: 'prompt', attrs: { tabindex: '0', 'aria-label': d.prompt.label }, text: d.prompt.text })));
    } else {
      card.append(h('div', { cls: 'label', text: 'Prompt' }), h('div', { cls: 'grow muted', text: d.nothing }));
    }
    card.append(h('div', { cls: 'small dim mono', text: '─── nothing was sent; no sandbox was started' }));

    return h('main', { cls: 'main dry' }, head, h('div', { cls: 'row top dryrow' }, side, card));
  }

  // ---- the report (design 07, take a) ----

  const reportName = (batch) => String(batch).split('/').pop();

  function ledgerRow(r, by) {
    const open = by === 'run' && rep.open.has(r.id);
    const cells = [
      span('mono small rowname', (r.expandable ? (open ? '▾ ' : '▸ ') : '') + r.label),
      h('span', { cls: 'small' }, ...r.parts.flatMap((p, i) => [i > 0 ? ' · ' : null, p.tone ? span(p.tone, p.text) : p.text])),
      h('span', { cls: 'meter' + (r.hot ? ' hot' : '') }, h('i')),
      span('mono small', r.cost),
    ];
    cells[2].firstChild.style.width = Math.round(r.frac * 100) + '%';
    cells[3].title = r.exact;
    if (!r.expandable) return h('div', { cls: 't ledgerrow', attrs: { title: r.title } }, ...cells);
    return h('button', {
      cls: 't ledgerrow run' + (open ? ' open' : ''),
      attrs: { type: 'button', 'data-run': r.id, 'aria-expanded': open ? 'true' : 'false', title: r.title },
      on: { click: () => toggleRun(r.id) },
    }, ...cells);
  }

  // What is under an open run: its iterations as the CLI worded them, or that it is being read, or
  // why it could not be.
  function iterationRows(id) {
    const st = rep.runs[id];
    const note = (cls, text) => h('div', { cls: 't iterrow ' + cls }, span('mono small muted', text));
    if (!st || st.state === 'loading') return [note('muted', 'Reading the iterations…')];
    if (st.state === 'error') return [note('err', st.error.message || 'Could not read the iterations.')];
    return st.iterations.map((i) => h('div', { cls: 't iterrow' }, span('mono small ' + (i.tone || 'muted'), i.label),
      h('span', { cls: 'mono small muted', text: i.cost, attrs: { title: i.exact } })));
  }

  function reportView(data) {
    const back = button('Back', { cls: 'quiet', onClick: leaveReport });
    if (rep.state === 'loading') return paneView('Reading the report…', 'foreman is reading the run record. Nothing is sent.', back);
    if (rep.state === 'error') return failureView(rep.error, () => readReport(rep.by), back);

    const r = M.report(rep.docs[rep.by]);
    const read = rep.at.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    const pick = (by, label) => {
      const b = button(label, { cls: 'quiet' + (rep.by === by ? ' on' : ''), onClick: () => showBy(by) });
      b.setAttribute('aria-pressed', rep.by === by ? 'true' : 'false');
      return b;
    };
    const head = h('div', { cls: 'row' },
      button('← ' + reportName(rep.batch), { cls: 'quiet', onClick: leaveReport }),
      h('div', { cls: 'h2 grow' }, 'Report · ', span('mono', r.title), ' ', span('free', 'free')),
      pick('run', 'By run'), pick('ticket', 'By ticket'),
      span('small dim mono', 'read ' + read),
      button('Read again', { onClick: openReport }));

    const line = (label, value, tone, hint) => {
      const v = span(tone || '', value);
      if (hint) v.title = hint;
      return h('div', { cls: 'line' }, span('', label), v);
    };
    const bill = h('div', { cls: 'bill' },
      h('div', { cls: 'label total', text: 'Total, all runs' }),
      h('div', { cls: 'big', text: r.bill.total, attrs: { title: r.bill.exact } }),
      h('div', { cls: 'small muted', text: r.bill.sub }),
      h('div', { cls: 'rule' }),
      ...r.bill.outcomes.map((o) => line(o.label, o.value, o.tone)),
      h('div', { cls: 'rule' }),
      ...r.bill.tokens.map((o) => line(o.label, o.value, '', o.hint)),
      r.bill.perIteration ? h('div', { cls: 'rule' }) : null,
      r.bill.perIteration ? line('per iteration', r.bill.perIteration, '', r.bill.perIterationHint) : null);

    const ledger = h('div', { cls: 'card flush grow ledger' },
      h('div', { cls: 't ledgerrow headrow' }, span('label', r.by === 'run' ? 'Run' : 'Ticket'), span('label', 'Iterations · landed'), span('label', 'Cost'), span('', '')));
    for (const row of r.rows) {
      ledger.append(ledgerRow(row, r.by));
      if (r.by === 'run' && rep.open.has(row.id)) ledger.append(...iterationRows(row.id));
    }
    return h('main', { cls: 'main report' }, head, h('div', { cls: 'row top reportrow' }, h('div', { cls: 'billcol' }, bill), ledger));
  }

  // What the window is showing: the batch overview, the dry run, or the report of the selected batch.
  // Each is read once, when asked for; a file changing does not read it again (Run again, Read again
  // do), and a read that comes back after the person has left the screen is dropped.
  let view = 'overview';
  let rep = null;            // { batch, by, state: 'loading' | 'ready' | 'error', docs: { run, ticket }, runs: { id: { state, iterations, error } }, open: Set, error, at }

  function leaveReport() {
    rep = null;
    view = 'overview';
    draw();
  }

  // Open the report of the selected batch (again, if it is already open): the default view is by run.
  async function openReport() {
    const batch = data && data.selected;
    if (!batch) return;
    dryToken++; dry = null; tp = null;
    const by = rep && rep.batch === batch ? rep.by : 'run';          // Read again keeps the view
    view = 'report';
    rep = { batch, by, state: 'loading', docs: {}, runs: {}, open: new Set(), error: null, at: null };
    await readReport(by);
  }

  // Ask for one view of the report. `rep` is held in `mine`, so an answer that comes back after the
  // person left, or read again, is dropped.
  async function readReport(by) {
    const mine = rep;
    mine.by = by;
    mine.state = 'loading';
    draw();
    let answer;
    try {
      answer = await api.report(mine.batch, by === 'ticket' ? { byTicket: true } : {});
    } catch (e) {
      answer = { ok: false, error: { kind: 'spawn', message: String(e && e.message ? e.message : e) } };
    }
    if (rep !== mine) return;
    if (answer && answer.ok) {
      mine.docs[by] = answer.doc;
      mine.state = 'ready';
      mine.at = new Date();
    } else {
      mine.state = 'error';
      mine.error = (answer && answer.error) || { kind: 'spawn', message: 'No answer.' };
    }
    draw();
  }

  function showBy(by) {
    if (rep.by === by) return;
    if (rep.docs[by]) { rep.by = by; draw(); } else readReport(by);
  }

  // Open or close a run. Its iterations are asked for the first time it is opened, and again only
  // if that failed.
  async function toggleRun(id) {
    const mine = rep;
    if (mine.open.has(id)) { mine.open.delete(id); draw(); return; }
    mine.open.add(id);
    const have = mine.runs[id];
    if (have && have.state !== 'error') { draw(); return; }
    mine.runs[id] = { state: 'loading' };
    draw();
    let answer;
    try {
      answer = await api.report(mine.batch, { run: id });
    } catch (e) {
      answer = { ok: false, error: { kind: 'spawn', message: String(e && e.message ? e.message : e) } };
    }
    if (rep !== mine) return;
    mine.runs[id] = answer && answer.ok
      ? { state: 'ready', iterations: M.reportIterations(answer.doc) }
      : { state: 'error', error: (answer && answer.error) || { message: 'No answer.' } };
    draw();
  }

  // The dry run, likewise.
  let dry = null;            // { batch, state: 'loading' | 'ready' | 'error', doc, error, at }
  let dryToken = 0;

  function leaveDryRun() {
    dryToken++;
    view = 'overview';
    dry = null;
    draw();
  }

  async function openDryRun() {
    const batch = data && data.selected;
    if (!batch) return;
    const token = ++dryToken;
    tp = null;
    view = 'dryrun';
    dry = { batch, state: 'loading' };
    draw();
    let answer;
    try {
      answer = await api.dryRun(batch);
    } catch (e) {
      answer = { ok: false, error: { kind: 'spawn', message: String(e && e.message ? e.message : e) } };
    }
    if (token !== dryToken) return;
    dry = answer && answer.ok
      ? { batch, state: 'ready', doc: answer.doc, at: new Date() }
      : { batch, state: 'error', error: (answer && answer.error) || { kind: 'spawn', message: 'No answer.' } };
    draw();
  }

  // ---- the ticket page (design 02: b, b1, b2, b3) ----

  // The ticket page is of one ticket of the selected batch, named as main finds it. Its files are read
  // when it opens and again whenever the pushed overview says something changed. The handoff editor
  // is one <textarea> kept for as long as the page is open, so a redraw never takes the person's
  // text, caret or focus with it.
  let tp = null;             // { batch, name, state: 'loading' | 'ready' | 'error', doc, error, readError, mode: 'preview' | 'markdown',
                             //   editor, base, diskChanged, conflict: { disk }, saving, saveError, savedAt, leaving, seq, ui }

  const norm = (v) => String(v).replace(/\r\n?/g, '\n');
  const isDirty = (t) => !!t.editor && norm(t.editor.value) !== norm(t.base === null ? '' : t.base);
  const asError = (e) => ({ kind: 'spawn', message: String(e && e.message ? e.message : e) });

  // Run `next` now — or, if the handoff editor holds changes that are not saved, after the person has
  // said they can go.
  function leaving(next) {
    if (view === 'ticket' && tp && isDirty(tp)) { tp.leaving = next; draw(); return; }
    next();
  }

  function leaveTicket() {
    tp = null;
    view = 'overview';
    draw();
  }

  async function openTicket(name) {
    const batch = data && data.selected;
    if (!batch || !name) return;
    dryToken++; dry = null; rep = null;
    view = 'ticket';
    tp = {
      batch, name, state: 'loading', doc: null, error: null, readError: null, mode: 'preview',
      editor: null, base: null, diskChanged: false, conflict: null, saving: false, saveError: null,
      savedAt: null, leaving: null, seq: 0, ui: null,
    };
    draw();
    await readTicket();
  }

  // What main read, taken into the page. The editor follows the file when it has nothing unsaved; when
  // it has, the draft stays and the page says the file moved (Save then asks, below).
  function takeDoc(t, doc) {
    t.doc = doc;
    const hf = doc.handoff;
    if (!hf || hf.error) return;
    const disk = hf.text;
    if (!t.editor) {
      t.editor = h('textarea', { cls: 'editor', attrs: { spellcheck: 'false', 'aria-label': 'Handoff file', 'data-editor': 'handoff' } });
      t.editor.addEventListener('input', () => syncEditor());
      t.base = disk;
      t.editor.value = disk === null ? '' : disk;
      return;
    }
    if (disk === t.base) { t.diskChanged = false; return; }
    if (!isDirty(t) || norm(t.editor.value) === norm(disk === null ? '' : disk)) {
      t.base = disk;
      if (norm(t.editor.value) !== norm(disk === null ? '' : disk)) t.editor.value = disk === null ? '' : disk;
      t.diskChanged = false;
      t.conflict = null;
    } else {
      t.diskChanged = true;
    }
  }

  async function readTicket() {
    const mine = tp;
    const seq = ++mine.seq;
    let answer;
    try { answer = await api.ticket(mine.batch, mine.name); } catch (e) { answer = { ok: false, error: asError(e) }; }
    if (tp !== mine || seq !== mine.seq) return;
    if (answer && answer.ok) {
      takeDoc(mine, answer.doc);
      mine.state = 'ready';
      mine.readError = null;
    } else {
      const error = (answer && answer.error) || { kind: 'spawn', message: 'No answer.' };
      // A page already showing keeps what it has; the next change reads again.
      if (mine.doc) mine.readError = error.message; else { mine.state = 'error'; mine.error = error; }
    }
    draw();
  }

  function retryTicket() {
    tp.state = 'loading';
    draw();
    readTicket();
  }

  // Save the handoff. `base` is what the file must still be on disk for the write to go ahead: what
  // the editor was opened on, or — after the person chose Overwrite — what is there now.
  async function saveHandoff(base) {
    const mine = tp;
    if (!mine || !mine.editor || mine.saving) return;
    const body = mine.editor.value;
    mine.saving = true;
    mine.saveError = null;
    mine.conflict = null;
    draw();
    let answer;
    try { answer = await api.saveHandoff(mine.batch, mine.name, body, base); } catch (e) { answer = { ok: false, error: asError(e) }; }
    mine.saving = false;
    if (tp !== mine) return;
    if (!answer || !answer.ok) {
      mine.saveError = ((answer && answer.error) || { message: 'No answer.' }).message;
    } else if (answer.saved) {
      mine.base = answer.text;           // as written, with the file's own line endings
      mine.savedAt = new Date();
      mine.diskChanged = false;
    } else if (answer.conflict) {
      mine.conflict = { disk: answer.disk };
    }
    draw();
  }

  // The words on the editor's card that change as the person types, set without redrawing it.
  function syncEditor() {
    const t = tp;
    if (!t || !t.ui) return;
    const dirty = isDirty(t);
    let state = '';
    if (t.saving) state = 'saving…';
    else if (dirty) state = 'unsaved';
    else if (t.base === null) state = 'not written yet';
    else if (t.savedAt) state = 'saved ' + t.savedAt.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    t.ui.state.textContent = state;
    t.ui.save.disabled = t.saving || !(dirty || t.base === null);
    t.ui.warn.hidden = !(t.diskChanged && dirty);
  }

  function inlineNodes(list) {
    return list.map((n) => (n.type === 'bold' ? h('b', { text: n.text }) : n.type === 'code' ? h('code', { text: n.text }) : n.text));
  }

  // The Preview: the nodes preview.js made, as elements, every string through textContent.
  function previewEl(source) {
    const md = h('div', { cls: 'md' });
    for (const node of P.preview(source)) {
      if (node.type === 'heading') md.append(h('h' + Math.min(node.level, 3), {}, ...inlineNodes(node.children)));
      else if (node.type === 'paragraph') md.append(h('p', {}, ...inlineNodes(node.children)));
      else {
        md.append(h('ul', {}, ...node.items.map((it) => h('li', { cls: 'd' + it.depth },
          it.checked === null ? span('dot', '•') : span('bx' + (it.checked ? ' on' : ''), it.checked ? '✓' : ''),
          h('span', {}, ...inlineNodes(it.children))))));
      }
    }
    return md;
  }

  function factsStrip(page) {
    const strip = h('div', { cls: 'card row facts' });
    for (const f of page.facts) {
      strip.append(h('div', { cls: f.label === 'Handoff' || f.label === 'Spend' ? 'grow' : '' },
        h('div', { cls: 'label', text: f.label }),
        h('div', { cls: 'mono wordy' }, ...f.parts.map((p) => (p.tone ? span(p.tone, p.text) : p.text)))));
    }
    return strip;
  }

  function ticketCard(page) {
    const pick = (mode, label) => {
      const b = h('button', { cls: tp.mode === mode ? 'on' : '', attrs: { type: 'button', 'aria-pressed': tp.mode === mode ? 'true' : 'false' }, on: { click: () => { tp.mode = mode; draw(); } } }, label);
      return b;
    };
    const notes = h('div', { cls: 'feed notes' });
    if (page.notes.length === 0) notes.append(h('div', { cls: 'dim', text: `nothing mentions ${page.num} yet` }));
    for (const n of page.notes) {
      notes.append(h('div', { cls: 'noteentry' },
        n.title === null ? null : h('div', { cls: 'notetitle', text: n.title }),
        h('pre', { cls: 'said', text: n.text })));
    }
    return h('div', { cls: 'card col ticketcard' },
      h('div', { cls: 'row' }, h('div', { cls: 'label grow', text: 'Ticket' }),
        h('span', { cls: 'seg', attrs: { role: 'group', 'aria-label': 'View' } }, pick('preview', 'Preview'), pick('markdown', 'Markdown'))),
      h('div', { cls: 'col grow scroller', attrs: { 'data-scroll': 'ticket' } },
        tp.mode === 'markdown' ? h('pre', { cls: 'src', text: page.text === null ? '' : page.text }) : previewEl(page.text === null ? '' : page.text),
        h('div', { cls: 'label notelabel', text: 'Notes in progress.txt' }), notes));
  }

  function handoffCard(page) {
    const t = tp;
    const card = h('div', { cls: 'card col grow sidecard handoff' });
    const state = span('mono small muted', '');
    card.append(h('div', { cls: 'row' }, h('div', { cls: 'label grow', text: 'Handoff file' }), state));
    if (!page.side.path) {
      card.append(h('div', { cls: 'muted', text: 'This ticket has no Handoff: line, so there is no file to fill in.' }));
      return card;
    }
    card.append(h('div', { cls: 'note lock', text: page.side.reminder }));
    const hf = t.doc && t.doc.handoff;
    if (!hf) { card.append(h('div', { cls: 'muted', text: 'Reading the handoff file…' })); return card; }
    if (hf.error) {
      card.append(h('pre', { cls: 'said err', text: hf.error }),
        h('div', { cls: 'small muted', text: 'The app only writes the file the ticket names, and only inside this repository.' }));
      return card;
    }

    // One question at a time: leaving with unsaved changes, else the file having changed under a save.
    if (t.leaving) {
      card.append(h('div', { cls: 'card warm col ask' },
        h('div', { text: 'You have unsaved changes to the handoff. Leave and discard them?' }),
        h('div', { cls: 'row' },
          button('Discard', { onClick: () => { const go = t.leaving; t.leaving = null; t.editor = null; go(); } }),
          button('Keep editing', { cls: 'quiet', onClick: () => { t.leaving = null; draw(); } }))));
    } else if (t.conflict) {
      card.append(h('div', { cls: 'card warm col ask' },
        h('div', { text: t.conflict.disk === null
          ? 'This file was removed from disk since you opened it. Nothing was saved.'
          : 'This file changed on disk since you opened it. Nothing was saved.' }),
        h('div', { cls: 'row' },
          button('Overwrite', { cls: 'primary', onClick: () => saveHandoff(t.conflict.disk) }),
          button('Load from disk', { onClick: () => {
            const disk = t.conflict.disk;
            t.editor.value = disk === null ? '' : disk;
            t.base = disk; t.conflict = null; t.diskChanged = false;
            draw();
          } }),
          button('Keep editing', { cls: 'quiet', onClick: () => { t.conflict = null; t.diskChanged = true; draw(); } }))));
    }
    const warn = h('div', { cls: 'small rust', text: 'The file changed on disk while you were editing. Save will ask before it overwrites.' });
    const save = button('Save handoff', { cls: 'primary', onClick: () => saveHandoff(t.base) });
    t.editor.title = page.side.path;
    t.editor.setAttribute('title', page.side.path);
    card.append(warn, t.editor);
    if (t.saveError) card.append(h('pre', { cls: 'said err', text: t.saveError }));
    card.append(h('div', { cls: 'row' },
      h('span', { cls: 'small muted grow' }, 'When it\'s done, set the ticket\'s status line to ', span('mono', 'implemented'), ' in your editor; the overview updates by itself.'),
      save));
    t.ui = { state, save, warn };
    syncEditor();
    return card;
  }

  function statsCard(side) {
    return h('div', { cls: 'card col grow sidecard' },
      h('div', { cls: 'row' }, h('div', { cls: 'label grow', text: 'Run stats' }), span('mono small muted', 'from foreman-runs.jsonl')),
      h('div', { cls: 'stats' }, ...side.cards.map((c) => h('div', { cls: 's' },
        h('div', { cls: 'k', text: c.k }), h('div', { cls: 'v' + (c.mono ? ' mono' : ''), text: c.v })))),
      h('div', { cls: 'label', text: 'Iterations' }),
      h('div', { cls: 'card flush small tlist iters' }, ...side.iterations.map((r) => h('div', { cls: 't iterline', attrs: { title: r.label } },
        span('g ' + (r.tone || 'acc'), r.glyph), span('num', r.n), span('slug', r.label),
        span('chip ' + (r.tone === 'ok' ? 'landed' : r.tone === 'rust' ? 'human' : 'followup'), r.outcome), span('meta', r.meta)))));
  }

  function sideCard(page) {
    const side = page.side;
    if (side.kind === 'handoff') return handoffCard(page);
    if (side.kind === 'stats') return statsCard(side);
    if (side.kind === 'nostats') {
      return h('div', { cls: 'card col grow sidecard nostats' }, h('div', { cls: 'label', text: 'Run stats' }),
        h('div', { cls: 'muted', text: side.text }));
    }
    const kv = h('div', { cls: 'kv' });
    for (const [k, v] of side.rows) kv.append(span('', k), span('', v));
    return h('div', { cls: 'card col grow sidecard knows' }, h('div', { cls: 'label', text: 'What the loop knows' }), kv);
  }

  function ticketView(data) {
    const t = tp;
    const goBack = () => leaving(leaveTicket);
    const backOnly = button('Back', { cls: 'quiet', onClick: goBack });
    if (t.state === 'loading') return paneView('Reading the ticket…', 'foreman is reading the ticket and its notes. Nothing is sent.', backOnly);
    if (t.state === 'error') return failureView(t.error, retryTicket, backOnly);

    const page = M.ticketPage(data.status, t.name, t.doc);
    if (!page) {
      return paneView(`${t.name} is not in this batch any more.`, 'The loop may have renamed it or the batch moved. Go back to see the order as it is now.', backOnly);
    }
    const head = h('div', { cls: 'row' },
      button('← ' + reportName(t.batch), { cls: 'quiet', onClick: goBack }),
      page.chip ? chip(page.chip) : null,
      h('span', { cls: 'mono grow ticketname', text: page.name }),
      button('Open ticket in editor', { onClick: () => api.open(page.file) }));
    const main = h('main', { cls: 'main ticket' }, head, factsStrip(page));
    if (t.readError) main.append(h('div', { cls: 'small rust', text: 'Could not read the files again: ' + t.readError }));
    main.append(h('div', { cls: 'row top ticketcols' }, ticketCard(page), sideCard(page)));
    return main;
  }

  // ---- drawing, keeping the person's place ----

  let data = null;
  let selecting = false;

  function draw() {
    const before = app.querySelector('.main');
    const scroll = before ? before.scrollTop : 0;
    const focused = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.batch : undefined;
    // The ticket page's own places: how far each of its columns is scrolled, and the editor's caret.
    const scrolls = Array.from(app.querySelectorAll('[data-scroll]')).map((e) => [e.dataset.scroll, e.scrollTop]);
    const ed = tp && tp.editor;
    const edAt = ed ? { focus: document.activeElement === ed, from: ed.selectionStart, to: ed.selectionEnd, top: ed.scrollTop } : null;
    app.replaceChildren();

    if (!data || !data.ok) {
      app.classList.add('solo');
      app.append(failureView(data ? data.error : { kind: 'spawn', message: 'Waiting for foreman…' }));
      document.title = 'Foreman';
      return;
    }
    app.classList.remove('solo');
    // The dry run, the report and a ticket's page are of the batch that was selected when they were asked for.
    if (view === 'dryrun' && (!dry || !data.status || dry.batch !== data.selected)) { dryToken++; view = 'overview'; dry = null; }
    if (view === 'report' && (!rep || rep.batch !== data.selected)) { view = 'overview'; rep = null; }
    if (view === 'ticket' && (!tp || tp.batch !== data.selected || !data.status)) { view = 'overview'; tp = null; }
    const rail = railView(data, (batch) => { if (!selecting) leaving(() => start(batch)); });
    app.append(rail);

    if (data.all.batches.length === 0) {
      app.append(paneView('No batch here.', 'A batch is a directory with a foreman.conf in it.\n' + data.repoRoot));
      document.title = 'Foreman — ' + data.repoRoot;
    } else if (view === 'report') {
      app.append(reportView(data));
      document.title = 'Foreman — report · ' + rep.batch;
    } else if (view === 'ticket') {
      app.append(ticketView(data));
      const page = tp.state === 'ready' ? M.ticketPage(data.status, tp.name, tp.doc) : null;
      document.title = 'Foreman — ' + (page ? page.name : tp.name);
    } else if (data.status) {
      app.append(view === 'dryrun' ? dryRunView(data) : overviewView(data));
      document.title = (view === 'dryrun' ? 'Foreman — dry run · ' : 'Foreman — ') + data.status.batch.path;
    } else {
      app.append(paneView('This batch cannot be read.', data.statusError || '', button('Try again', { onClick: () => start(data.selected) })));
      document.title = 'Foreman — ' + (data.selected || data.repoRoot);
    }

    const main = app.querySelector('.main');
    if (main) main.scrollTop = scroll;
    for (const [key, top] of scrolls) {
      const el = app.querySelector(`[data-scroll="${key}"]`);
      if (el) el.scrollTop = top;
    }
    if (edAt && tp && tp.editor === ed && ed.isConnected !== false) {
      ed.scrollTop = edAt.top;
      if (edAt.focus) {
        ed.focus();
        if (typeof ed.setSelectionRange === 'function') ed.setSelectionRange(edAt.from, edAt.to);
        else { ed.selectionStart = edAt.from; ed.selectionEnd = edAt.to; }
      }
    }
    if (focused) {
      for (const b of app.querySelectorAll('[data-batch]')) if (b.dataset.batch === focused) b.focus();
    }
  }

  async function start(batch) {
    dryToken++;
    view = 'overview';
    dry = null;
    rep = null;
    tp = null;
    selecting = true;
    try {
      data = await api.load(batch);
    } catch (e) {
      data = { ok: false, error: { kind: 'spawn', message: String(e && e.message ? e.message : e) } };
    } finally {
      selecting = false;
    }
    draw();
  }

  // A file changed: the screen redraws from the new overview, and a ticket page reads its own files again.
  api.onUpdate((fresh) => {
    data = fresh;
    draw();
    if (view === 'ticket' && tp && fresh && fresh.ok && fresh.selected === tp.batch) readTicket();
  });
  start(null);
}());
