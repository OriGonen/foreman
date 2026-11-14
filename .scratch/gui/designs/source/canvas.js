// Foreman GUI design canvases. Clones each <template data-take> into a dark and a light frame,
// fills the shared parts (title bar, rail) and draws the art from data attributes:
//   <span data-art="dome" data-stakes="dddd>..hf.." data-w="260">   the sunrise dome over the stake line
//   <span data-art="inspector" data-w="90">                          the inspector (doctor)
//   <span data-art="figure" data-w="70">                             the foreman (run)
//   <span data-art="sunrise" data-p="0.4">                           a sunrise band (p = how high the sun is)
//   <span data-art="runner">                                         the doctor's inspector, running across and back, sweating (CSS animation)
//   <span data-art="end" data-kind="done|paused|problem|human" data-w="400">
//                                                                    the run-end scenes as silhouettes: a big banded sun on a low horizon, the terminal's pixel foreman a flat dark shape in front of it
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


  // shared by the runner (OUT) and the end scenes' signs (HAND)
  const OUT = 'stroke:var(--outline);stroke-width:1.3;stroke-linejoin:round;stroke-linecap:round';
  const HAND = "'Segoe Print','Bradley Hand','Chalkboard SE','Comic Sans MS',cursive";
  // ---- run-end scenes, the silhouette world (05). Drawn like the terminal's sunrise in lib/foreman-draw.cjs:
  // a big sun in flat bands (sun, amber, rust, then two rings) sitting on a low horizon, its glint on the
  // ground below, and the foreman as one flat dark shape in front of it: no face, no colour, no detail.
  // 320 x 170, horizon at y = 148. The sun is the same in every scene but for its height, and exit 30's
  // sun is drawn exactly as exit 10's. The figure is the terminal's half-block
  // sprite, picked at the second sign-off. The pose carries the meaning.
  const EH = 148, ESUN = { cx: 160, r: 70 };
  const ESUN_Y = { done: EH - 68, paused: EH, human: EH, problem: EH + 8 };
  const EPOSE = { done: 'raise', paused: 'hold', problem: 'scratch', human: 'shrug' };
  const EAT = { done: 160, paused: 144, problem: 136, human: 190 };      // where the foreman stands

  function endSun(cx, cy, r, id) {
    const glow = `<radialGradient id="${id}g"><stop offset=".3" style="stop-color:var(--sun-mid);stop-opacity:var(--glow)"/><stop offset="1" style="stop-color:var(--sun-mid);stop-opacity:0"/></radialGradient>`;
    return `<defs>${glow}</defs><circle cx="${cx}" cy="${cy}" r="${(r * 2.2).toFixed(1)}" fill="url(#${id}g)"/>` + [[r + 10, '--sun-ring2'], [r + 5, '--sun-ring1'], [r, '--sun-rim'], [r * .84, '--sun-mid'], [r * .56, '--sun-core']]
      .map(([rr, c]) => `<circle cx="${cx}" cy="${cy}" r="${rr.toFixed(1)}" style="fill:var(${c})"/>`).join('');
  }

  // the ground: a band that fades down and out to the sides, a hard horizon, and the sun's glint under it
  function endGround(id, cx, cy, r) {
    const half = cy <= EH - r ? r * .72 : Math.sqrt(Math.max(0, r * r - (EH - cy) ** 2));
    const glint = [0, 1, 2, 3].map(k => { const w = half * (1 - k * .23), y = EH + 4 + k * 5;
      return `<line x1="${(cx - w).toFixed(1)}" x2="${(cx + w).toFixed(1)}" y1="${y}" y2="${y}" style="stroke:var(--glint)" stroke-width="1.7" stroke-linecap="round" opacity="${(.95 - k * .22).toFixed(2)}"/>`; }).join('');
    return `<defs><linearGradient id="${id}v" x1="0" y1="0" x2="0" y2="1"><stop offset="0" style="stop-color:var(--night)"/><stop offset="1" style="stop-color:var(--night);stop-opacity:0"/></linearGradient>
      <linearGradient id="${id}h" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#000"/><stop offset=".18" stop-color="#fff"/><stop offset=".82" stop-color="#fff"/><stop offset="1" stop-color="#000"/></linearGradient>
      <mask id="${id}m" maskUnits="userSpaceOnUse" x="0" y="0" width="320" height="170"><rect x="0" y="0" width="320" height="170" fill="url(#${id}h)"/></mask></defs>
      <g mask="url(#${id}m)"><rect x="0" y="${EH}" width="320" height="${170 - EH}" fill="url(#${id}v)"/><rect x="0" y="${EH - .6}" width="320" height="1.5" style="fill:var(--sil)"/></g>${glint}`;
  }

  const SIL = 'var(--sil)';
  // The figure (picked at the second sign-off, Option 1): the terminal's foreman (FIGURE_TOP + FIGURE_LEGS in foreman-draw.cjs, 18 x 25 cells), his
  // left arm taken off so each pose can put both arms where it needs them. [column, row] cells.
  const PX_BODY = ['.......####.......', '......######......', '.....########.....', '..##############..', '......######......', '......######......',
    '.......####.......', '.......####.......', '.....########.....', '....##########....', '...###########....', '...###########....', '...###########....',
    '.....#########....', '.....#########....', '.....#########....', '.....#########....', '.....#########....', '.....#########....',
    '.....####.####....', '.....####..####...', '.....###....###...', '.....###....###...', '.....###.....###..', '....####.....####.'];
  const pxRun = (x, y, n) => [...Array(n)].map((_, i) => [x + i, y]);
  const PX_HIP = [[2, 12], [2, 13], [1, 13], [1, 14], [2, 14], [1, 15], [2, 15], [2, 16], [3, 16], [3, 17], [4, 17]];
  const PX_ARMS = {
    raise: PX_HIP.concat([[14, 10], [14, 9], [15, 9], [15, 8], [15, 7], [16, 7], [15, 6], [16, 6], [16, 5], [16, 4], [17, 4], [16, 3], [17, 3], [16, 2], [17, 2]],
      pxRun(15, -1, 3), pxRun(15, 0, 3), pxRun(15, 1, 3)),
    hold: PX_HIP.concat(pxRun(14, 10, 6), pxRun(14, 11, 6), [[20, 5], [21, 5]], pxRun(20, 6, 2), pxRun(20, 7, 2), pxRun(20, 8, 2), pxRun(20, 9, 2), pxRun(20, 10, 2), pxRun(20, 11, 2), [[19, 9], [19, 10]]),
    scratch: PX_HIP.concat([[14, 10], [14, 9], [15, 9], [15, 8], [16, 8], [16, 7], [17, 7], [17, 6], [16, 6], [17, 5], [16, 5], [15, 5], [15, 4], [14, 4], [14, 5], [13, 4], [13, 5], [12, 4], [12, 5]]),
    shrug: (() => { const l = [[3, 12], [2, 12], [2, 13], [1, 13], [1, 14], [2, 14], [1, 15], [0, 15], [0, 14], [-1, 14], [-1, 13], [-2, 13], [-2, 12], [-3, 12], [-4, 12], [-4, 11], [-3, 11]];
      return l.concat(l.map(([x, y]) => [17 - x, y])); })(),
  };
  function figPixel(pose) {
    const cells = [];
    PX_BODY.forEach((row, j) => [...row].forEach((ch, i) => { if (ch === '#') cells.push([i, j]); }));
    cells.push(...PX_ARMS[pose]);
    return `<path d="${cells.map(([i, j]) => `M${i} ${j}h1.04v1.04h-1.04z`).join('')}" shape-rendering="crispEdges"/>`;
  }

  function endFigure(pose, x) {
    const c = 1.72;
    return `<g transform="translate(${(x - 8.8 * c).toFixed(2)} ${(EH - 25 * c).toFixed(2)}) scale(${c})" style="fill:${SIL}">${figPixel(pose)}</g>`;
  }

  // The two hand-lettered signs, as silhouettes: a dark post and board leaning off square, the letters
  // painted on in the sun's colour so they read against the sun and the sky in either theme.
  function endSign(kind, x, tilt) {
    const wob = (n) => [...Array(n)].map((_, i) => [-2, 1.5, -1, 2.5, 0, -2.5, 1, -1.5, 2, 0][i % 10]).join(' ');
    const dy = (n) => [...Array(n)].map((_, i) => [0, -1, 1, 0, -1.2, 1, 0, -.8, .8, 0][i % 10]).join(' ');
    const text = (t, tx, ty, fs, len) => `<text x="${tx}" y="${ty}" text-anchor="middle" font-size="${fs}" font-weight="700" textLength="${len}" lengthAdjust="spacingAndGlyphs"
        rotate="${wob(t.length)}" dy="${dy(t.length)}" style="font-family:${HAND};fill:var(--letter)">${t}</text>`;
    const body = kind === 'problem'
      ? `<path d="M-1.8 0 L-2.2 -26 L2.4 -26 L1.8 0z"/><path d="M-30 -52 L29 -55 L30.5 -24 L-28.5 -22.5 Z"/>
         ${text('problem!', .5, -32.5, 15, 50)}`
      : `<path d="M-1.8 0 L-1.6 -24 L2.2 -24 L1.8 0z"/><path d="M-37 -22 L-36 -59 Q0 -69 37.5 -60 L36.5 -21 Z"/>
         ${text('need human', 0, -43, 13, 58)}${text('inspection!', 0, -29, 13, 60)}`;
    return `<g transform="translate(${x} ${EH}) rotate(${tilt})" style="fill:${SIL}">${body}</g>`;
  }

  function endScene(el) {
    const kind = ESUN_Y[el.dataset.kind] !== undefined ? el.dataset.kind : 'done';
    const w = +el.dataset.w || 400, h = Math.round(w * 170 / 320), id = 'e' + (++uid);
    const { cx, r } = ESUN, cy = ESUN_Y[kind];
    let extra = '';
    if (kind === 'done') extra = [22, 44, 66, 88, 110, 210, 232, 254, 276, 298].map(x =>
      `<rect x="${x - 1.1}" y="${EH - 12}" width="2.2" height="12"/><path d="M${x + 1.1} ${EH - 12} l8 2.8 l-8 2.8z"/>`).join('');
    if (kind === 'problem') extra = endSign('problem', 206, 8);
    if (kind === 'human') extra = endSign('human', 124, -7);
    el.innerHTML = svg(w, h, '0 0 320 170', `<defs><clipPath id="${id}c"><rect x="0" y="0" width="320" height="${EH}"/></clipPath></defs>
      <g clip-path="url(#${id}c)">${endSun(cx, cy, r, id)}</g>${endGround(id, cx, cy, r)}
      <g style="fill:${SIL}">${extra}</g>${endFigure(EPOSE[kind], EAT[kind])}`);
    el.firstChild.setAttribute('class', 'scene');
  }

  // ---- the doctor's inspector at a run: two stances swapped by CSS, sweat drops trailing him ----
  function runner(el) {
    el.classList.add('runner');
    el.innerHTML = `<span class="flip">${svg(40, 60, '0 0 40 60', `
      <path class="lg-a" d="M13 40 L8 57 h7 L20 45 L26 57 h7 L27 40z" style="fill:var(--earth);${OUT}"/>
      <path class="lg-b" d="M15 40 L16 57 h6 L20 47 L20 57 h6 L25 40z" style="fill:var(--earth);${OUT}"/>
      <path d="M12 21 Q20 17 28 21 L30 41 L10 41 Z" style="fill:var(--rust);${OUT}"/><path d="M12 30 h16" style="stroke:var(--sun);stroke-width:2.2"/>
      <path d="M14 23 l-6 9" fill="none" style="stroke:var(--amber);stroke-width:4.4;stroke-linecap:round"/>
      <rect x="27" y="26" width="9" height="12" rx="1.4" style="fill:var(--panel);stroke:var(--post);stroke-width:1.5"/><rect x="29.5" y="24.5" width="4" height="3" rx=".8" style="fill:var(--post)"/>
      <path d="M29.5 31 h4 M29.5 34 h4" style="stroke:var(--muted);stroke-width:1"/>
      <circle cx="20" cy="13" r="6.2" style="fill:var(--sun);${OUT}"/><circle cx="23" cy="13.4" r=".9" style="fill:var(--ink)"/>
      <path d="M12.6 11.5 Q13 4.2 20 4.2 Q27 4.2 27.4 11.5 Z" style="fill:var(--amber);${OUT}"/><rect x="11" y="10.8" width="19" height="3" rx="1.5" style="fill:var(--amber);${OUT}"/>
      <path class="drop" d="M8 8 q1.8 2.4 0 4 q-1.8 -1.6 0 -4z"/><path class="drop d2" d="M5.5 16 q1.8 2.4 0 4 q-1.8 -1.6 0 -4z"/>`)}</span>`;
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
    root.querySelectorAll('[data-art=end]').forEach(endScene);
    root.querySelectorAll('[data-art=runner]').forEach(runner);
  }

  function build() {
    const picks = ((document.querySelector('[data-pick]') || {}).dataset?.pick || '').split(/\s+/).filter(Boolean);   // data-pick="a c" marks every picked take
    document.querySelectorAll('template[data-take]').forEach(t => {
      const sec = document.createElement('section'); sec.className = 'take';
      const take = t.dataset.take;
      const badge = t.dataset.badge !== undefined ? t.dataset.badge : 'PICK';   // data-badge="" drops it, e.g. for options still to choose between
      sec.innerHTML = `<h2>${take} · ${t.dataset.title}${badge && picks.includes((take.match(/^[a-z]+/) || [])[0]) ? `<span class="badge">${badge}</span>` : ''}</h2><p></p><div class="frames"></div>`;
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
