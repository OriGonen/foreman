'use strict';
// The pictures, as SVG built node by node — no markup strings, so nothing is ever parsed. A port
// of the dome in designs/source/canvas.js. Colours come from the tokens through the classes in
// app.css (f-amber, k-post, ...): the strict CSP allows no inline style, and the classes let the
// light and dark themes redraw the same shapes.
//
// Only what the screens built so far need (the dome, the doctor's runner, the run-end scenes).
(function (root) {
  const NS = 'http://www.w3.org/2000/svg';
  let uid = 0;

  function svg(tag, attrs, kids) {
    const e = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs || {})) e.setAttribute(k, String(v));
    for (const kid of kids || []) e.appendChild(kid);
    return e;
  }

  // The sunrise dome over the stake line. The sun's height is how much has landed (p, 0..1); a
  // stake is a ticket: d landed · > next · h human · f followup · . to go · x missing.
  //   dome({ w: 190, p: 0.4, stakes: 'dddd>.hf..' })
  function dome({ w = 240, p = 0, stakes = '' } = {}) {
    p = Math.min(Math.max(Number.isFinite(p) ? p : 0, 0), 1);
    const h = Math.round(w * 0.62);
    const id = 'dome' + (++uid);
    const cy = 112 - p * 74;            // the sun climbs from the horizon to the top of the dome
    const kids = [];

    kids.push(svg('defs', {}, [
      svg('linearGradient', { id: id + 'g', x1: 0, y1: 0, x2: 0, y2: 1 }, [
        svg('stop', { offset: 0, class: 's-top' }), svg('stop', { offset: 1, class: 's-bot' }),
      ]),
      svg('clipPath', { id: id + 'c' }, [svg('path', { d: 'M14 104 A86 86 0 0 1 186 104 Z' })]),
    ]));
    kids.push(svg('path', { d: 'M14 104 A86 86 0 0 1 186 104 Z', fill: `url(#${id}g)` }));

    const sky = [
      svg('circle', { cx: 100, cy, r: 40, class: 'f-halo', opacity: 0.22 }),
      svg('circle', { cx: 100, cy, r: 27, class: 'f-sunfill' }),
    ];
    if (p >= 1) {
      for (let i = 0; i < 9; i++) {
        const a = Math.PI * (i + 1) / 10;
        sky.push(svg('line', {
          x1: 100 - Math.cos(a) * 34, y1: cy - Math.sin(a) * 34, x2: 100 - Math.cos(a) * 46, y2: cy - Math.sin(a) * 46,
          class: 'k-sunfill', 'stroke-width': 3, 'stroke-linecap': 'round',
        }));
      }
    }
    kids.push(svg('g', { 'clip-path': `url(#${id}c)` }, sky));

    kids.push(svg('path', { d: 'M14 104 A86 86 0 0 1 186 104', fill: 'none', class: 'k-post', 'stroke-width': 2.4 }));
    kids.push(svg('path', { d: 'M40 104 A60 60 0 0 1 160 104', fill: 'none', class: 'k-post', 'stroke-width': 1, opacity: 0.35, 'stroke-dasharray': '3 5' }));
    kids.push(svg('rect', { x: 4, y: 104, width: 192, height: 3, rx: 1.5, class: 'f-earth' }));

    const n = stakes.length;
    const x0 = 22, x1 = 178, step = n > 1 ? (x1 - x0) / (n - 1) : 0;
    [...stakes].forEach((c, i) => {
      const x = n > 1 ? x0 + i * step : 100;
      const cls = c === 'd' ? 'f-amber' : c === '>' ? 'f-sunfill' : c === 'h' ? 'f-rust' : c === 'x' ? 'f-err' : 'f-dim';
      kids.push(svg('rect', { x: x - 1.6, y: 108, width: 3.2, height: c === '>' ? 15 : 10, rx: 1, class: cls }));
      if (c === 'h') kids.push(svg('path', { d: `M${x + 1.6} 108 l8 3 l-8 3z`, class: 'f-rust' }));
      if (c === '>') kids.push(svg('circle', { cx: x, cy: 106, r: 2.6, class: 'f-sunfill' }));
      if (c === 'f') kids.push(svg('circle', { cx: x, cy: 120, r: 1.6, class: 'f-muted' }));
    });

    return svg('svg', { xmlns: NS, width: w, height: h, viewBox: '0 0 200 124', 'aria-hidden': 'true' }, kids);
  }

  // The doctor's inspector: a clipboard under his arm, sweat drops trailing him. Two stances (lg-a and
  // lg-b) and the drops are swapped and moved by the stylesheet's keyframes, and the run across the
  // track and back is the element's own animation: nothing here moves anything. The shapes are the
  // design's (designs/08-doctor.html), their colours classes of app.css.
  //   runner()   -> <span class="runner"><span class="flip"><svg>…</svg></span></span>
  function runner() {
    const o = 'k-out';
    const kids = [
      svg('path', { class: 'lg-a f-earth ' + o, d: 'M13 40 L8 57 h7 L20 45 L26 57 h7 L27 40z' }),
      svg('path', { class: 'lg-b f-earth ' + o, d: 'M15 40 L16 57 h6 L20 47 L20 57 h6 L25 40z' }),
      svg('path', { class: 'f-rust ' + o, d: 'M12 21 Q20 17 28 21 L30 41 L10 41 Z' }),
      svg('path', { class: 'k-sun', 'stroke-width': 2.2, d: 'M12 30 h16' }),
      svg('path', { class: 'k-amber', fill: 'none', 'stroke-width': 4.4, 'stroke-linecap': 'round', d: 'M14 23 l-6 9' }),
      svg('rect', { class: 'f-panel k-post', x: 27, y: 26, width: 9, height: 12, rx: 1.4, 'stroke-width': 1.5 }),
      svg('rect', { class: 'f-post', x: 29.5, y: 24.5, width: 4, height: 3, rx: 0.8 }),
      svg('path', { class: 'k-muted', 'stroke-width': 1, d: 'M29.5 31 h4 M29.5 34 h4' }),
      svg('circle', { class: 'f-sun ' + o, cx: 20, cy: 13, r: 6.2 }),
      svg('circle', { class: 'f-ink', cx: 23, cy: 13.4, r: 0.9 }),
      svg('path', { class: 'f-amber ' + o, d: 'M12.6 11.5 Q13 4.2 20 4.2 Q27 4.2 27.4 11.5 Z' }),
      svg('rect', { class: 'f-amber ' + o, x: 11, y: 10.8, width: 19, height: 3, rx: 1.5 }),
      svg('path', { class: 'drop', d: 'M8 8 q1.8 2.4 0 4 q-1.8 -1.6 0 -4z' }),
      svg('path', { class: 'drop d2', d: 'M5.5 16 q1.8 2.4 0 4 q-1.8 -1.6 0 -4z' }),
    ];
    const flip = document.createElement('span');
    flip.className = 'flip';
    flip.appendChild(svg('svg', { xmlns: NS, width: 40, height: 60, viewBox: '0 0 40 60', 'aria-hidden': 'true' }, kids));
    const el = document.createElement('span');
    el.className = 'runner';
    el.appendChild(flip);
    return el;
  }

  // The inspector standing with his clipboard, for the states that need a person to look at something: a
  // sign over his shoulder (`stop`, the red FIX). A port of the design's `person(el, 'inspector')`
  // (designs/09-empty-and-error.html), the shapes the same and the colours classes of app.css.
  //   inspector({ w: 64, sign: 'stop' }) -> <svg>
  function inspector({ w = 64, sign = null } = {}) {
    const h = Math.round(w * 1.5);
    const kids = [];
    if (sign === 'stop') {
      kids.push(svg('rect', { x: 2, y: 2, width: 30, height: 20, rx: 3, class: 'f-err' }));
      const t = svg('text', { x: 17, y: 16, 'text-anchor': 'middle', 'font-size': 9, 'font-family': 'Consolas,monospace', 'font-weight': 700, class: 'f-panel' });
      t.textContent = 'FIX';
      kids.push(t);
    }
    kids.push(
      svg('path', { d: 'M22 30 a14 14 0 0 1 28 0z', class: 'f-amber' }),
      svg('rect', { x: 18, y: 29, width: 36, height: 4, rx: 2, class: 'f-amber' }),
      svg('circle', { cx: 36, cy: 40, r: 9, class: 'f-sun' }),
      svg('path', { d: 'M22 54 q14 -6 28 0 l4 34 h-36z', class: 'f-rust' }),
      svg('path', { d: 'M30 52 h12 v36 h-12z', class: 'f-amber', opacity: 0.85 }),
      svg('path', { d: 'M24 88 l-2 28 h8 l4 -24 l4 24 h8 l-2 -28z', class: 'f-earth' }),
      svg('path', { d: 'M50 58 l10 8', class: 'k-rust', 'stroke-width': 6, 'stroke-linecap': 'round' }),
      svg('rect', { x: 46, y: 54, width: 22, height: 30, rx: 2, class: 'f-panel k-post', 'stroke-width': 2 }),
      svg('rect', { x: 51, y: 51, width: 12, height: 5, rx: 1, class: 'f-post' }),
      svg('path', { d: 'M51 63 h12 M51 69 h12 M51 75 h8', class: 'k-muted', 'stroke-width': 1.6 }),
      svg('rect', { x: 0, y: 116, width: 80, height: 3, rx: 1.5, class: 'f-earth' }),
    );
    return svg('svg', { xmlns: NS, width: w, height: h, viewBox: '0 0 80 120', 'aria-hidden': 'true' }, kids);
  }

  // ---- how a run ended (design 05, take b1) ----
  //
  // The terminal's sunrise (lib/foreman-draw.cjs) as a silhouette: one big sun in flat bands on a low
  // horizon with its glint on the ground, and the foreman in front of it as one flat dark shape. He is the
  // terminal's own 18 x 25 half-block sprite (FIGURE_TOP + FIGURE_LEGS), drawn in square cells; his left arm
  // is taken off so each pose can put both arms where it needs them. A port of `endScene` and its helpers in
  // designs/source/canvas.js, the shapes and numbers the same; the colours are classes of app.css (f-ring1,
  // f-sil, f-letter, ...), which read the --sun-*, --glow, --glint, --night, --sil and --letter tokens in
  // both themes.
  const EH = 148;                                     // the horizon
  const ESUN = { cx: 160, r: 70 };
  // exit 10 and exit 30 share one sun: held halfway, on the horizon
  const ESUN_Y = { done: EH - 68, paused: EH, human: EH, problem: EH + 8 };
  const EPOSE = { done: 'raise', paused: 'hold', problem: 'scratch', human: 'shrug' };
  const EAT = { done: 160, paused: 144, problem: 136, human: 190 };     // where he stands
  const HAND = "'Segoe Print','Bradley Hand','Chalkboard SE','Comic Sans MS',cursive";
  const FLAGS_AT = [22, 44, 66, 88, 110, 210, 232, 254, 276, 298];       // the horizon holds ten, either side of him

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
    shrug: (() => {
      const l = [[3, 12], [2, 12], [2, 13], [1, 13], [1, 14], [2, 14], [1, 15], [0, 15], [0, 14], [-1, 14], [-1, 13], [-2, 13], [-2, 12], [-3, 12], [-4, 12], [-4, 11], [-3, 11]];
      return l.concat(l.map(([x, y]) => [17 - x, y]));
    })(),
  };

  function pixelFigure(pose, x) {
    const c = 1.72;                                    // one cell, in the scene's units
    const cells = [];
    PX_BODY.forEach((row, j) => [...row].forEach((ch, i) => { if (ch === '#') cells.push([i, j]); }));
    cells.push(...PX_ARMS[pose]);
    const body = svg('path', { d: cells.map(([i, j]) => `M${i} ${j}h1.04v1.04h-1.04z`).join(''), 'shape-rendering': 'crispEdges' });
    return svg('g', {
      class: 'foreman f-sil', 'data-pose': pose,
      transform: `translate(${(x - 8.8 * c).toFixed(2)} ${(EH - 25 * c).toFixed(2)}) scale(${c})`,
    }, [body]);
  }

  // A hand-lettered sign: a dark post and a board leaning off square, the letters painted on in the sun's
  // colour so they read against the sun and the sky in either theme.
  function endSign(kind, x, tilt) {
    const wob = (n) => [...Array(n)].map((_, i) => [-2, 1.5, -1, 2.5, 0, -2.5, 1, -1.5, 2, 0][i % 10]).join(' ');
    const dy = (n) => [...Array(n)].map((_, i) => [0, -1, 1, 0, -1.2, 1, 0, -.8, .8, 0][i % 10]).join(' ');
    const letters = (word, tx, ty, size, len) => {
      const e = svg('text', {
        x: tx, y: ty, 'text-anchor': 'middle', 'font-size': size, 'font-weight': 700, textLength: len, lengthAdjust: 'spacingAndGlyphs',
        rotate: wob(word.length), dy: dy(word.length), 'font-family': HAND, class: 'f-letter',
      });
      e.textContent = word;
      return e;
    };
    const kids = kind === 'problem'
      ? [svg('path', { d: 'M-1.8 0 L-2.2 -26 L2.4 -26 L1.8 0z' }), svg('path', { d: 'M-30 -52 L29 -55 L30.5 -24 L-28.5 -22.5 Z' }), letters('problem!', 0.5, -32.5, 15, 50)]
      : [svg('path', { d: 'M-1.8 0 L-1.6 -24 L2.2 -24 L1.8 0z' }), svg('path', { d: 'M-37 -22 L-36 -59 Q0 -69 37.5 -60 L36.5 -21 Z' }),
        letters('need human', 0, -43, 13, 58), letters('inspection!', 0, -29, 13, 60)];
    return svg('g', { class: 'sign f-sil', 'data-sign': kind, transform: `translate(${x} ${EH}) rotate(${tilt})` }, kids);
  }

  // The scene for how a run ended: kind 'done' | 'paused' | 'problem' | 'human', and for 'done' the number of
  // tickets that landed (a flag on a stake each, up to the ten the horizon holds).
  //   endScene({ kind: 'done', flags: 10, w: 400 }) -> <svg>
  function endScene({ kind = 'done', flags = 0, w = 400 } = {}) {
    if (ESUN_Y[kind] === undefined) kind = 'done';
    const h = Math.round(w * 170 / 320);
    const id = 'end' + (++uid);
    const { cx, r } = ESUN;
    const cy = ESUN_Y[kind];

    const defs = svg('defs', {}, [
      svg('clipPath', { id: id + 'c' }, [svg('rect', { x: 0, y: 0, width: 320, height: EH })]),
      svg('radialGradient', { id: id + 'g' }, [svg('stop', { offset: 0.3, class: 's-glow' }), svg('stop', { offset: 1, class: 's-glow0' })]),
      svg('linearGradient', { id: id + 'v', x1: 0, y1: 0, x2: 0, y2: 1 }, [svg('stop', { offset: 0, class: 's-night' }), svg('stop', { offset: 1, class: 's-night0' })]),
      svg('linearGradient', { id: id + 'h', x1: 0, y1: 0, x2: 1, y2: 0 }, [
        svg('stop', { offset: 0, 'stop-color': '#000' }), svg('stop', { offset: 0.18, 'stop-color': '#fff' }),
        svg('stop', { offset: 0.82, 'stop-color': '#fff' }), svg('stop', { offset: 1, 'stop-color': '#000' })]),
      svg('mask', { id: id + 'm', maskUnits: 'userSpaceOnUse', x: 0, y: 0, width: 320, height: 170 }, [
        svg('rect', { x: 0, y: 0, width: 320, height: 170, fill: `url(#${id}h)` })]),
    ]);

    // the sun, clipped to the sky: a glow, then flat bands from the rim in
    const sky = [svg('circle', { class: 'f-glow', cx, cy, r: (r * 2.2).toFixed(1), fill: `url(#${id}g)` })];
    for (const [rr, cls] of [[r + 10, 'f-ring2'], [r + 5, 'f-ring1'], [r, 'f-rim'], [r * 0.84, 'f-mid'], [r * 0.56, 'f-core']]) {
      sky.push(svg('circle', { class: cls, cx, cy, r: rr.toFixed(1) }));
    }

    // the ground: a band that fades down and out to the sides, a hard horizon, and the sun's glint under it
    const half = cy <= EH - r ? r * 0.72 : Math.sqrt(Math.max(0, r * r - (EH - cy) ** 2));
    const glint = [0, 1, 2, 3].map((k) => {
      const wk = half * (1 - k * 0.23), y = EH + 4 + k * 5;
      return svg('line', {
        class: 'k-glint', x1: (cx - wk).toFixed(1), x2: (cx + wk).toFixed(1), y1: y, y2: y,
        'stroke-width': 1.7, 'stroke-linecap': 'round', opacity: (0.95 - k * 0.22).toFixed(2),
      });
    });
    const ground = svg('g', { mask: `url(#${id}m)` }, [
      svg('rect', { class: 'f-night', x: 0, y: EH, width: 320, height: 170 - EH, fill: `url(#${id}v)` }),
      svg('rect', { class: 'f-sil', x: 0, y: EH - 0.6, width: 320, height: '1.5' }),
    ]);

    // what stands beside him
    const beside = [];
    if (kind === 'done') {
      FLAGS_AT.slice(0, Math.max(0, Math.min(flags | 0, FLAGS_AT.length))).forEach((x) => {
        beside.push(svg('g', { class: 'flag f-sil', 'data-x': x }, [
          svg('rect', { x: x - 1.1, y: EH - 12, width: 2.2, height: 12 }),
          svg('path', { d: `M${x + 1.1} ${EH - 12} l8 2.8 l-8 2.8z` }),
        ]));
      });
    }
    if (kind === 'problem') beside.push(endSign('problem', 206, 8));
    if (kind === 'human') beside.push(endSign('human', 124, -7));

    return svg('svg', { xmlns: NS, class: 'scene', width: w, height: h, viewBox: '0 0 320 170', 'aria-hidden': 'true' }, [
      defs, svg('g', { 'clip-path': `url(#${id}c)` }, sky), ground, ...glint, ...beside, pixelFigure(EPOSE[kind], EAT[kind]),
    ]);
  }

  root.ForemanArt = { dome, runner, inspector, endScene };
}(window));
