'use strict';
// Where the app finds Git Bash (spec: "Windows paths"). Plain Node, no Electron: the lookup takes
// the environment and a "does this file exist" question, so every order below is a table.
const test = require('node:test');
const assert = require('node:assert/strict');
const { findGitBash, isWslLauncher } = require('../bash.cjs');

const PF = 'C:\\Program Files\\Git\\bin\\bash.exe';

// A fake disk: exists() answers for exactly these paths.
const disk = (...files) => { const s = new Set(files.map((f) => f.toLowerCase())); return (p) => s.has(p.toLowerCase()); };

test('FOREMAN_BASH comes first, when it is there', () => {
  const r = findGitBash({
    env: { FOREMAN_BASH: 'D:\\tools\\bash.exe', PATH: 'C:\\Git\\cmd' },
    exists: disk('D:\\tools\\bash.exe', 'C:\\Git\\cmd\\git.exe', 'C:\\Git\\bin\\bash.exe', PF),
  });
  assert.equal(r.bash, 'D:\\tools\\bash.exe');
});

test('FOREMAN_BASH that is not there falls through to git.exe on PATH', () => {
  const r = findGitBash({
    env: { FOREMAN_BASH: 'D:\\gone\\bash.exe', PATH: 'C:\\Windows;C:\\Git\\cmd' },
    exists: disk('C:\\Git\\cmd\\git.exe', 'C:\\Git\\bin\\bash.exe', PF),
  });
  assert.equal(r.bash, 'C:\\Git\\bin\\bash.exe');
});

test('git.exe on PATH resolves to <git root>\\bin\\bash.exe, from cmd\\, bin\\ or mingw64\\bin\\', () => {
  for (const dir of ['C:\\Git\\cmd', 'C:\\Git\\bin', 'C:\\Git\\mingw64\\bin', 'C:\\Git\\usr\\bin']) {
    const r = findGitBash({
      env: { PATH: `C:\\Windows;${dir}` },
      exists: disk(`${dir}\\git.exe`, 'C:\\Git\\bin\\bash.exe'),
    });
    assert.equal(r.bash, 'C:\\Git\\bin\\bash.exe', dir);
  }
});

test('the PATH variable may be spelled Path, and an empty entry or a trailing ; is ignored', () => {
  const r = findGitBash({
    env: { Path: ';C:\\Git\\cmd;' },
    exists: disk('C:\\Git\\cmd\\git.exe', 'C:\\Git\\bin\\bash.exe'),
  });
  assert.equal(r.bash, 'C:\\Git\\bin\\bash.exe');
});

test('git.exe found but no bash.exe beside it: on to Program Files', () => {
  const r = findGitBash({ env: { PATH: 'C:\\Git\\cmd' }, exists: disk('C:\\Git\\cmd\\git.exe', PF) });
  assert.equal(r.bash, PF);
});

test('with neither, Program Files is the last resort', () => {
  const r = findGitBash({ env: { PATH: 'C:\\Windows' }, exists: disk(PF) });
  assert.equal(r.bash, PF);
});

test('never a WSL launcher: not from FOREMAN_BASH, and not just because it is on PATH', () => {
  for (const wsl of ['C:\\Windows\\System32\\bash.exe', 'C:\\Windows\\Sysnative\\bash.exe',
    'C:\\Users\\me\\AppData\\Local\\Microsoft\\WindowsApps\\bash.exe']) {
    const r = findGitBash({
      env: { FOREMAN_BASH: wsl, PATH: 'C:\\Windows\\System32;C:\\Users\\me\\AppData\\Local\\Microsoft\\WindowsApps' },
      exists: disk(wsl, 'C:\\Windows\\System32\\bash.exe', PF),
    });
    assert.equal(r.bash, PF, wsl);
  }
  assert.equal(isWslLauncher('c:/windows/system32/BASH.EXE'), true, 'forward slashes and case');
  assert.equal(isWslLauncher('C:\\Program Files\\Git\\bin\\bash.exe'), false);
  assert.equal(isWslLauncher('D:\\Windows\\tools\\bash.exe'), false, 'only the two launcher directories');
});

test('a WSL launcher given as FOREMAN_BASH with nothing else to find: nothing found, and it says why', () => {
  const r = findGitBash({
    env: { FOREMAN_BASH: 'C:\\Windows\\System32\\bash.exe', PATH: '' },
    exists: disk('C:\\Windows\\System32\\bash.exe'),
  });
  assert.equal(r.bash, null);
  assert.match(r.tried.join('\n'), /System32.*WSL/i);
});

test('nothing found: null, and the paths it tried, in the order it tried them', () => {
  const r = findGitBash({ env: { FOREMAN_BASH: 'D:\\x\\bash.exe', PATH: 'C:\\Windows' }, exists: disk() });
  assert.equal(r.bash, null);
  assert.deepEqual(r.tried, ['D:\\x\\bash.exe (FOREMAN_BASH)', 'git.exe on PATH (not found)', PF]);
});

test('no FOREMAN_BASH and no PATH at all', () => {
  const r = findGitBash({ env: {}, exists: disk() });
  assert.equal(r.bash, null);
  assert.deepEqual(r.tried, ['git.exe on PATH (not found)', PF]);
});
