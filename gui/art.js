'use strict';
// The pictures, as SVG built node by node — no markup strings, so nothing is ever parsed. A port
// of the dome in designs/source/canvas.js. Colours come from the tokens through the classes in
// app.css (f-amber, k-post, ...): the strict CSP allows no inline style, and the classes let the
// light and dark themes redraw the same shapes.
//
// Only what the screens built so far need (the dome, the doctor's runner). The other scenes
// (foreman, end scenes) arrive with the screens that show them.
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

  root.ForemanArt = { dome, runner };
}(window));
