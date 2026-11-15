'use strict';
// Which of the six states fills the pane, from what main read: the overview answer (or the error that
// stood in for it) and the `conditions` main attached. The words of each state's message are the
// CLI's, passed through untouched; the app's own words are only the sentence around them.
const test = require('node:test');
const assert = require('node:assert/strict');
const S = require('../states.js');
const { sample } = require('./sample.cjs');

const okData = (over = {}) => ({
  ok: true, repoRoot: 'C:/Projects/app', selected: '.scratch/b', status: sample(), statusError: null,
  all: { batches: [{ path: '.scratch/b', name: 'b', finished: false, counts: { done: 4, total: 10 }, error: null }] },
  conditions: null, ...over,
});

test('with nothing wrong, there is no state: the overview shows', () => {
  assert.equal(S.choose(okData()), null);
  assert.equal(S.choose(okData({ conditions: { login: null, runners: null } })), null);
});

test('not a git repo: git\'s own words, the folder, and Choose a folder…', () => {
  const s = S.choose({ ok: false, error: { kind: 'not-a-repo', message: 'fatal: not a git repository (or any of the parent directories): .git', dir: 'C:\\Users\\me\\Downloads' } });
  assert.equal(s.id, 'not-a-repo');
  assert.equal(s.whole, true);
  assert.equal(s.message, 'fatal: not a git repository (or any of the parent directories): .git');
  assert.deepEqual(s.detail, { kind: 'path', text: 'C:\\Users\\me\\Downloads' });
  assert.equal(s.action.do, 'choose-folder');
  assert.equal(s.action.label, 'Choose a folder…');
  assert.equal(s.action.tag, undefined);
});

test('not a git repo without a folder in the error shows no path line', () => {
  const s = S.choose({ ok: false, error: { kind: 'not-a-repo', message: 'x' } });
  assert.equal(s.detail, null);
});

test('no batch: the foreman init command, and a button that copies it', () => {
  const s = S.choose(okData({ all: { batches: [] }, selected: null, status: null }));
  assert.equal(s.id, 'no-batch');
  assert.equal(s.whole, true);
  assert.equal(s.detail.kind, 'command');
  assert.equal(s.detail.text, S.INIT_COMMAND);
  assert.equal(S.INIT_COMMAND, 'foreman init .scratch/<name>');
  assert.deepEqual([s.action.do, s.action.label], ['copy-command', 'Copy command']);
});

test('Git Bash missing: every path it looked in, and Look again', () => {
  const tried = ['C:\\a\\bash.exe (FOREMAN_BASH)', 'git.exe on PATH (not found)', 'C:\\Program Files\\Git\\bin\\bash.exe'];
  const s = S.choose({ ok: false, error: { kind: 'git-bash-missing', message: 'foreman runs in Git Bash, and none was found.', tried } });
  assert.equal(s.id, 'git-bash-missing');
  assert.equal(s.message, 'foreman runs in Git Bash, and none was found.');
  assert.deepEqual(s.detail, { kind: 'tried', lines: tried });
  assert.deepEqual([s.action.do, s.action.label], ['look-again', 'Look again']);
});

test('other failures are not one of the six: the generic failure screen keeps them', () => {
  for (const kind of ['exit', 'spawn', 'parse', 'version']) assert.equal(S.choose({ ok: false, error: { kind, message: 'm' } }), null);
  assert.equal(S.choose(null), null);
});

test('batch unreadable: the CLI\'s stderr as text, and a button that opens the file it names', () => {
  const said = 'foreman-next.sh: .scratch/b/order.md lists a ticket that does not exist: .scratch/b/issues/03-nope.md';
  const s = S.choose(okData({ status: null, statusError: said }));
  assert.equal(s.id, 'batch-unreadable');
  assert.equal(s.message, said);
  assert.equal(s.action.do, 'open-file');
  assert.equal(s.action.file, '.scratch/b/order.md');
  assert.equal(s.action.label, 'Open order.md in editor');
});

test('batch unreadable: with no file named, the button opens the batch folder', () => {
  const s = S.choose(okData({ status: null, statusError: 'foreman: something odd' }));
  assert.equal(s.action.do, 'open-file');
  assert.equal(s.action.file, '.scratch/b');
  assert.equal(s.action.label, 'Open the batch folder');
});

test('batch unreadable: a file the message names that leaves the repository is not offered', () => {
  for (const said of ['x C:/Windows/win.ini.md y', 'x ../../etc/passwd.md y', 'x /etc/hosts.md y']) {
    const s = S.choose(okData({ status: null, statusError: said }));
    assert.equal(s.action.file, '.scratch/b', said);
  }
});

test('batch unreadable: the first .md file named is the one opened, backslashes read as slashes', () => {
  const s = S.choose(okData({ status: null, statusError: 'bad: .scratch\\b\\issues\\02-x.md then order.md' }));
  assert.equal(s.action.file, '.scratch/b/issues/02-x.md');
});

test('runner missing: the doctor\'s words, the mode, runs off, and a Doctor button; whole pane it is not', () => {
  const c = { batch: '.scratch/b', tool: 'sbx', mode: 'sandbox', message: 'sbx is not on PATH, and FOREMAN_EXEC=sandbox needs it', fix: 'Install sbx and put it on PATH' };
  const s = S.choose(okData({ conditions: { runners: c, login: null } }));
  assert.equal(s.id, 'runner-missing');
  assert.equal(s.whole, false);
  assert.equal(s.message, 'sbx is not on PATH, and FOREMAN_EXEC=sandbox needs it\nInstall sbx and put it on PATH');
  assert.equal(s.heading, "sbx isn't installed");
  assert.ok(s.sentence.includes('FOREMAN_EXEC=sandbox'));
  assert.deepEqual([s.action.do, s.action.label, s.action.tag], ['doctor', 'Doctor', { cls: 'free', text: 'free' }]);
  assert.equal(S.startBlock(okData({ conditions: { runners: c, login: null } })), 'sbx is not on PATH, and FOREMAN_EXEC=sandbox needs it');
});

test('runner missing for another batch than the one shown is ignored', () => {
  const c = { batch: '.scratch/c', tool: 'sbx', mode: 'sandbox', message: 'm', fix: null };
  assert.equal(S.choose(okData({ conditions: { runners: c, login: null } })), null);
  assert.equal(S.startBlock(okData({ conditions: { runners: c, login: null } })), null);
});

test('login expired: exit 20 and auth_failed, the loop\'s own reason, and Resume… that costs money', () => {
  const c = { batch: '.scratch/b', runId: '20261021-2', exit: 20, message: '06-x.md was not attempted: the agent could not authenticate' };
  const s = S.choose(okData({ conditions: { runners: null, login: c } }));
  assert.equal(s.id, 'login-expired');
  assert.equal(s.whole, false);
  assert.equal(s.message, c.message);
  assert.ok(s.sentence.includes('20261021-2') && s.sentence.includes('exit 20') && s.sentence.includes('auth_failed'));
  assert.deepEqual([s.action.do, s.action.label, s.action.tag], ['resume', 'Resume…', { cls: 'paid', text: 'costs money' }]);
});

test('login expired with no reason line says only what the record says', () => {
  const s = S.choose(okData({ conditions: { runners: null, login: { batch: '.scratch/b', runId: 'r', exit: 20, message: null } } }));
  assert.equal(s.message, null);
});

test('login expired is not shown while a run is in flight', () => {
  const d = okData({ conditions: { runners: null, login: { batch: '.scratch/b', runId: 'r', exit: 20, message: 'm' } } });
  d.status.run = { in_flight: true };
  assert.equal(S.choose(d), null);
});

test('when both hold, runs are off, so that is the one shown', () => {
  const d = okData({ conditions: {
    runners: { batch: '.scratch/b', tool: 'claude', mode: 'local', message: 'claude is not on PATH, and FOREMAN_EXEC=local needs it', fix: null },
    login: { batch: '.scratch/b', runId: 'r', exit: 20, message: 'm' } } });
  assert.equal(S.choose(d).id, 'runner-missing');
});

test('the state whole-pane wins over the unreadable one only when there is no batch at all', () => {
  assert.equal(S.choose(okData({ all: { batches: [] }, selected: null, status: null, statusError: 'x' })).id, 'no-batch');
});
