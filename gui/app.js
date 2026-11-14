'use strict';
// The screens. Everything on them is built with createElement and textContent — ticket names, the
// CLI's words, a stderr line: they are text, never markup, so nothing in a ticket can run here.
// What to show is decided in model.js; this file only turns it into elements.
(function () {
  const api = window.foreman;
  const M = window.ForemanModel;
  const A = window.ForemanArt;
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
      on: { click: openReport },
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
      button('Fill in handoff', { title: 'The ticket page and the handoff editor are a later ticket.' }));
  }

  function warningsCard(warnings) {
    const card = h('div', { cls: 'card bad col warnings' }, h('div', { cls: 'label', text: warnings.length === 1 ? 'Warning' : 'Warnings' }));
    for (const w of warnings) card.append(h('pre', { cls: 'said', text: w }));
    return card;
  }

  function orderList(rows) {
    const list = h('div', { cls: 'card flush tlist', attrs: { role: 'list', 'aria-label': 'Order' } });
    for (const r of rows) {
      list.append(h('div', { cls: 't ' + r.kind, attrs: { role: 'listitem', title: r.file } },
        span('g ' + (r.kind === 'done' ? 'ok' : r.kind === 'next' ? 'acc' : r.glyph === '✋' ? 'rust' : 'dim'), r.glyph),
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
    dryToken++; dry = null;
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

  // ---- drawing, keeping the person's place ----

  let data = null;
  let selecting = false;

  function draw() {
    const before = app.querySelector('.main');
    const scroll = before ? before.scrollTop : 0;
    const focused = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.batch : undefined;
    app.replaceChildren();

    if (!data || !data.ok) {
      app.classList.add('solo');
      app.append(failureView(data ? data.error : { kind: 'spawn', message: 'Waiting for foreman…' }));
      document.title = 'Foreman';
      return;
    }
    app.classList.remove('solo');
    // The dry run and the report are of the batch that was selected when they were asked for.
    if (view === 'dryrun' && (!dry || !data.status || dry.batch !== data.selected)) { dryToken++; view = 'overview'; dry = null; }
    if (view === 'report' && (!rep || rep.batch !== data.selected)) { view = 'overview'; rep = null; }
    const rail = railView(data, (batch) => { if (!selecting) start(batch); });
    app.append(rail);

    if (data.all.batches.length === 0) {
      app.append(paneView('No batch here.', 'A batch is a directory with a foreman.conf in it.\n' + data.repoRoot));
      document.title = 'Foreman — ' + data.repoRoot;
    } else if (view === 'report') {
      app.append(reportView(data));
      document.title = 'Foreman — report · ' + rep.batch;
    } else if (data.status) {
      app.append(view === 'dryrun' ? dryRunView(data) : overviewView(data));
      document.title = (view === 'dryrun' ? 'Foreman — dry run · ' : 'Foreman — ') + data.status.batch.path;
    } else {
      app.append(paneView('This batch cannot be read.', data.statusError || '', button('Try again', { onClick: () => start(data.selected) })));
      document.title = 'Foreman — ' + (data.selected || data.repoRoot);
    }

    const main = app.querySelector('.main');
    if (main) main.scrollTop = scroll;
    if (focused) {
      for (const b of app.querySelectorAll('[data-batch]')) if (b.dataset.batch === focused) b.focus();
    }
  }

  async function start(batch) {
    dryToken++;
    view = 'overview';
    dry = null;
    rep = null;
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

  api.onUpdate((fresh) => { data = fresh; draw(); });
  start(null);
}());
