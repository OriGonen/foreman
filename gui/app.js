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
    const entries = M.rail(data.all, data.selected);
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
    const read = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    rail.append(h('div', { cls: 'spacer' }), h('div', { cls: 'foot', text: 'read from disk · ' + read }));
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
      button('Dry run', { tag: { cls: 'free', text: 'free' } }),
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

  function failureView(error) {
    const tried = Array.isArray(error.tried) && error.tried.length ? '\n\nLooked at, in order:\n  ' + error.tried.join('\n  ') : '';
    const sentence = {
      'git-bash-missing': 'Git Bash was not found.',
      'not-a-repo': 'This folder is not a git repository.',
      spawn: 'foreman could not be started.',
      exit: 'foreman reported a problem.',
      parse: 'foreman answered with something this app cannot read.',
      version: 'foreman and this app do not match.',
    }[error.kind] || 'Something went wrong.';
    return paneView(sentence, error.message + tried, button('Try again', { onClick: () => start(null) }));
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
    const rail = railView(data, (batch) => { if (!selecting) start(batch); });
    app.append(rail);

    if (data.all.batches.length === 0) {
      app.append(paneView('No batch here.', 'A batch is a directory with a foreman.conf in it.\n' + data.repoRoot));
      document.title = 'Foreman — ' + data.repoRoot;
    } else if (data.status) {
      app.append(overviewView(data));
      document.title = 'Foreman — ' + data.status.batch.path;
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
