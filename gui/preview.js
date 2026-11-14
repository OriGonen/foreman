'use strict';
// A ticket's text as the Preview shows it: a list of plain nodes, from a small fixed set.
//
//   { type: 'heading',   level: 1..6, children: [inline] }
//   { type: 'paragraph', children: [inline] }
//   { type: 'list',      items: [{ type: 'item', checked: null | false | true, depth: 0.., children: [inline] }] }
//
//   inline: { type: 'text' | 'bold' | 'code', text }
//
// That is all there is. No HTML passes through, and there are no links and no images: a `<script>`,
// a raw tag or a `[x](javascript:…)` is a text node holding exactly those characters. The page turns
// the nodes into elements with createElement and textContent (app.js); nothing here touches a
// document, so it is tested with plain Node.
//
// Loaded two ways, like model.js: as a plain <script> (it puts `ForemanPreview` on the window) and
// with require() in the tests.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ForemanPreview = factory();
}(typeof self !== 'undefined' ? self : this, function () {

  const HEADING = /^(#{1,6})\s+(.*?)(?:\s+#+)?\s*$/;        // the space after the #s is required; so is the one before a closing run of them
  const BULLET = /^(\s*)[-*+]\s+(.*)$/;
  const BOX = /^\[([ xX])\](?:\s+|$)(.*)$/;               // `[x]` must be followed by a space or the end:
                                                          // `[x](javascript:…)` is a link's shape, not a box
  const FENCE = /^\s*```/;

  // **bold** and `code` in a line. A code span is read first, so what is inside it is never bold; an
  // opener with no closer is just the characters.
  function inline(src) {
    const out = [];
    let text = '';
    const flush = () => { if (text !== '') { out.push({ type: 'text', text }); text = ''; } };
    let i = 0;
    while (i < src.length) {
      if (src[i] === '`') {
        const end = src.indexOf('`', i + 1);
        if (end > i + 1) { flush(); out.push({ type: 'code', text: src.slice(i + 1, end) }); i = end + 1; continue; }
      } else if (src.startsWith('**', i)) {
        const end = src.indexOf('**', i + 2);
        if (end > i + 2) { flush(); out.push({ type: 'bold', text: src.slice(i + 2, end) }); i = end + 2; continue; }
      }
      text += src[i];
      i++;
    }
    flush();
    return out;
  }

  const indentOf = (s) => /^\s*/.exec(s)[0].replace(/\t/g, '    ').length;

  function preview(source) {
    if (typeof source !== 'string' || source === '') return [];
    const lines = source.split(/\r\n|\r|\n/);
    const nodes = [];
    let para = null;           // lines of the paragraph being read
    let list = null;           // the list being read

    const endPara = () => {
      if (para) nodes.push({ type: 'paragraph', children: inline(para.join('\n')) });
      para = null;
    };
    const endAll = () => { endPara(); list = null; };

    for (let n = 0; n < lines.length; n++) {
      const line = lines[n];

      if (FENCE.test(line)) {           // a fenced block is one code span of its own text
        endAll();
        const body = [];
        n++;
        while (n < lines.length && !FENCE.test(lines[n])) body.push(lines[n++]);
        nodes.push({ type: 'paragraph', children: [{ type: 'code', text: body.join('\n') }] });
        continue;
      }
      if (line.trim() === '') { endAll(); continue; }

      const head = HEADING.exec(line);
      if (head) {
        endAll();
        nodes.push({ type: 'heading', level: head[1].length, children: inline(head[2]) });
        continue;
      }

      const bullet = BULLET.exec(line);
      if (bullet) {
        endPara();
        if (!list) { list = { type: 'list', items: [] }; nodes.push(list); }
        const box = BOX.exec(bullet[2]);
        list.items.push({
          type: 'item',
          checked: box ? box[1] !== ' ' : null,
          depth: Math.min(Math.floor(indentOf(bullet[1]) / 2), 3),
          children: inline(box ? box[2] : bullet[2]),
          _raw: box ? box[2] : bullet[2],
        });
        continue;
      }

      // A wrapped bullet: an indented line straight after an item goes on to that item.
      if (list && /^\s/.test(line)) {
        const item = list.items[list.items.length - 1];
        item._raw += ' ' + line.trim();
        item.children = inline(item._raw);
        continue;
      }

      list = null;
      if (!para) para = [];
      para.push(line.trim());
    }
    endAll();
    for (const node of nodes) if (node.type === 'list') for (const item of node.items) delete item._raw;
    return nodes;
  }

  return { preview };
}));
