'use strict';
// preview.js: a ticket's text turned into a list of plain nodes — a heading, bold, inline code,
// bullets, check boxes and paragraphs, and nothing else. The page builds them with createElement and
// textContent, so what is held here is that nothing in a ticket can become anything but characters.
const test = require('node:test');
const assert = require('node:assert/strict');
const { preview } = require('../preview.js');

const para = (...children) => ({ type: 'paragraph', children });
const t = (text) => ({ type: 'text', text });

// The text of every inline node anywhere in the tree, to check that nothing was lost or turned into markup.
function strings(node) {
  if (Array.isArray(node)) return node.flatMap(strings);
  if (node && typeof node === 'object') {
    return Object.entries(node).flatMap(([k, v]) => (k === 'text' && typeof v === 'string' ? [v] : strings(v)));
  }
  return [];
}
const KINDS = new Set(['heading', 'paragraph', 'list', 'item', 'text', 'bold', 'code']);
function kindsOf(node, out = new Set()) {
  if (Array.isArray(node)) node.forEach((n) => kindsOf(n, out));
  else if (node && typeof node === 'object') { if (node.type) out.add(node.type); Object.values(node).forEach((v) => kindsOf(v, out)); }
  return out;
}

test('a heading, with its level and its text', () => {
  assert.deepEqual(preview('# 03: The ticket page'), [{ type: 'heading', level: 1, children: [t('03: The ticket page')] }]);
  assert.equal(preview('### Third')[0].level, 3);
  assert.equal(preview('####### seven is not a heading')[0].type, 'paragraph');
});

test('a # with no space after it is not a heading', () => {
  assert.deepEqual(preview('#hashtag'), [para(t('#hashtag'))]);
});

test('bold and inline code inside a line; everything else in it stays as it is', () => {
  assert.deepEqual(preview('**Status:** ready for `foreman run` now'),
    [para({ type: 'bold', text: 'Status:' }, t(' ready for '), { type: 'code', text: 'foreman run' }, t(' now'))]);
  assert.deepEqual(preview('**bold `not code`**'), [para({ type: 'bold', text: 'bold `not code`' })]);
  assert.deepEqual(preview('`**not bold**`'), [para({ type: 'code', text: '**not bold**' })]);
});

test('an unclosed ** or ` is just those characters', () => {
  assert.deepEqual(preview('a ** b'), [para(t('a ** b'))]);
  assert.deepEqual(preview('a ` b'), [para(t('a ` b'))]);
  assert.deepEqual(preview('**open'), [para(t('**open'))]);
});

test('bullets group into one list; - [ ] is an unticked box and - [x] a ticked one', () => {
  const [list] = preview('- plain\n* star\n- [ ] to do\n- [x] done\n- [X] done too');
  assert.equal(list.type, 'list');
  assert.deepEqual(list.items.map((i) => [i.checked, strings(i.children).join('')]),
    [[null, 'plain'], [null, 'star'], [false, 'to do'], [true, 'done'], [true, 'done too']]);
  assert.equal(preview('- a\n\n- b').length, 2, 'a blank line ends the list');
});

test('a box with nothing after it is still a box', () => {
  assert.deepEqual(preview('- [ ]')[0].items.map((i) => [i.checked, i.children]), [[false, []]]);
});

test('a wrapped criterion: the indented line after a bullet belongs to it', () => {
  const [list] = preview('- [ ] The run stops at the human ticket\n      and says so\n- [ ] next');
  assert.equal(list.items.length, 2);
  assert.equal(strings(list.items[0].children).join(''), 'The run stops at the human ticket and says so');
});

test('an indented bullet is an item one level in', () => {
  const [list] = preview('- top\n  - inner\n    - deeper\n- top again');
  assert.deepEqual(list.items.map((i) => i.depth), [0, 1, 2, 0]);
});

test('paragraphs are split at blank lines and keep their own line breaks', () => {
  assert.deepEqual(preview('one\ntwo\n\n\nthree'), [para(t('one\ntwo')), para(t('three'))]);
});

test('a <script> or <img onerror=…> is text, in a paragraph, a heading, a bullet and a code span', () => {
  const evil = '<script>alert(1)</script><img src=x onerror="alert(2)">';
  const tree = preview(`# ${evil}\n\n${evil}\n\n- ${evil}\n- [x] ${evil}\n\n\`${evil}\` and **${evil}**`);
  assert.ok(strings(tree).filter((s) => s.includes(evil)).length >= 6, 'the characters are all there');
  assert.deepEqual([...kindsOf(tree)].filter((k) => !KINDS.has(k)), [], 'and no node of any other kind');
  assert.ok(!JSON.stringify(tree).includes('"tag"') && !JSON.stringify(tree).includes('"html"'));
});

test('[x](javascript:alert(1)) is not a link: it is the characters, in a bullet and in a paragraph', () => {
  const [p] = preview('[x](javascript:alert(1))');
  assert.deepEqual(p, para(t('[x](javascript:alert(1))')));
  const [list] = preview('- [x](javascript:alert(1))');
  assert.equal(list.items[0].checked, null, 'it is not a ticked box');
  assert.equal(strings(list.items[0].children).join(''), '[x](javascript:alert(1))');
  assert.deepEqual(preview('![img](http://x/y.png)'), [para(t('![img](http://x/y.png)'))]);
  assert.deepEqual(preview('<https://example.com>'), [para(t('<https://example.com>'))]);
});

test('a line that is not Markdown comes out as itself', () => {
  for (const line of ['Status: ready-for-agent', '1. a numbered line', '---', '> quoted', '| a | b |', '    indented four']) {
    assert.deepEqual(preview(line), [para(t(line.trim()))], line);
  }
});

test('a ticket with no heading still renders', () => {
  const tree = preview('Just a note.\n\n- [ ] one\n- [x] two');
  assert.deepEqual(tree.map((n) => n.type), ['paragraph', 'list']);
});

test('a fenced block is one inline code span of its own text — a # in it is not a heading', () => {
  const tree = preview('before\n\n```bash\n# a comment\n- not a bullet\n```\n\nafter');
  assert.deepEqual(tree.map((n) => n.type), ['paragraph', 'paragraph', 'paragraph']);
  assert.deepEqual(tree[1], para({ type: 'code', text: '# a comment\n- not a bullet' }));
});

test('an unclosed fence takes the rest of the text, and nothing is lost', () => {
  const tree = preview('```\n# one\ntwo');
  assert.deepEqual(tree, [para({ type: 'code', text: '# one\ntwo' })]);
});

test('empty text and non-text are an empty list, and CRLF is read as lines', () => {
  assert.deepEqual(preview(''), []);
  assert.deepEqual(preview(null), []);
  assert.deepEqual(preview(undefined), []);
  assert.deepEqual(preview('a\r\n\r\nb\r\n'), [para(t('a')), para(t('b'))]);
});

test('every character of an arbitrary text survives, in order, apart from the markers', () => {
  const src = '# H\n\n**b** `c` text <b>x</b>\n- [ ] one\n- [x] two\n\nend';
  const all = strings(preview(src)).join('');
  for (const piece of ['H', 'b', 'c', ' text <b>x</b>', 'one', 'two', 'end']) assert.ok(all.includes(piece), piece);
});

test('the page script builds the nodes with createElement and textContent only', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'preview.js'), 'utf8')
    .replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
  for (const bad of ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document', 'eval(', 'new Function']) {
    assert.ok(!src.includes(bad), `preview.js must not use ${bad}`);
  }
});

test('a heading keeps a # that belongs to its text; only a closing run of #s after a space is dropped', () => {
  assert.deepEqual(preview('# C#'), [{ type: 'heading', level: 1, children: [t('C#')] }]);
  assert.deepEqual(preview('## issue #12'), [{ type: 'heading', level: 2, children: [t('issue #12')] }]);
  assert.deepEqual(preview('## closed ##'), [{ type: 'heading', level: 2, children: [t('closed')] }]);
});
