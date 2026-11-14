'use strict';
// ticket.cjs: what main reads for a ticket's page, and the one thing the app writes — the handoff
// file the ticket names. Held here: the path check (nothing outside the repo, through `..`, an
// absolute path or a symlink), that the page never names the path, that a file changed on disk is
// not overwritten unasked, and that line endings are kept. Real files in a temporary repository.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { resolveInside, detectEol, toEol, createTicketFiles } = require('../ticket.cjs');

function repo() {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'foreman-ticket-')));
  fs.mkdirSync(path.join(root, 'b', 'issues'), { recursive: true });
  fs.mkdirSync(path.join(root, 'b', 'handoff'), { recursive: true });
  return root;
}
const put = (root, rel, text) => { fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true }); fs.writeFileSync(path.join(root, rel), text); };
const get = (root, rel) => fs.readFileSync(path.join(root, rel), 'utf8');
const refused = (e) => e.kind === 'bad-handoff';

function status(over = {}) {
  return {
    tickets: [
      { name: '07-try-it', file: 'b/issues/07-try-it.md', human: true, done: false, handoff: 'b/handoff/07-try-it.md', ...over },
      { name: '08-agent', file: 'b/issues/08-agent.md', human: false, done: false, handoff: null },
    ],
  };
}

// A foreman that answers `status` and counts how often it was asked.
function files(root, st = status()) {
  const asked = { n: 0 };
  const foreman = { status: async () => { asked.n++; return typeof st === 'function' ? st() : st; } };
  return { asked, tf: createTicketFiles({ repoRoot: root, foreman }) };
}

// ---- the path check ----

test('resolveInside: a repo-relative path inside the repo is the file under the root', () => {
  const root = repo();
  assert.equal(resolveInside(root, 'b/handoff/07-try-it.md'), path.join(root, 'b', 'handoff', '07-try-it.md'));
  assert.equal(resolveInside(root.replace(/\\/g, '/'), 'b/handoff/new/x.md'), path.join(root, 'b', 'handoff', 'new', 'x.md'), 'a file and folder that are not there yet');
});

test('resolveInside refuses a path with `..` in it, however it is spelt', () => {
  const root = repo();
  for (const bad of ['..', '../x.md', 'b/../../x.md', 'b/handoff/../../../x.md', 'b/..', 'b/../b/handoff/x.md']) {
    assert.throws(() => resolveInside(root, bad), refused, bad);
  }
});

test('resolveInside refuses an absolute path: POSIX, drive-letter, UNC, backslashed', () => {
  const root = repo();
  for (const bad of ['/etc/passwd', 'C:/Windows/x.md', 'c:x.md', '//server/share/x.md', 'b\\handoff\\x.md', '\\x.md']) {
    assert.throws(() => resolveInside(root, bad), refused, bad);
  }
});

test('resolveInside refuses what is not a path: empty, NUL, not a string', () => {
  const root = repo();
  for (const bad of ['', 'a\0b.md', null, undefined, 7, {}]) assert.throws(() => resolveInside(root, bad), refused, String(bad));
});

test('resolveInside refuses a path that resolves outside the repo through a symlink', (t) => {
  const root = repo();
  const outside = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'foreman-outside-')));
  try {
    fs.symlinkSync(outside, path.join(root, 'b', 'link'), 'junction');
    fs.symlinkSync(path.join(outside, 'target.md'), path.join(root, 'b', 'handoff', 'dangling.md'));
    put(outside, 'real.md', 'secret');
    fs.symlinkSync(path.join(outside, 'real.md'), path.join(root, 'b', 'handoff', 'file-link.md'));
  } catch (e) {
    t.skip('this machine cannot make symlinks: ' + e.code);
    return;
  }
  assert.throws(() => resolveInside(root, 'b/link/x.md'), refused, 'through a linked folder');
  assert.throws(() => resolveInside(root, 'b/link/new/deep/x.md'), refused, 'through a linked folder, to a file that is not there');
  assert.throws(() => resolveInside(root, 'b/handoff/file-link.md'), refused, 'a linked file');
  assert.throws(() => resolveInside(root, 'b/handoff/dangling.md'), refused, 'a link to nothing: writing would create the file outside');
});

test('resolveInside allows a symlink that stays inside the repo, and gives the real path', (t) => {
  const root = repo();
  put(root, 'b/real/x.md', 'x');
  try { fs.symlinkSync(path.join(root, 'b', 'real'), path.join(root, 'b', 'alias'), 'junction'); } catch (e) { t.skip(e.code); return; }
  assert.equal(resolveInside(root, 'b/alias/x.md'), path.join(root, 'b', 'real', 'x.md'));
});

test('resolveInside refuses .git, whatever the case', () => {
  const root = repo();
  for (const bad of ['.git/hooks/pre-commit', 'b/.GIT/config', '.Git']) assert.throws(() => resolveInside(root, bad), refused, bad);
});

// ---- line endings ----

test('detectEol: CRLF when most of the line ends are CRLF, else LF — a new or one-line file is LF', () => {
  assert.equal(detectEol('a\r\nb\r\n'), '\r\n');
  assert.equal(detectEol('a\nb\n'), '\n');
  assert.equal(detectEol('a\r\nb\nc\r\n'), '\r\n');
  assert.equal(detectEol('a\nb\nc\r\n'), '\n');
  assert.equal(detectEol('no newline'), '\n');
  assert.equal(detectEol(''), '\n');
  assert.equal(detectEol(null), '\n');
});

test('toEol: every kind of line end in the text becomes the one asked for', () => {
  assert.equal(toEol('a\nb\r\nc\rd', '\r\n'), 'a\r\nb\r\nc\r\nd');
  assert.equal(toEol('a\r\nb\n', '\n'), 'a\nb\n');
});

// ---- reading a ticket's page ----

test('load: the ticket text, the batch\'s progress.txt and, for a human ticket, its handoff', async () => {
  const root = repo();
  put(root, 'b/issues/07-try-it.md', '# 07\r\n- [ ] do it\r\n');
  put(root, 'b/progress.txt', '## 07 — notes\n- a\n');
  put(root, 'b/handoff/07-try-it.md', '## What I did\r\n');
  const { tf } = files(root);
  const doc = await tf.load('b', '07-try-it');
  assert.equal(doc.file, 'b/issues/07-try-it.md');
  assert.equal(doc.text, '# 07\r\n- [ ] do it\r\n', 'the file\'s own text, line ends and all');
  assert.equal(doc.progress, '## 07 — notes\n- a\n');
  assert.deepEqual(doc.handoff, { path: 'b/handoff/07-try-it.md', text: '## What I did\r\n', error: null });
});

test('load: no progress.txt is null, a handoff not written yet has no text, an agent ticket has no handoff', async () => {
  const root = repo();
  put(root, 'b/issues/07-try-it.md', 't');
  put(root, 'b/issues/08-agent.md', 'a');
  const { tf } = files(root);
  const human = await tf.load('b', '07-try-it');
  assert.equal(human.progress, null);
  assert.deepEqual(human.handoff, { path: 'b/handoff/07-try-it.md', text: null, error: null });
  assert.equal((await tf.load('b', '08-agent')).handoff, null);
});

test('load: a handoff path the check refuses is shown as the refusal, not read', async () => {
  const root = repo();
  put(root, 'b/issues/07-try-it.md', 't');
  put(root, 'x.md', 'outside the handoff folder but inside the repo: fine');
  const { tf } = files(root, status({ handoff: 'b/../../outside.md' }));
  const doc = await tf.load('b', '07-try-it');
  assert.equal(doc.handoff.text, null);
  assert.equal(doc.handoff.path, 'b/../../outside.md');
  assert.match(doc.handoff.error, /outside\.md/);
  assert.match(doc.handoff.error, /outside the repository|\.\./);
});

test('load: a ticket that is not in the batch, or a ticket file that cannot be read, is an error that says so', async () => {
  const root = repo();
  const { tf } = files(root);
  await assert.rejects(tf.load('b', 'nope'), (e) => e.kind === 'no-ticket' && /nope/.test(e.message));
  await assert.rejects(tf.load('b', '07-try-it'), (e) => e.kind === 'read' && /07-try-it\.md/.test(e.message));
  await assert.rejects(tf.load('b', 7), (e) => e.kind === 'no-ticket');
});

test('load: a ticket the loop renamed to DONE_ is found by its name, at its new file', async () => {
  const root = repo();
  put(root, 'b/issues/DONE_08-agent.md', 'landed');
  const { tf } = files(root, { tickets: [{ name: '08-agent', file: 'b/issues/DONE_08-agent.md', human: false, done: true, handoff: null }] });
  assert.equal((await tf.load('b', '08-agent')).text, 'landed');
});

// ---- saving ----

test('save writes the file the ticket names, from the CLI\'s answer, and nothing else', async () => {
  const root = repo();
  put(root, 'b/issues/07-try-it.md', 'ticket');
  put(root, 'b/handoff/07-try-it.md', 'old\n');
  put(root, 'b/handoff/other.md', 'untouched');
  put(root, 'b/foreman.conf', 'conf');
  const { tf } = files(root);
  const out = await tf.save('b', '07-try-it', 'new\n', 'old\n');
  assert.deepEqual(out, { saved: true, text: 'new\n' });
  assert.equal(get(root, 'b/handoff/07-try-it.md'), 'new\n');
  assert.equal(get(root, 'b/handoff/other.md'), 'untouched');
  assert.equal(get(root, 'b/issues/07-try-it.md'), 'ticket');
  assert.equal(get(root, 'b/foreman.conf'), 'conf');
});

test('save asks the CLI for the path each time: the page has no way to name one', async () => {
  const root = repo();
  const { tf, asked } = files(root);
  await tf.save('b', '07-try-it', 'x', null);
  await tf.save('b', '07-try-it', 'y', 'x');
  assert.equal(asked.n, 2);
});

test('save refuses a ticket that is not a human ticket, or that has no Handoff: line', async () => {
  const root = repo();
  const { tf } = files(root);
  await assert.rejects(tf.save('b', '08-agent', 'x', null), (e) => e.kind === 'no-handoff');
  const none = files(root, status({ handoff: null }));
  await assert.rejects(none.tf.save('b', '07-try-it', 'x', null), (e) => e.kind === 'no-handoff');
  const done = files(root, status({ human: false }));
  await assert.rejects(done.tf.save('b', '07-try-it', 'x', null), (e) => e.kind === 'no-handoff');
  assert.deepEqual(fs.readdirSync(path.join(root, 'b', 'handoff')), []);
});

test('save refuses a path outside the repo — `..`, absolute, symlink — and writes nothing', async (t) => {
  const root = repo();
  const outside = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'foreman-outside-')));
  for (const bad of ['../outside.md', 'b/../../outside.md', '/tmp/outside.md', 'C:/outside.md']) {
    const { tf } = files(root, status({ handoff: bad }));
    await assert.rejects(tf.save('b', '07-try-it', 'x', null), refused, bad);
  }
  try { fs.symlinkSync(outside, path.join(root, 'b', 'link'), 'junction'); } catch (e) { t.diagnostic('no symlinks: ' + e.code); }
  if (fs.existsSync(path.join(root, 'b', 'link'))) {
    const { tf } = files(root, status({ handoff: 'b/link/x.md' }));
    await assert.rejects(tf.save('b', '07-try-it', 'x', null), refused, 'symlink');
  }
  assert.deepEqual(fs.readdirSync(outside), [], 'nothing was written outside');
  assert.ok(!fs.existsSync(path.join(path.dirname(root), 'outside.md')));
});

test('save refuses to overwrite the ticket itself, foreman.conf, or a folder', async () => {
  const root = repo();
  put(root, 'b/issues/07-try-it.md', 'ticket');
  put(root, 'b/foreman.conf', 'conf');
  for (const bad of ['b/issues/07-try-it.md', 'b/foreman.conf', 'b/handoff']) {
    const { tf } = files(root, status({ handoff: bad }));
    await assert.rejects(tf.save('b', '07-try-it', 'x', 'ticket'), refused, bad);
  }
  assert.equal(get(root, 'b/issues/07-try-it.md'), 'ticket');
  assert.equal(get(root, 'b/foreman.conf'), 'conf');
});

test('save keeps the file\'s line endings: CRLF stays CRLF, LF stays LF', async () => {
  const root = repo();
  put(root, 'b/handoff/07-try-it.md', 'one\r\ntwo\r\n');
  const { tf } = files(root);
  const out = await tf.save('b', '07-try-it', 'one\ntwo\nthree\n', 'one\r\ntwo\r\n');
  assert.equal(get(root, 'b/handoff/07-try-it.md'), 'one\r\ntwo\r\nthree\r\n');
  assert.equal(out.text, 'one\r\ntwo\r\nthree\r\n', 'what was written is what the page is now based on');
  put(root, 'b/handoff/07-try-it.md', 'one\ntwo\n');
  await tf.save('b', '07-try-it', 'a\r\nb', 'one\ntwo\n');
  assert.equal(get(root, 'b/handoff/07-try-it.md'), 'a\nb');
});

test('save writes LF for a file it creates, and the folder it needs', async () => {
  const root = repo();
  fs.rmSync(path.join(root, 'b', 'handoff'), { recursive: true });
  const { tf } = files(root, status({ handoff: 'b/handoff/deeper/07.md' }));
  await tf.save('b', '07-try-it', 'a\r\nb\r\n', null);
  assert.equal(get(root, 'b/handoff/deeper/07.md'), 'a\nb\n');
});

test('save does not overwrite a file that changed on disk since the page read it: it hands the new text back', async () => {
  const root = repo();
  put(root, 'b/handoff/07-try-it.md', 'what the person opened\n');
  const { tf } = files(root);
  put(root, 'b/handoff/07-try-it.md', 'changed in another editor\n');
  const out = await tf.save('b', '07-try-it', 'my edit\n', 'what the person opened\n');
  assert.deepEqual(out, { saved: false, conflict: true, disk: 'changed in another editor\n' });
  assert.equal(get(root, 'b/handoff/07-try-it.md'), 'changed in another editor\n', 'nothing was written');
  // The person says overwrite: the same save, based on what is on disk now.
  const again = await tf.save('b', '07-try-it', 'my edit\n', out.disk);
  assert.equal(again.saved, true);
  assert.equal(get(root, 'b/handoff/07-try-it.md'), 'my edit\n');
});

test('save: a file that appeared since the page saw none is a change too; one that vanished is a change', async () => {
  const root = repo();
  const { tf } = files(root);
  put(root, 'b/handoff/07-try-it.md', 'appeared\n');
  assert.deepEqual(await tf.save('b', '07-try-it', 'mine', null), { saved: false, conflict: true, disk: 'appeared\n' });
  fs.rmSync(path.join(root, 'b', 'handoff', '07-try-it.md'));
  assert.deepEqual(await tf.save('b', '07-try-it', 'mine', 'appeared\n'), { saved: false, conflict: true, disk: null });
  assert.equal((await tf.save('b', '07-try-it', 'mine', null)).saved, true);
});

test('save takes only text: no text, or a base that is neither text nor null, is refused before anything is read', async () => {
  const root = repo();
  const { tf, asked } = files(root);
  await assert.rejects(tf.save('b', '07-try-it', undefined, null), (e) => e.kind === 'bad-text');
  await assert.rejects(tf.save('b', '07-try-it', 'x', undefined), (e) => e.kind === 'bad-text');
  await assert.rejects(tf.save('b', '07-try-it', 'x'.repeat(2 * 1024 * 1024 + 1), null), (e) => e.kind === 'bad-text');
  assert.equal(asked.n, 0);
});

// ---- not asking foreman twice for what the overview just read ----

test('load uses the status the overview already read; it asks foreman only when that does not have the ticket', async () => {
  const root = repo();
  put(root, 'b/issues/07-try-it.md', 'ticket');
  const asked = { n: 0 };
  const foreman = { status: async () => { asked.n++; return status(); } };
  let cache = status();
  const tf = createTicketFiles({ repoRoot: root, foreman, known: (batch) => (batch === 'b' ? cache : null) });
  await tf.load('b', '07-try-it');
  await tf.load('b', '07-try-it');
  assert.equal(asked.n, 0, 'the cache answered');
  cache = { tickets: [] };
  await tf.load('b', '07-try-it');
  assert.equal(asked.n, 1, 'the cache did not know the ticket (renamed?), so foreman was asked');
  await tf.load('other', '07-try-it');
  assert.equal(asked.n, 2, 'a batch the cache is not of');
});

test('save never uses the cache: the path it writes is the CLI\'s answer of the moment', async () => {
  const root = repo();
  const foreman = { status: async () => status({ handoff: 'b/handoff/now.md' }) };
  const tf = createTicketFiles({ repoRoot: root, foreman, known: () => status({ handoff: 'b/handoff/stale.md' }) });
  await tf.save('b', '07-try-it', 'x', null);
  assert.equal(get(root, 'b/handoff/now.md'), 'x');
  assert.ok(!fs.existsSync(path.join(root, 'b', 'handoff', 'stale.md')));
});
