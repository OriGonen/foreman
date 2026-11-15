'use strict';
// The screens. Everything on them is built with createElement and textContent — ticket names, the
// CLI's words, a stderr line: they are text, never markup, so nothing in a ticket can run here.
// What to show is decided in model.js; this file only turns it into elements.
(function () {
  const api = window.foreman;
  const M = window.ForemanModel;
  const A = window.ForemanArt;
  const P = window.ForemanPreview;
  const ST = window.ForemanStates;
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
    const doctoring = view === 'doctor';
    const entries = M.rail(data.all, reporting || doctoring ? null : data.selected);
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
    // Tools: what the app can tell without running anything. The Doctor is of the repository and the
    // machine, not of a batch, so it is there when there is no batch at all.
    const doctor = h('button', {
      cls: 'item' + (doctoring ? ' on' : ''),
      attrs: { type: 'button', 'data-tool': 'doctor', 'aria-current': doctoring ? 'page' : 'false' },
      on: { click: () => leaving(openDoctor) },
    }, 'Doctor', span('free', 'free'));
    const report = h('button', {
      cls: 'item' + (reporting ? ' on' : ''),
      attrs: { type: 'button', 'data-tool': 'report', 'aria-current': reporting ? 'page' : 'false' },
      on: { click: () => leaving(openReport) },
    }, 'Report', span('free', 'free'));
    if (!data.selected) { report.disabled = true; report.title = 'There is no batch to report on.'; }
    const read = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    rail.append(h('div', { cls: 'spacer' }), h('div', { cls: 'label', text: 'Tools' }), doctor, report,
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

  // Start run… — off, with the CLI's own reason as its title, when the batch's runner is missing (the state
  // above the overview says it in full). Dry run, the report and the status all still work.
  function startButton(data) {
    const why = ST.startBlock(data);
    return button('Start run…', {
      cls: 'primary', tag: { cls: 'paid', text: 'costs money' },
      onClick: why ? null : () => openConfirm(), title: why || null,
    });
  }

  function overviewView(data) {
    const o = M.overview(data.status);
    const head = h('div', { cls: 'row' },
      h('div', { cls: 'grow' }, h('div', { cls: 'label', text: 'Batch' }), h('div', { cls: 'h1 mono title', text: o.title })),
      button('Open folder', { cls: 'quiet', onClick: () => api.open(data.status.batch.path) }),
      button('Dry run', { tag: { cls: 'free', text: 'free' }, onClick: openDryRun }),
      startButton(data));

    const dome = h('div', { cls: 'card domecard' },
      A.dome({ w: 190, p: o.dome.p, stakes: o.dome.stakes }),
      h('div', { cls: 'col' },
        h('div', { cls: 'big' }, String(o.dome.landed) + ' ', span('muted of', 'of ' + o.dome.total)),
        h('div', { cls: 'muted', text: `landed · ${o.dome.toGo} to go` }),
        o.spent ? h('div', { cls: 'small dim mono', text: o.spent }) : null));

    const state = ST.choose(data);
    const main = h('main', { cls: 'main' }, head, state ? stateView(state) : null,
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

  // ---- the six states (design 09, take a) ----
  //
  // A picture, one sentence, the CLI's own message and one button. What the button does is named by the state
  // (states.js) and done here. A line under the button says so when it could not.
  let stateNote = null;      // { id, text } — what a state's button could not do
  let copied = false;        // the init command is on the clipboard

  async function chooseFolder() {
    let answer;
    try { answer = await api.chooseFolder(); } catch (e) { answer = { ok: false, error: asError(e) }; }
    if (answer && answer.ok) { if (answer.chosen) start(null); return; }
    stateNote = { id: 'not-a-repo', text: ((answer && answer.error) || { message: 'No answer.' }).message };
    draw();
  }
  async function copyCommand() {
    let ok = false;
    try { ok = (await api.copyInitCommand()) === true; } catch { ok = false; }
    copied = ok;
    stateNote = ok ? null : { id: 'no-batch', text: 'Could not reach the clipboard. Select the command above and copy it.' };
    draw();
  }
  async function openFile(state) {
    let said;
    try { said = await api.open(state.action.file); } catch (e) { said = asError(e).message; }
    stateNote = said ? { id: state.id, text: said } : null;
    if (said) draw();
  }

  function stateAction(state) {
    const a = state.action;
    const label = a.do === 'copy-command' && copied ? 'Copied' : a.label;
    const doIt = {
      'choose-folder': chooseFolder,
      'copy-command': copyCommand,
      'look-again': () => start(null),
      doctor: () => leaving(openDoctor),
      resume: () => openConfirm({ resume: true }),
      'open-file': () => openFile(state),
    }[a.do];
    return button(label, { cls: a.do === 'resume' ? 'primary' : '', tag: a.tag || null, onClick: () => { stateNote = null; return doIt(); } });
  }

  function stateArt(art) {
    return art.kind === 'inspector' ? A.inspector({ w: 64, sign: art.sign }) : A.dome({ w: 130, p: art.p, stakes: art.stakes });
  }

  function stateView(state) {
    const lines = [];
    if (state.detail && state.detail.kind === 'path') lines.push(h('div', { cls: 'where', text: state.detail.text }));
    if (state.detail && state.detail.kind === 'command') lines.push(h('div', { cls: 'where command', text: state.detail.text }));
    const tried = state.detail && state.detail.kind === 'tried'
      ? h('pre', { cls: 'tried', text: 'looked in:\n  ' + state.detail.lines.join('\n  ') }) : null;
    const note = stateNote && stateNote.id === state.id ? h('div', { cls: 'stnote', text: stateNote.text, attrs: { role: 'alert' } }) : null;
    const text = [
      h('div', { cls: 'cap', text: state.cap }),
      h('div', { cls: 'h2', text: state.heading }),
      h('div', { cls: 'sentence', text: state.sentence }),
      state.message ? h('pre', { cls: 'said', text: state.message }) : null,
      ...lines, tried,
    ];
    const attrs = { 'data-state': state.id };
    if (state.whole) {
      return h('main', { cls: 'main pane state', attrs }, ...text.slice(0, 1), stateArt(state.art), ...text.slice(1), stateAction(state), note);
    }
    return h('div', { cls: 'card state', attrs }, stateArt(state.art),
      h('div', { cls: 'text' }, ...text, h('div', { cls: 'row' }, stateAction(state)), note));
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
      startButton(data));

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
    dryToken++; dry = null; tp = null; drToken++; dr = null;
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
    tp = null; drToken++; dr = null;
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

  // ---- the doctor (design 08, take a) ----

  // The inspection sheet of the machine and the repository. It is read once, when asked for (Run
  // again reads it again), and a file changing does not read it again. While it is being read the
  // inspector runs across the track and back, then stands and sweats; that is all CSS, started by
  // the track being built, so a redraw during the read is held back (see the push handler) and the
  // run is not restarted. When the sheet is in, the track is drawn stopped.
  let dr = null;             // { state: 'loading' | 'ready' | 'error', doc, error, at, planOpen, fixing, fixError, applied }
  let drToken = 0;

  function leaveDoctor() {
    drToken++;
    dr = null;
    view = 'overview';
    draw();
  }

  function trackView(running) {
    const track = h('div', { cls: 'track' + (running ? '' : ' inspected'), attrs: { role: 'img', 'aria-label': running ? 'inspecting' : 'inspected' } },
      h('div', { cls: 'say', text: running ? 'inspecting…' : 'inspected' }));
    for (const [left, height] of [[15, 10], [30, 6], [45, 10], [60, 6], [75, 10]]) {
      const tick = h('i', { cls: 'tick' });
      tick.style.left = left + '%';
      tick.style.height = height + 'px';
      track.append(tick);
    }
    track.append(h('div', { cls: 'ground' }), A.runner());
    return track;
  }

  function doctorRow(r) {
    const row = h('div', { cls: 'drow' }, span('mark ' + r.tone, r.mark), h('div', { cls: 'dtext' },
      h('div', { cls: 'small wordy' }, r.label, r.detail ? ' ' : null, r.detail ? span('muted', r.detail) : null)));
    const body = row.lastChild;
    for (const n of r.notes) body.append(h('div', { cls: 'small muted wordy', text: n }));
    if (r.fix) body.append(h('div', { cls: 'small wordy dfix' }, span('label', 'fix'), ' ', span(r.auto ? 'mono' : 'mono muted', r.fix)));
    return row;
  }

  function doctorSection(sec) {
    const col = h('div', { cls: 'col dsec', attrs: { 'data-section': sec.id } }, h('div', { cls: 'label', text: sec.title }));
    for (const r of sec.rows) col.append(doctorRow(r));
    for (const line of sec.info) col.append(h('div', { cls: 'small muted wordy', text: line }));
    return col;
  }

  // What Fix what it can will append, shown before it does. Nothing is written until Append is pressed.
  function planCard(fix) {
    const card = h('div', { cls: 'plan col', attrs: { role: 'group', 'aria-label': 'What Fix what it can will append' } },
      h('div', { cls: 'label', text: 'Will append' }));
    for (const f of fix.files) {
      card.append(h('div', { cls: 'col plancol' },
        h('div', { cls: 'mono small' }, f.file),
        h('pre', { cls: 'planlines', text: f.lines.join('\n') }),
        f.why ? h('div', { cls: 'small muted wordy', text: f.why }) : null));
    }
    card.append(h('div', { cls: 'small muted', text: fix.summary }));
    if (dr.fixError) card.append(h('pre', { cls: 'said err', text: dr.fixError.message }));
    card.append(h('div', { cls: 'row' },
      button(dr.fixing ? 'Appending…' : 'Append these lines', { cls: 'primary', tag: { cls: 'free', text: 'free' }, onClick: dr.fixing ? null : runFix, title: 'Appending…' }),
      button('Cancel', { cls: 'quiet', onClick: () => { if (!dr.fixing) { dr.planOpen = false; dr.fixError = null; draw(); } } })));
    return card;
  }

  function doctorView() {
    const back = button('Back', { cls: 'quiet', onClick: leaveDoctor });
    if (dr.state === 'error') return failureView(dr.error, openDoctor, back);
    const loading = dr.state === 'loading';
    const d = loading ? null : M.doctor(dr.doc);
    const head = h('div', { cls: 'row' },
      h('div', { cls: 'h2 grow' }, 'Site inspection ', span('free', 'free'), d && d.meta ? ' ' : null, d && d.meta ? span('mono small muted', d.meta) : null),
      span('small dim mono', loading ? 'reading…' : 'read ' + dr.at.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })),
      button('Run again', { onClick: loading ? null : openDoctor, title: 'Reading…' }),
      back);
    const main = h('main', { cls: 'main doctor' }, head, trackView(loading));
    if (loading) {
      main.append(h('div', { cls: 'small muted', text: 'foreman is looking over the machine and this repository. Nothing is sent and nothing is written.' }));
      return main;
    }

    const sheet = h('div', { cls: 'card col sheet' });
    const byId = Object.fromEntries(d.sections.map((x) => [x.id, x]));
    const top = [byId.machine, byId.repository].filter(Boolean);
    if (top.length) sheet.append(h('div', { cls: 'row top dtop' }, ...top.map((x) => h('div', { cls: 'grow col' }, doctorSection(x)))));
    for (const x of d.sections) if (x !== byId.machine && x !== byId.repository) sheet.append(doctorSection(x));

    if (dr.applied) sheet.append(h('div', { cls: 'applied small' }, span('ok', '■ '), dr.applied.text, ' ', span('muted', dr.applied.then)));
    if (dr.planOpen && d.fix) sheet.append(planCard(d.fix));

    const stamp = h('div', { cls: 'stamp ' + d.stamp.tone, attrs: { 'aria-label': `${d.stamp.label}: ${d.stamp.detail}` } },
      h('div', { cls: 'word', text: d.stamp.label }), h('div', { cls: 'sub', text: d.stamp.detail }));
    const legend = h('div', { cls: 'small muted legend' });
    d.legend.forEach((l, i) => legend.append(span('', i ? '   ' : ''), span(l.tone, l.mark), ' ' + l.text));
    const foot = h('div', { cls: 'col grow dfoot' }, legend);
    if (d.next) foot.append(h('div', { cls: 'mono small' }, span('muted', d.next.label), ' ' + d.next.command));
    if (d.fix && !dr.planOpen) {
      foot.append(button('Fix what it can…', { cls: 'dfixbtn', tag: { cls: 'free', text: 'free' }, onClick: () => { dr.planOpen = true; dr.fixError = null; draw(); } }));
    }
    sheet.append(h('div', { cls: 'row dbottom' }, foot, stamp));
    main.append(sheet);
    return main;
  }

  // Read the sheet. `applied` is what a fix just appended, kept across the read that follows it.
  async function openDoctor(applied = null) {
    if (!applied || typeof applied.text !== 'string') applied = null;
    dryToken++; dry = null; rep = null; tp = null;
    const token = ++drToken;
    view = 'doctor';
    dr = { state: 'loading', doc: null, error: null, at: null, planOpen: false, fixing: false, fixError: null, applied: applied && applied.text ? applied : null };
    draw();
    let answer;
    try {
      answer = await api.doctor();
    } catch (e) {
      answer = { ok: false, error: asError(e) };
    }
    if (token !== drToken) return;
    if (answer && answer.ok) { dr.state = 'ready'; dr.doc = answer.doc; dr.at = new Date(); }
    else { dr.state = 'error'; dr.error = (answer && answer.error) || { kind: 'spawn', message: 'No answer.' }; }
    draw();
  }

  // Fix what it can, once the person has seen what it will append: the CLI appends, and the sheet is
  // read again so what is shown is what is on disk now.
  async function runFix() {
    const mine = dr;
    if (!mine || mine.fixing) return;
    const token = drToken;
    mine.fixing = true;
    mine.fixError = null;
    draw();
    let answer;
    try {
      answer = await api.doctorFix();
    } catch (e) {
      answer = { ok: false, error: asError(e) };
    }
    if (token !== drToken || dr !== mine) return;
    mine.fixing = false;
    if (answer && answer.ok) {
      const done = M.doctor(answer.doc).applied;
      await openDoctor(done);
    } else {
      mine.fixError = (answer && answer.error) || { kind: 'spawn', message: 'No answer.' };
      draw();
    }
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
    dryToken++; dry = null; rep = null; drToken++; dr = null;
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
      t.editor.addEventListener('keydown', (e) => {
        if ((e.ctrlKey || e.metaKey) && String(e.key).toLowerCase() === 's' && tp === t && t.ui && !t.ui.save.disabled) {
          e.preventDefault();
          saveHandoff(t.base);
        }
      });
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

  // ---- starting a run: the confirmation (design 03, take c) ----

  const RP = window.ForemanRunPlan;
  const RV = window.ForemanRunView;
  const RE = window.ForemanRunEnd;

  // The confirmation is one question asked of one batch. Its facts are read when it opens (`dry-run
  // --json`, foreman.conf, whether the control directory is ignored); what the person types is kept here,
  // for this one confirmation, and is gone when it closes: nothing is remembered, nothing is written. The
  // three inputs are kept for as long as it is open, so a redraw never takes the caret or the focus.
  let cf = null;             // { batch, resume, state: 'loading' | 'ready' | 'error', facts, edits, more, help, error, starting, startError, inputs, token }
  let cfToken = 0;

  function closeConfirm() {
    cfToken++;
    cf = null;
    draw();
  }

  async function openConfirm(opts) {
    const batch = data && data.selected;
    if (!batch || cf) return;
    const token = ++cfToken;
    cf = { batch, resume: !!(opts && opts.resume), state: 'loading', facts: null, edits: null, more: false, help: null, focusOpened: null, refocus: null, error: null, starting: false, startError: null, inputs: null, token };
    draw();
    let answer;
    try { answer = await api.runConfirm(batch); } catch (e) { answer = { ok: false, error: asError(e) }; }
    if (!cf || cf.token !== token) return;
    if (answer && answer.ok) {
      cf.facts = answer.doc;
      cf.edits = RP.start(answer.doc);
      cf.state = 'ready';
      cf.inputs = makeInputs();
    } else {
      cf.state = 'error';
      cf.error = (answer && answer.error) || { kind: 'spawn', message: 'No answer.' };
    }
    draw();
  }

  function makeInputs() {
    const mk = (key, label, value) => {
      const i = h('input', { attrs: { type: 'text', inputmode: key === 'iterations' ? 'numeric' : 'decimal', autocomplete: 'off', spellcheck: 'false', 'aria-label': label, 'data-field': key } });
      i.value = value;
      i.addEventListener('input', () => { cf.edits[key] = i.value; draw(); });
      return i;
    };
    const f = cf.facts.dry.settings.budgets;
    return {
      iterations: mk('iterations', 'Iterations', cf.edits.iterations === 'unlimited' ? '' : cf.edits.iterations),
      cost: mk('cost', 'Spend cap in dollars', f.cost_usd ? Number(f.cost_usd).toFixed(2) : ''),
      minutes: mk('minutes', 'Time cap in minutes', f.minutes ? String(f.minutes) : ''),
    };
  }

  // Put a cap back to what the file says: no edit, and the field shows the file's value again.
  function resetCap(key) {
    cf.edits[key] = null;
    const f = cf.facts.dry.settings.budgets;
    cf.inputs[key].value = key === 'cost' ? (f.cost_usd ? Number(f.cost_usd).toFixed(2) : '') : (f.minutes ? String(f.minutes) : '');
    draw();
  }

  function stepIterations(by) {
    const cur = RP.checkIterations(cf.edits.iterations);
    const n = cur.ok && cur.value !== null ? cur.value : 1;
    const next = Math.min(RP.MAX_ITERATIONS, Math.max(1, n + by));
    cf.edits.iterations = String(next);
    cf.inputs.iterations.value = String(next);
    draw();
  }

  function setUnlimited(on) {
    cf.edits.iterations = on ? 'unlimited' : '1';
    cf.inputs.iterations.value = on ? '' : '1';
    draw();
  }

  // A ? beside a field: a plain-text popover on click or keyboard focus. Esc or a click elsewhere closes it.
  function helpButton(key) {
    const open = cf.help === key;
    const b = h('button', { cls: 'help' + (open ? ' open' : ''), text: '?', attrs: { type: 'button', 'aria-label': 'What ' + key + ' means', 'aria-expanded': open ? 'true' : 'false', 'data-help': key } });
    b.addEventListener('focus', () => { if (cf && cf.help !== key) { cf.help = key; cf.focusOpened = key; cf.refocus = key; draw(); } });
    b.addEventListener('click', () => {
      if (!cf) return;
      if (cf.focusOpened === key) { cf.focusOpened = null; return; }      // the click that came with the focus
      cf.help = cf.help === key ? null : key;
      cf.refocus = key;
      draw();
    });
    const wrap = h('span', { cls: 'helpwrap' }, b);
    if (open) {
      const t = RP.HELP[key];
      const pop = h('div', { cls: 'pop', attrs: { role: 'tooltip', 'data-pop': key } }, h('b', { text: t.title }), h('span', { text: t.body }));
      if (t.note) pop.append(h('span', { cls: 'dim', text: t.note }));
      wrap.append(pop);
    }
    return wrap;
  }

  function capTile(v, c, key, helpKey, label, unit) {
    const field = h('span', { cls: 'field' + (c.unset && !c.changed && !c.error ? ' none' : '') }, key === 'cost' ? span('', '$') : null, cf.inputs[key], unit ? h('small', { text: unit }) : null);
    cf.inputs[key].setAttribute('placeholder', 'none set');
    const tile = h('div', { cls: 'tile edit' + (c.error ? ' bad' : '') },
      h('div', { cls: 'lab' }, label, helpButton(helpKey)),
      h('div', { cls: 'row', attrs: { style: 'justify-content:center;margin-top:4px' } }, field));
    if (c.error) tile.append(h('div', { cls: 'fielderr', text: c.error, attrs: { role: 'alert' } }));
    if (c.changed || c.error) {
      const note = h('div', { cls: 'src' });
      if (c.changed) {
        note.append(span(c.rust ? 'rust' : 'acc', c.rust ? (c.value === 0 ? 'this run only · no cap' : 'this run only · above the file') : 'this run only'), ' · ');
      }
      note.append(h('button', { cls: 'linkish', text: 'reset: ' + c.reset, attrs: { type: 'button', 'data-reset': key }, on: { click: () => resetCap(key) } }));
      tile.append(note);
    }
    tile.append(h('div', { cls: 'src', text: c.name }));
    tile.append(h('div', { cls: 'src ' + (c.unset && !c.changed ? 'rust' : ''), text: c.unset ? 'none set · ' + c.source.text : (c.changed ? 'the file has ' + (c.reset) : c.source.text) }));
    return tile;
  }

  function confirmBody() {
    const c = cf;
    const v = RP.view(c.facts, c.edits, { resume: c.resume });
    const row = (label, helpKey, ...value) => h('div', { cls: 'line' },
      h('span', { cls: 'muted' }, label, helpKey ? helpButton(helpKey) : null), h('span', { cls: 'val' }, ...value));
    const box = h('div', { cls: 'bill', attrs: { role: 'dialog', 'aria-modal': 'true', 'aria-label': v.title } });
    box.append(
      h('div', { cls: 'row', attrs: { style: 'margin-bottom:8px' } }, h('span', { cls: 'label grow', text: v.title }), span('paid', 'costs money')),
      row('batch ', null, v.batch),
      row('starts at ', 'starts at', v.startsAt),
      row('can reach ', 'can reach', ...v.reach.map((p) => (p.tone ? span(p.tone, p.text) : p.text))),
      h('div', { cls: 'rule' }));

    // The one budget up front, and the one editable field.
    const it = v.iterations;
    c.inputs.iterations.hidden = it.unlimited;
    const stepper = h('div', { cls: 'row', attrs: { style: 'gap:6px;margin-left:auto' } },
      h('button', { cls: 'btn sq', text: '−', attrs: { type: 'button', 'aria-label': 'One fewer iteration', 'data-step': 'down' }, on: { click: () => stepIterations(-1) } }),
      h('span', { cls: 'field iters' }, it.unlimited ? h('b', { text: '∞', attrs: { style: 'padding:0 10px' } }) : null, c.inputs.iterations),
      h('button', { cls: 'btn sq', text: '+', attrs: { type: 'button', 'aria-label': 'One more iteration', 'data-step': 'up' }, on: { click: () => stepIterations(1) } }),
      h('button', { cls: 'btn quiet', text: it.unlimited ? 'set a number' : 'unlimited', attrs: { type: 'button', 'data-unlimited': 'toggle', style: 'padding:1px 6px;font-size:11px' }, on: { click: () => setUnlimited(!it.unlimited) } }));
    stepper.querySelector('[data-step="up"]').disabled = it.unlimited;
    box.append(h('div', { cls: 'tiles' }, h('div', { cls: 'tile edit wide' + (it.error ? ' bad' : '') },
      h('div', { cls: 'col', attrs: { style: 'gap:3px' } }, h('div', { cls: 'lab' }, 'iterations', helpButton('iterations')), h('div', { cls: 'src', text: 'argument · 1–∞' })), stepper)));
    if (it.error) box.append(h('div', { cls: 'fielderr', text: it.error, attrs: { role: 'alert' } }));

    // More settings: closed at first.
    box.append(h('div', { cls: 'moreline' },
      h('button', { cls: 'btn quiet', text: 'More settings ' + (c.more ? '▾' : '▸'), attrs: { type: 'button', 'aria-expanded': c.more ? 'true' : 'false', 'data-more': 'toggle' }, on: { click: () => { c.more = !c.more; draw(); } } }),
      span('dim small', c.more ? 'for this run only' : 'spend cap · time cap · live view · model')));
    if (c.more) {
      box.append(h('div', { cls: 'morepanel' },
        h('div', { cls: 'tiles' }, capTile(v, v.cost, 'cost', 'spend cap', 'spend cap', ''), capTile(v, v.minutes, 'minutes', 'time cap', 'time cap', 'min')),
        h('div', { cls: 'line', attrs: { style: 'margin-top:8px' } }, h('span', { cls: 'muted' }, 'live tool calls', helpButton('live tool calls')),
          h('label', { cls: 'checkbox' },
            (() => { const k = h('input', { attrs: { type: 'checkbox', 'data-field': 'live', 'aria-label': 'Live tool calls' } }); k.checked = v.live; k.addEventListener('change', () => { c.edits.live = !!k.checked; draw(); }); return k; })(),
            v.live ? 'on' : 'off')),
        h('div', { cls: 'line' }, h('span', { cls: 'muted' }, 'model', helpButton('model')), h('span', { cls: 'val' }, v.model + ' ', span('dim', v.modelSource))),
        h('div', { cls: 'small dim', attrs: { style: 'font-family:var(--ui);margin-top:4px' }, text: 'Changes here apply to this run only. foreman.conf is not edited, and the app remembers nothing.' })));
    }

    box.append(h('div', { cls: 'rule' }),
      row('runs ', 'runs', ...v.command.prefix.map((p) => span('acc', p + ' ')), v.command.text));
    box.append(h('div', { cls: 'small muted', attrs: { style: 'font-family:var(--ui);margin-top:8px' }, text: "The run stops at whichever budget comes first. You can add or take away iterations while it runs. Closing this window doesn't stop it." }));
    for (const w of v.warnings) box.append(h('pre', { cls: 'said', text: w }));
    if (v.blocked && v.blocked !== v.button) box.append(h('div', { cls: 'small rust', attrs: { style: 'margin-top:8px', role: 'status' }, text: v.blocked }));
    if (c.startError) box.append(h('pre', { cls: 'said err', text: c.startError.message }));
    const go = h('button', { cls: 'btn primary', text: c.starting ? 'Starting…' : v.button, attrs: { type: 'button', 'data-start': 'go' } });
    if (v.blocked || c.starting) { go.disabled = true; go.title = v.blocked || 'Starting…'; } else go.addEventListener('click', () => startRun(v));
    box.append(h('div', { cls: 'row', attrs: { style: 'margin-top:14px;justify-content:flex-end' } },
      h('button', { cls: 'btn', text: 'Cancel', attrs: { type: 'button' }, on: { click: () => { if (!c.starting) closeConfirm(); } } }), go));
    return box;
  }

  function confirmView() {
    const c = cf;
    const shell = (content) => h('div', {}, h('div', { cls: 'scrim' }), h('div', { cls: 'modal' }, content));
    const bill = (...kids) => h('div', { cls: 'bill' }, ...kids);
    if (c.state === 'loading') {
      return shell(bill(h('div', { cls: 'label', text: c.resume ? 'Resume a run' : 'Start a run' }), h('div', { cls: 'muted', text: 'Reading what a run would do. Nothing is sent.' }),
        h('div', { cls: 'row', attrs: { style: 'margin-top:12px;justify-content:flex-end' } }, button('Cancel', { onClick: closeConfirm }))));
    }
    if (c.state === 'error') {
      return shell(bill(h('div', { cls: 'label', text: 'Could not read what a run would do' }), h('pre', { cls: 'said', text: c.error.message }),
        h('div', { cls: 'row', attrs: { style: 'margin-top:12px;justify-content:flex-end' } }, button('Close', { onClick: closeConfirm }))));
    }
    return shell(confirmBody());
  }

  // The one place a run is started. What the person edited is sent as a request; main checks it again.
  async function startRun(v) {
    const c = cf;
    if (!c || c.starting || v.blocked) return;
    c.starting = true;
    c.startError = null;
    draw();
    let answer;
    try {
      answer = await api.runStart(c.batch, { iterations: v.plan.iterations, live: v.plan.live, caps: v.plan.caps });
    } catch (e) { answer = { ok: false, error: asError(e) }; }
    if (cf !== c) return;
    c.starting = false;
    if (answer && answer.ok) {
      const caps = { cost: v.cost.value > 0 ? v.cost.value : null, minutes: v.minutes.value > 0 ? v.minutes.value : null };
      cfToken++;
      cf = null;
      lv = newLive(c.batch);
      lv.before = data && data.status && data.status.last_run ? data.status.last_run.id : null;
      lv.starting = { command: answer.command || v.command.full };
      lv.caps = caps;
      view = 'live';
      dryToken++; dry = null; rep = null; tp = null; drToken++; dr = null;
    } else {
      c.startError = (answer && answer.error) || { message: 'No answer.' };
    }
    draw();
  }

  function insideClass(el, cls) {
    for (let e = el; e; e = e.parentElement || e.parent) {
      if (typeof e.className === 'string' && e.className.split(/\s+/).includes(cls)) return true;
    }
    return false;
  }

  // ---- the live run (design 04: take a, and c for the compact view) ----

  // batch is where the run is now (the loop renames a finished batch to DONE_), watched where the screen began;
  // runId the run on screen, once it has been seen in flight; before the last run the batch had when the app
  // started this one; exitInfo what the process the app started said; ended the scene (see "how a run ended").
  let lv = null;             // { batch, watched, run, runId, before, starting, exit, exitInfo, ended, compact, caps, notice, error, asking, busy }

  const newLive = (batch) => ({ batch, watched: batch, run: null, runId: null, before: null, starting: null, exit: null, exitInfo: null, ended: null, compact: false, caps: null, notice: null, error: null, asking: false, busy: false });

  function endLive() {
    const was = lv;
    lv = null;
    if (was && was.compact) { try { api.compact(false); } catch (e) { /* the window is going away */ } }
    if (view === 'live') view = 'overview';
  }

  function setCompact(on) {
    if (!lv) return;
    lv.compact = on;
    api.compact(on);
    draw();
  }

  // + - L: foreman keys; the bar shows what the control directory says afterwards.
  async function pressKey(key) {
    const l = lv;
    if (!l || l.busy) return;
    l.busy = true; l.error = null; l.notice = null;
    draw();
    let answer;
    try { answer = await api.runKeys(l.batch, key); } catch (e) { answer = { ok: false, error: asError(e) }; }
    l.busy = false;
    if (lv !== l) return;
    if (answer && answer.ok) { if (answer.run) l.run = answer.run; } else l.error = ((answer && answer.error) || { message: 'No answer.' }).message;
    draw();
  }

  async function stopRun(now) {
    const l = lv;
    if (!l || l.busy) return;
    l.busy = true; l.error = null; l.asking = false;
    l.notice = now ? 'Stopping now…' : 'Stopping after this iteration…';
    draw();
    let answer;
    try { answer = await api.runStop(l.batch, now); } catch (e) { answer = { ok: false, error: asError(e) }; }
    l.busy = false;
    if (lv !== l) return;
    if (answer && answer.ok) l.notice = now ? 'Stopped.' : 'The run will stop after this iteration.';
    else { l.notice = null; l.error = ((answer && answer.error) || { message: 'No answer.' }).message; }
    draw();
  }

  function leaveLive() {
    const batch = lv ? lv.batch : null;
    endLive();
    if (batch) start(batch); else draw();
  }

  const viewSwitch = (compact) => {
    const pick = (label, on, go) => h('button', { cls: on ? 'on' : '', text: label, attrs: { type: 'button', 'aria-pressed': on ? 'true' : 'false' }, on: { click: () => { if (!on) go(); } } });
    return h('span', { cls: 'seg', attrs: { role: 'group', 'aria-label': 'View', title: compact ? 'Switch to the full view' : 'Switch to the compact view' } },
      pick('Full view', !compact, () => setCompact(false)), pick('Compact view', compact, () => setCompact(true)));
  };

  function liveRow(r) {
    if (r.kind === 'running') {
      const body = h('div', { attrs: { style: 'min-width:0' } }, h('div', { cls: 'slug', text: r.label }));
      if (r.feed.length) {
        const feed = h('div', { cls: 'feed', attrs: { 'data-feed': 'run' } });
        for (const f of r.feed) feed.append(h('div', { cls: 'ln' }, span('tm', f.tm), span('tool', f.tool.toLowerCase()), span('', f.text)));
        body.append(feed);
      } else if (r.activity) body.append(h('div', { cls: 'feed' }, h('div', { text: r.activity })));
      else if (r.feedOff) body.append(h('div', { cls: 'feed dim', text: 'live view is off · press L for the tool calls' }));
      return h('div', { cls: 't running', attrs: { 'data-row': 'running' } }, span('g acc spin', r.glyph), span('num', r.num), body, chip(r.chip), span('meta', r.meta));
    }
    return h('div', { cls: 't done', attrs: { 'data-row': 'done', title: r.flags.join(' · ') } }, span('g ' + r.tone, r.glyph), span('num', r.num), span('slug', r.label), chip(r.chip), span('meta', r.meta));
  }

  function runBar(s, l) {
    const off = !s.steerable || l.busy;
    const why = s.bar.disabledWhy;
    const key = (label, k, tip, disabled) => {
      const b = h('button', { cls: 'btn sq', text: label, attrs: { type: 'button', 'aria-label': tip, 'data-key': k }, on: { click: () => pressKey(k) } });
      if (off || disabled) { b.disabled = true; b.title = why || tip; }
      return b;
    };
    const meter = (m) => { const mt = h('span', { cls: 'meter' + (m.hot ? ' hot' : '') }, h('i')); mt.firstChild.style.width = Math.round(m.frac * 100) + '%'; return mt; };
    const live = h('button', { cls: 'btn', attrs: { type: 'button', 'data-key': 'L', 'aria-pressed': s.bar.live ? 'true' : 'false' }, on: { click: () => pressKey('L') } }, span('k', 'L'), ' Live ' + (s.bar.live ? 'on' : 'off'));
    const after = h('button', { cls: 'btn', text: 'Stop after this one', attrs: { type: 'button', title: 'Stop after this iteration', 'data-stop': 'after' }, on: { click: () => stopRun(false) } });
    const now = h('button', { cls: 'btn danger', text: 'Stop now…', attrs: { type: 'button', 'data-stop': 'now' }, on: { click: () => { l.asking = true; draw(); } } });
    for (const b of [live, after, now]) if (off) { b.disabled = true; b.title = why || b.title || ''; }
    const bar = h('div', { cls: 'runbar', attrs: { 'aria-label': 'Run controls' } },
      h('div', { cls: 'grp' }, span('label', 'Iteration'), h('b', { cls: 'mono', text: s.bar.iteration }), key('−', '-', 'One fewer iteration', s.bar.minusOff), key('+', '+', 'One more iteration', s.bar.plusOff)),
      h('div', { cls: 'grp stack' }, h('div', {}, span('label', 'Spent'), ' ', span('mono', s.bar.spent.text)), meter(s.bar.spent)),
      h('div', { cls: 'grp stack' }, h('div', {}, span('label', 'Time'), ' ', span('mono', s.bar.time.text)), meter(s.bar.time)),
      h('div', { cls: 'grp' }, live),
      h('div', { cls: 'grp', attrs: { style: 'margin-left:auto' } }, after, now));
    if (why) bar.append(h('div', { cls: 'small rust why', text: why }));
    return bar;
  }

  function stopAsk(l) {
    return h('div', { cls: 'card warm col ask', attrs: { role: 'alertdialog', 'aria-label': 'Stop now' } },
      h('div', { text: "Stop now? The ticket's uncommitted work is kept, and the next run reviews it." }),
      h('div', { cls: 'row' },
        h('button', { cls: 'btn danger', text: 'Stop now', attrs: { type: 'button', 'data-stop': 'confirm' }, on: { click: () => stopRun(true) } }),
        h('button', { cls: 'btn quiet', text: 'Keep running', attrs: { type: 'button' }, on: { click: () => { l.asking = false; draw(); } } })));
  }

  // The run's head: the dome, which run, where, how far, and a control at the top right.
  function liveHead(s, data, control) {
    return h('div', { cls: 'card row livehead' },
      A.dome({ w: 150, p: s.dome.p, stakes: M.overview(data.status).dome.stakes }),
      h('div', { cls: 'grow kv' },
        span('', 'Run'), span('', s.run.id + (s.run.startedAt ? ' · started ' + s.run.startedAt.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '')),
        span('', 'Batch'), span('', s.batchPath), span('', 'Done'), span('', s.done), span('', 'Elapsed'), span('', s.elapsed)),
      h('span', { attrs: { style: 'align-self:flex-start' } }, control));
  }

  function liveView(data) {
    const l = lv;
    if (l.ended) return endView(data);
    if (l.exit) {
      return paneView('The run ended before it began.', (l.exit.out || `foreman exited with ${l.exit.code}.`) + (l.exit.code !== null && l.exit.out ? `\n\n(exit ${l.exit.code})` : ''), button('Back', { onClick: leaveLive }));
    }
    if (!l.run) {
      return paneView('Starting the run…', (l.starting ? l.starting.command + '\n\n' : '') + 'foreman is getting ready. Closing this window does not stop it.', viewSwitch(false));
    }
    const s = RV.screen(l.run, { status: data.status, now: Date.now(), caps: l.caps });
    const note = (cls, text) => h('div', { cls: 'small ' + cls, text, attrs: { role: 'status' } });

    if (l.compact) {
      const c = s.compact;
      const meter = (m) => { const mt = h('span', { cls: 'meter grow' + (m.hot ? ' hot' : '') }, h('i')); mt.firstChild.style.width = Math.round(m.frac * 100) + '%'; return mt; };
      const off = !s.steerable || l.busy;
      const small = (label, k, tip, dis) => { const b = h('button', { cls: 'btn sq', text: label, attrs: { type: 'button', 'aria-label': tip, 'data-key': k }, on: { click: () => pressKey(k) } }); if (off || dis) { b.disabled = true; b.title = s.bar.disabledWhy || tip; } return b; };
      const after = h('button', { cls: 'btn', text: 'Stop after this one', attrs: { type: 'button', 'data-stop': 'after' }, on: { click: () => stopRun(false) } });
      if (off) { after.disabled = true; after.title = s.bar.disabledWhy || ''; }
      const card = h('div', { cls: 'card col compactcard', attrs: { 'data-view': 'compact' } },
        h('div', { cls: 'row', attrs: { style: 'align-items:flex-start' } }, A.dome({ w: 90, p: s.dome.p, stakes: '' }),
          h('div', { cls: 'grow' }, h('div', { cls: 'mono', text: s.batch }), h('div', { cls: 'small muted', text: c.progress })), viewSwitch(true)),
        h('div', { cls: 'mono small' }, span('acc', '⠹ '), c.line, c.activity ? h('div', { cls: 'muted', attrs: { style: 'padding-left:16px' }, text: c.activity }) : null),
        h('div', { cls: 'row small' }, span('label', 'Spent'), meter(s.bar.spent), span('mono', s.bar.spent.text.replace(' / ', '/'))),
        h('div', { cls: 'row small' }, span('label', 'Time'), meter(s.bar.time), span('mono', s.bar.time.text.replace(' / ', '/'))),
        l.error ? note('rust', l.error) : null, l.notice ? note('muted', l.notice) : null,
        h('div', { cls: 'row' }, small('−', '-', 'One fewer iteration', s.bar.minusOff), small('+', '+', 'One more iteration', s.bar.plusOff), h('span', { cls: 'grow' }), after));
      return h('main', { cls: 'main compact' }, card);
    }

    const head = liveHead(s, data, viewSwitch(false));
    const list = h('div', { cls: 'card flush tlist liverows', attrs: { 'aria-label': 'Iterations' } }, ...s.rows.map(liveRow));
    const main = h('main', { cls: 'main live' }, head, list);
    if (l.error) main.append(note('rust', l.error));
    if (l.notice) main.append(note('muted', l.notice));
    if (l.asking) main.append(stopAsk(l));
    main.append(runBar(s, l));
    return main;
  }

  // A file of the batch changed and the overview is read again: is a run in flight there? And if the run
  // that was on screen is not any more, how did it end?
  function syncLive(fresh) {
    const st = fresh && fresh.ok && fresh.status ? fresh.status : null;
    const inFlight = !!(st && st.run && st.run.in_flight);
    // The loop renamed the batch to DONE_ as the run ended: the screen goes with it.
    if (lv && fresh && fresh.ok && lv.batch !== fresh.selected && M.renamedTo(fresh.all, lv.batch) === fresh.selected) {
      lv.batch = fresh.selected;
      if (lv.ended) readEndRows(lv);
    }
    if (inFlight) {
      if (!lv || lv.batch !== fresh.selected || lv.ended) {
        lv = newLive(fresh.selected);
        lv.runId = st.run.id || null;
        const mine = lv;
        Promise.resolve(api.runLoad(fresh.selected)).then((ans) => {
          if (lv === mine && ans && ans.ok && ans.run) { mine.run = ans.run; draw(); }
        }, () => {});
        view = 'live';
      } else {
        lv.starting = null;
        lv.runId = st.run.id || lv.runId;
        if (view !== 'live' && view === 'overview') view = 'live';
      }
      return;
    }
    if (!st || !lv || lv.batch !== fresh.selected || lv.exit || lv.ended) return;
    if (lv.runId || lv.run) {                       // it was running, and its pid is gone: the scene
      beginEnd(lv);
      if (view === 'overview') view = 'live';
    }
    else if (!lv.starting) endLive();               // nothing was ever seen of it
  }

  // ---- how a run ended (design 05, take b1) ----
  //
  // The scene replaces the run's list in the same window, and the compact view is left. Which scene, and its
  // words and next steps, is runend.js's; this is the drawing and what the buttons do. Nothing here decides
  // how a run ended.

  function beginEnd(l) {
    if (l.ended) return;
    l.ended = { rows: null, state: 'loading', error: null, listing: false, token: 0 };
    l.asking = false; l.notice = null; l.error = null; l.busy = false;
    if (l.compact) { l.compact = false; try { api.compact(false); } catch (e) { /* the window is going away */ } }
    readEndRows(l);
  }

  // The run's iterations as the CLI words them: for the scene's numbers, and for Show iterations.
  async function readEndRows(l) {
    const e = l.ended;
    const mine = ++e.token;
    const last = data && data.status && data.status.last_run;
    const id = l.runId || (last ? last.id : null);
    let answer;
    if (!id) answer = { ok: false, error: { message: 'No run to read.' } };
    else {
      try { answer = await api.report(l.batch, { run: id }); } catch (x) { answer = { ok: false, error: asError(x) }; }
    }
    if (lv !== l || l.ended !== e || e.token !== mine) return;
    const rows = answer && answer.ok && answer.doc && answer.doc.run && Array.isArray(answer.doc.run.iterations) ? answer.doc.run.iterations : null;
    e.rows = rows || [];
    e.state = rows ? 'ready' : 'error';
    e.error = rows ? null : ((answer && answer.error) || { message: 'No answer.' }).message;
    draw();
  }

  function endModel(l, d) {
    const st = ST.choose(d);
    const login = st && st.id === 'login-expired' ? d.conditions.login : null;
    return RE.choose({ status: d.status, runId: l.runId, before: l.before, watched: l.watched, rows: l.ended.rows || [], exit: l.exitInfo, login });
  }

  async function openFileFromScene(file) {
    const l = lv;
    let said;
    try { said = await api.open(file); } catch (e) { said = asError(e).message; }
    if (said && lv === l) { l.error = said; draw(); }
  }

  // What each next step does. The ones that go to another screen leave the scene; Resume… keeps it under the
  // confirmation, so Cancel comes back to it.
  function endAction(a, l) {
    const go = {
      report: () => { endLive(); return openReport(); },
      'dry-run': () => { endLive(); return openDryRun(); },
      doctor: () => leaving(() => { endLive(); return openDoctor(); }),
      resume: () => openConfirm({ resume: true }),
      handoff: () => leaving(() => { const name = ticketNameOf(a.file); endLive(); return openTicket(name); }),
      'open-file': () => openFileFromScene(a.file),
      'open-log': () => openFileFromScene(a.file),
      iterations: () => { l.ended.listing = true; draw(); },
    }[a.do];
    const quiet = a.do === 'iterations' || a.do === 'resume';       // the primary step, if the scene has one, is the one that stands out
    const b = button(a.label, { cls: a.primary ? 'primary' : quiet ? 'quiet' : '', tag: a.tag || null, onClick: () => { l.error = null; return go(); } });
    b.setAttribute('data-end-action', a.do);
    return b;
  }

  // The run's list again, from the record: no running row, no bar. "Back to the scene" leaves it.
  function endedList(l, d) {
    const e = l.ended;
    const prior = l.run && l.run.run ? l.run.run : {};
    const rows = e.rows || [];
    const ran = rows.reduce((m, r) => Math.max(m, r.kind === 'iteration' ? r.iteration || 0 : 0), 0);
    const last = d.status && d.status.last_run;
    const snap = {
      batch: l.batch, next: null, control: null, iterations: rows, iterationsError: e.error, caps: l.caps || { cost: null, minutes: null },
      run: { in_flight: false, id: l.runId || (last && last.id) || '', started_at: prior.started_at || (rows[0] && rows[0].started_at) || null, iteration: ran, budget: prior.budget, live: false, control_dir: null, pid: null },
    };
    const s = RV.screen(snap, { status: d.status, now: Date.now(), caps: l.caps, ended: true });
    const list = h('div', { cls: 'card flush tlist liverows', attrs: { 'aria-label': 'Iterations' } }, ...s.rows.map(liveRow));
    if (s.rows.length === 0) list.append(h('div', { cls: 't done' }, span('slug muted', e.state === 'loading' ? 'Reading the iterations…' : 'This run has no iterations in the record.')));
    const main = h('main', { cls: 'main live', attrs: { 'data-view': 'iterations' } }, liveHead(s, d, button('Back to the scene', { cls: 'quiet', onClick: () => { e.listing = false; draw(); } })), list);
    if (e.state === 'error' && e.error) main.append(h('div', { cls: 'small rust', text: e.error, attrs: { role: 'status' } }));
    return main;
  }

  function endView(d) {
    const l = lv;
    const e = l.ended;
    if (e.listing) return endedList(l, d);
    const m = endModel(l, d);
    const row = (actions) => h('div', { cls: 'row' }, ...actions.map((a) => endAction(a, l)));
    const note = l.error ? h('div', { cls: 'small rust', text: l.error, attrs: { role: 'alert' } }) : null;
    if (!m) {
      return h('main', { cls: 'main pane end', attrs: { 'data-end': 'reading' } }, h('div', { cls: 'h2', text: 'The run has ended.' }),
        h('div', { cls: 'sentence', text: 'Reading how it ended…' }), row([{ do: 'iterations', label: 'Show iterations' }]));
    }
    if (m.kind === 'text') {
      return h('main', { cls: 'main pane end', attrs: { 'data-end': 'text' } }, h('div', { cls: 'h1', text: m.heading }),
        h('pre', { cls: 'said', text: m.said }), row(m.actions), note,
        button('Back', { cls: 'quiet', onClick: leaveLive }));
    }
    if (m.login) {
      const state = ST.choose(d);
      return h('main', { cls: 'main pane end', attrs: { 'data-end': 'login-expired' } }, stateView(state), row(m.actions), note);
    }
    return h('main', { cls: 'main pane end', attrs: { 'data-end': m.scene } },
      h('div', { cls: 'cap', text: m.cap }),
      A.endScene({ kind: m.art.kind, flags: m.art.flags, w: 400 }),
      h('div', { cls: 'h2', text: m.heading }),
      m.facts ? h('div', { cls: 'facts', text: m.facts }) : null,
      m.sentence ? h('div', { cls: 'sentence', text: m.sentence }) : null,
      m.message ? h('pre', { cls: 'said', text: m.message }) : null,
      row(m.actions), note);
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
    const fieldFocus = cf && cf.inputs && document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.field : undefined;
    const fieldAt = fieldFocus && cf.inputs[fieldFocus] === document.activeElement ? { from: document.activeElement.selectionStart, to: document.activeElement.selectionEnd } : null;
    const ed = tp && tp.editor;
    const edAt = ed ? { focus: document.activeElement === ed, from: ed.selectionStart, to: ed.selectionEnd, top: ed.scrollTop } : null;
    app.replaceChildren();

    if (!data || !data.ok) {
      app.classList.add('solo');
      const stood = ST.choose(data);
      app.append(stood ? stateView(stood) : failureView(data ? data.error : { kind: 'spawn', message: 'Waiting for foreman…' }));
      document.title = 'Foreman';
      return;
    }
    if (view === 'live' && (!lv || lv.batch !== data.selected)) view = 'overview';
    const compactNow = view === 'live' && data.status && lv && lv.compact && lv.run && !lv.exit && !lv.ended;
    if (compactNow) app.classList.add('solo'); else app.classList.remove('solo');
    // The dry run, the report and a ticket's page are of the batch that was selected when they were asked for.
    if (view === 'dryrun' && (!dry || !data.status || dry.batch !== data.selected)) { dryToken++; view = 'overview'; dry = null; }
    if (view === 'report' && (!rep || rep.batch !== data.selected)) { view = 'overview'; rep = null; }
    if (view === 'doctor' && !dr) view = 'overview';
    if (view === 'ticket' && (!tp || tp.batch !== data.selected || !data.status)) { view = 'overview'; tp = null; }
    const rail = railView(data, (batch) => { if (!selecting) leaving(() => start(batch)); });
    if (!compactNow) app.append(rail);

    if (view === 'live' && data.status) {
      app.append(liveView(data));
      document.title = lv.ended ? 'Foreman — run ended · ' + String(lv.batch).split('/').pop() : 'Foreman — running ' + String(lv.batch).split('/').pop();
    } else if (view === 'doctor') {
      app.append(doctorView());
      document.title = 'Foreman — doctor';
    } else if (data.all.batches.length === 0) {
      app.append(stateView(ST.choose(data)));
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
      const stood = ST.choose(data);
      app.append(stood ? stateView(stood) : paneView('This batch cannot be read.', data.statusError || '', button('Try again', { onClick: () => start(data.selected) })));
      document.title = 'Foreman — ' + (data.selected || data.repoRoot);
    }

    if (cf) app.append(confirmView());
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
    // The confirmation's inputs live as long as it does: the caret goes back where it was, and so does
    // the focus on a ? that was just opened.
    if (fieldFocus && cf && cf.inputs && cf.inputs[fieldFocus] && cf.inputs[fieldFocus].isConnected !== false) {
      cf.inputs[fieldFocus].focus();
      if (fieldAt && typeof cf.inputs[fieldFocus].setSelectionRange === 'function') cf.inputs[fieldFocus].setSelectionRange(fieldAt.from, fieldAt.to);
    } else if (cf && cf.refocus) {
      const key = cf.refocus;
      cf.refocus = null;
      for (const b of app.querySelectorAll(`[data-help="${key}"]`)) b.focus();
    }
  }

  async function start(batch) {
    dryToken++; drToken++;
    view = 'overview';
    dry = null;
    dr = null;
    rep = null;
    tp = null;
    selecting = true;
    cfToken++; cf = null;
    try {
      data = await api.load(batch);
    } catch (e) {
      data = { ok: false, error: { kind: 'spawn', message: String(e && e.message ? e.message : e) } };
    } finally {
      selecting = false;
    }
    syncLive(data);
    draw();
  }

  // A file changed: the screen redraws from the new overview, and a ticket page reads its own files again.
  // Back from the person's own editor: read the page again. The watcher sees the batch's files; this
  // is for a handoff file kept elsewhere in the repository, and for an event that never came.
  if (typeof window.addEventListener === 'function') {
    window.addEventListener('focus', () => { if (view === 'ticket' && tp && tp.state !== 'loading') readTicket(); });
  }
  // Esc closes what is open on the confirmation: the popover first, then the confirmation itself. A click
  // anywhere that is not a ? or its popover closes the popover.
  if (typeof window.addEventListener === 'function') {
    window.addEventListener('keydown', (e) => {
      if (!cf || e.key !== 'Escape') return;
      if (cf.help) { cf.help = null; draw(); } else if (!cf.starting) closeConfirm();
    });
    window.addEventListener('click', (e) => {
      if (cf && cf.help && !insideClass(e.target, 'helpwrap')) { cf.help = null; draw(); }
    });
  }
  // A file of the run changed (its feed, its budget, the record): the live screen is rebuilt from what main read.
  if (typeof api.onRunUpdate === 'function') {
    api.onRunUpdate((u) => {
      if (!u || !lv || lv.batch !== u.batch) return;
      if (u.run && !lv.ended) { lv.run = u.run; lv.starting = null; if (u.run.run && u.run.run.id) lv.runId = u.run.run.id; draw(); }
    });
  }
  // A run the app started has ended. Its status is read again, and if the log has an ending that is new since
  // the app started it, that is the scene. If it never reached "in flight" and left no ending, that was a
  // preflight failure, and its own words are what the person needs.
  if (typeof api.onRunExit === 'function') {
    api.onRunExit(async (x) => {
      const l = lv;
      if (!x || !l || l.watched !== x.batch) return;
      l.exitInfo = { code: x.code, out: x.out || '' };
      if (l.ended) { draw(); return; }
      let fresh = null;
      try { fresh = await api.load(l.batch); } catch (e) { fresh = null; }
      if (lv !== l) return;
      if (fresh && fresh.ok) { data = fresh; syncLive(fresh); }
      if (lv === l && !l.ended && !l.exit) {
        const told = fresh && fresh.ok && fresh.status
          && RE.choose({ status: fresh.status, runId: l.runId, before: l.before, watched: l.watched, rows: [], exit: l.exitInfo, login: null });
        if (told) beginEnd(l);
        else if (!l.runId && !l.run) {
          l.starting = null;
          l.exit = { code: x.code, out: x.out || '' };
          if (l.compact) { l.compact = false; api.compact(false); }
        }
      }
      draw();
    });
  }
  api.onUpdate((fresh) => {
    data = fresh;
    syncLive(fresh);
    // Not while the inspector is running: building the track again would start the run over.
    if (!(view === 'doctor' && dr && dr.state === 'loading')) draw();
    if (view === 'ticket' && tp && fresh && fresh.ok && fresh.selected === tp.batch) readTicket();
  });
  start(null);
}());
