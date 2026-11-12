// Foreman GUI design canvases. Clones each <template data-take> into a dark and a light frame,
// fills the shared parts (title bar, rail) and draws the art from data attributes:
//   <span data-art="dome" data-stakes="dddd>..hf.." data-w="260">   the sunrise dome over the stake line
//   <span data-art="inspector" data-w="90">                          the inspector (doctor)
//   <span data-art="figure" data-w="70">                             the foreman (run)
//   <span data-art="sunrise" data-p="0.4">                           a sunrise band (p = how high the sun is)
// Stakes: d landed · > next · h human ticket · f followup · . to go · x missing.
// Local file, no network, no dependencies.
(function () {
  const NS = 'http://www.w3.org/2000/svg';
  const svg = (w, h, vb, body) => `<svg xmlns="${NS}" width="${w}" height="${h}" viewBox="${vb}" aria-hidden="true">${body}</svg>`;
  let uid = 0;

  function dome(el) {
    const stakes = (el.dataset.stakes || 'dddd>.h f..').replace(/ /g, '');
    const n = stakes.length, done = (stakes.match(/d/g) || []).length;
    const p = el.dataset.p !== undefined ? +el.dataset.p : done / n;
    const w = +el.dataset.w || 240, h = Math.round(w * 0.62), id = 'd' + (++uid);
    const cy = 112 - p * 74;                       // sun climbs from the horizon to the top of the dome
    const rays = p >= 1 ? [...Array(9)].map((_, i) => {
      const a = Math.PI * (i + 1) / 10, x1 = 100 - Math.cos(a) * 34, y1 = cy - Math.sin(a) * 34, x2 = 100 - Math.cos(a) * 46, y2 = cy - Math.sin(a) * 46;
      return `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" style="stroke:var(--sunfill)" stroke-width="3" stroke-linecap="round"/>`; }).join('') : '';
    let st = '';
    const x0 = 22, x1 = 178, step = n > 1 ? (x1 - x0) / (n - 1) : 0;
    [...stakes].forEach((c, i) => {
      const x = x0 + i * step;
      const col = c === 'd' ? 'var(--amber)' : c === '>' ? 'var(--sunfill)' : c === 'h' ? 'var(--rust)' : c === 'x' ? 'var(--err)' : 'var(--dim)';
      const tall = c === '>' ? 15 : 10;
      st += `<rect x="${x - 1.6}" y="${108}" width="3.2" height="${tall}" rx="1" style="fill:${col}"/>`;
      if (c === 'h') st += `<path d="M${x + 1.6} 108 l8 3 l-8 3z" style="fill:var(--rust)"/>`;
      if (c === '>') st += `<circle cx="${x}" cy="${106}" r="2.6" style="fill:var(--sunfill)"/>`;
      if (c === 'f') st += `<circle cx="${x}" cy="${120}" r="1.6" style="fill:var(--muted)"/>`;
    });
    el.innerHTML = svg(w, h, '0 0 200 124', `
      <defs><linearGradient id="${id}g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" style="stop-color:var(--sky-top)"/><stop offset="1" style="stop-color:var(--sky-bot)"/></linearGradient>
      <clipPath id="${id}c"><path d="M14 104 A86 86 0 0 1 186 104 Z"/></clipPath></defs>
      <path d="M14 104 A86 86 0 0 1 186 104 Z" fill="url(#${id}g)"/>
      <g clip-path="url(#${id}c)"><circle cx="100" cy="${cy}" r="40" style="fill:var(--halo)" opacity=".22"/><circle cx="100" cy="${cy}" r="27" style="fill:var(--sunfill)"/>${rays}</g>
      <path d="M14 104 A86 86 0 0 1 186 104" fill="none" style="stroke:var(--post)" stroke-width="2.4"/>
      <path d="M40 104 A60 60 0 0 1 160 104" fill="none" style="stroke:var(--post)" stroke-width="1" opacity=".35" stroke-dasharray="3 5"/>
      <rect x="4" y="104" width="192" height="3" rx="1.5" style="fill:var(--earth)"/>${st}`);
  }

  function sunrise(el) {
    const p = +(el.dataset.p || 0.35), cy = 110 - p * 80;
    el.innerHTML = svg('100%', '100%', '0 0 1000 92" preserveAspectRatio="xMinYMax slice', `
      <circle cx="120" cy="${cy}" r="60" style="fill:var(--halo)" opacity=".25"/><circle cx="120" cy="${cy}" r="40" style="fill:var(--sunfill)"/>
      <rect x="0" y="80" width="1000" height="12" style="fill:var(--ground)"/>
      ${[...Array(24)].map((_, i) => `<rect x="${300 + i * 28}" y="${i % 6 === 0 ? 66 : 72}" width="3" height="${i % 6 === 0 ? 14 : 8}" style="fill:var(--post)" opacity=".7"/>`).join('')}`);
  }

  function person(el, kind) {
    const w = +el.dataset.w || 80, h = Math.round(w * 1.5);
    const board = kind === 'inspector'
      ? `<rect x="46" y="54" width="22" height="30" rx="2" style="fill:var(--panel);stroke:var(--post)" stroke-width="2"/><rect x="51" y="51" width="12" height="5" rx="1" style="fill:var(--post)"/>
         <path d="M51 63 h12 M51 69 h12 M51 75 h8" style="stroke:var(--muted)" stroke-width="1.6"/>`
      : `<rect x="58" y="40" width="4" height="74" rx="1.5" style="fill:var(--post)"/><path d="M62 42 l14 6 l-14 6z" style="fill:var(--rust)"/>`;
    const sign = el.dataset.sign === 'stop' ? `<rect x="2" y="2" width="30" height="20" rx="3" style="fill:var(--err)"/><text x="17" y="16" text-anchor="middle" font-size="9" font-family="Consolas,monospace" font-weight="700" style="fill:var(--panel)">FIX</text>`
             : el.dataset.sign === 'ok' ? `<circle cx="16" cy="13" r="11" style="fill:var(--ok)"/><path d="M10 13 l4 4 l8 -8" fill="none" style="stroke:var(--panel)" stroke-width="2.6"/>` : '';
    el.innerHTML = svg(w, h, '0 0 80 120', `${sign}
      <path d="M22 30 a14 14 0 0 1 28 0z" style="fill:var(--amber)"/><rect x="18" y="29" width="36" height="4" rx="2" style="fill:var(--amber)"/>
      <circle cx="36" cy="40" r="9" style="fill:var(--sun)"/>
      <path d="M22 54 q14 -6 28 0 l4 34 h-36z" style="fill:var(--rust)"/><path d="M30 52 h12 v36 h-12z" style="fill:var(--amber)" opacity=".85"/>
      <path d="M24 88 l-2 28 h8 l4 -24 l4 24 h8 l-2 -28z" style="fill:var(--earth)"/>
      <path d="M50 58 l10 8" style="stroke:var(--rust)" stroke-width="6" stroke-linecap="round"/>${board}
      <rect x="0" y="116" width="80" height="3" rx="1.5" style="fill:var(--earth)"/>`);
  }

  const RAIL = (on, running) => `
    <div class="mark"><span data-art="dome" data-w="34" data-stakes="dddd>.hf.."></span><div><b>FOREMAN</b><small>~/projects/app</small></div></div>
    <div class="label" style="padding:0 8px 4px">Batches</div>
    <div class="item ${on === 'human' ? 'on' : ''}">${running ? '<span class="dot"></span>' : ''}<span class="mono">human-tickets</span><span class="n">4/10</span></div><div class="mini"><i style="width:40%"></i></div>
    <div class="item ${on === 'gui' ? 'on' : ''}"><span class="mono">gui</span><span class="n">0/14</span></div><div class="mini"><i style="width:0"></i></div>
    <div class="item done"><span class="mono">DONE_terminal-design</span><span class="n">✓</span></div>
    <div class="spacer"></div>
    <div class="label" style="padding:0 8px 4px">Tools</div>
    <div class="item ${on === 'doctor' ? 'on' : ''}">Doctor <span class="free" style="margin-left:auto">free</span></div>
    <div class="item ${on === 'report' ? 'on' : ''}">Report <span class="free" style="margin-left:auto">free</span></div>
    <div class="foot">${running ? 'run 20261021-2 in flight' : 'no run in flight'}<br>read from disk · 14:07</div>`;

  function fill(root) {
    root.querySelectorAll('[data-part=titlebar]').forEach(el => {
      el.classList.add('titlebar');
      el.innerHTML = `<span data-art="dome" data-w="18" data-stakes="dd>."></span><span>${el.dataset.title || 'Foreman — .scratch/human-tickets'}</span><span class="wc"><span>—</span><span>☐</span><span>✕</span></span>`;
    });
    root.querySelectorAll('[data-part=rail]').forEach(el => { el.classList.add('rail'); el.innerHTML = RAIL(el.dataset.on || 'human', el.dataset.running === '1'); });
    root.querySelectorAll('[data-art=dome]').forEach(dome);
    root.querySelectorAll('[data-art=sunrise]').forEach(sunrise);
    root.querySelectorAll('[data-art=inspector]').forEach(el => person(el, 'inspector'));
    root.querySelectorAll('[data-art=figure]').forEach(el => person(el, 'figure'));
  }

  function build() {
    const pick = (document.querySelector('[data-pick]') || {}).dataset?.pick;
    document.querySelectorAll('template[data-take]').forEach(t => {
      const sec = document.createElement('section'); sec.className = 'take';
      const take = t.dataset.take;
      sec.innerHTML = `<h2>${take} · ${t.dataset.title}${pick && (take.match(/^[a-z]+/) || [])[0] === pick ? '<span class="badge">PICK</span>' : ''}</h2><p></p><div class="frames"></div>`;
      sec.querySelector('p').textContent = t.dataset.note || '';
      const themes = (t.dataset.themes || 'dark light').split(' ');
      themes.forEach(th => {
        const wrap = document.createElement('div'); wrap.className = 'frame-wrap';
        wrap.innerHTML = `<div class="cap">${take} · ${th}</div>`;
        const f = document.createElement('div'); f.className = `frame ${t.dataset.frame || ''} theme-${th}`;
        f.appendChild(t.content.cloneNode(true)); fill(f);
        wrap.appendChild(f); sec.querySelector('.frames').appendChild(wrap);
      });
      t.after(sec);
    });
    document.querySelectorAll('header.top [data-art]').forEach(() => fill(document.querySelector('header.top')));
  }
  document.readyState === 'loading' ? document.addEventListener('DOMContentLoaded', build) : build();
})();
