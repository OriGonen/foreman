'use strict';
// foreman.cjs: how the app asks the CLI, and what it makes of the answer. A fake runner stands in
// for Git Bash, so what is checked is the command line, the environment, the parsing and the
// error states — not foreman itself (test/smoke-json.sh does that).
const test = require('node:test');
const assert = require('node:assert/strict');
const { createForeman, parseOutput, checkBatchPath, cliEnv, ForemanError, SUPPORTED_JSON } = require('../foreman.cjs');

const good = { foreman_json: 1, command: 'status', batch: { path: 'b' }, counts: { done: 0, total: 1 } };

function setup(reply) {
  const calls = [];
  const run = async (file, args, opts) => { calls.push({ file, args, opts }); return typeof reply === 'function' ? reply(file, args, opts) : reply; };
  const f = createForeman({
    bash: 'C:\\Program Files\\Git\\bin\\bash.exe', checkout: 'C:/tools/foreman', repoRoot: 'C:/Projects/app',
    run, env: { PATH: 'C:\\Windows', SECRET_TOKEN: 'hunter2', FOREMAN_MAX_COST_USD: '5', FOREMAN_SHOW: 'always', SystemRoot: 'C:\\Windows' },
  });
  return { f, calls };
}

test('status runs bash on bin/foreman, from the repo root, with the batch repo-relative and --json last', async () => {
  const { f, calls } = setup({ code: 0, stdout: JSON.stringify(good) + '\n', stderr: '' });
  const r = await f.status('.scratch/gui');
  assert.deepEqual(r, good);
  assert.equal(calls[0].file, 'C:\\Program Files\\Git\\bin\\bash.exe');
  assert.deepEqual(calls[0].args, ['C:/tools/foreman/bin/foreman', 'status', '.scratch/gui', '--json']);
  assert.equal(calls[0].opts.cwd, 'C:/Projects/app');
  assert.equal(calls[0].opts.windowsHide, true);
});

test('statusAll asks for --json --all and names no batch', async () => {
  const all = { foreman_json: 1, command: 'status', all: true, batches: [] };
  const { f, calls } = setup({ code: 0, stdout: JSON.stringify(all), stderr: '' });
  assert.deepEqual(await f.statusAll(), all);
  assert.deepEqual(calls[0].args, ['C:/tools/foreman/bin/foreman', 'status', '--json', '--all']);
});

test('the environment: display variables forced, no locks, and no variable the CLI does not need', async () => {
  const { f, calls } = setup({ code: 0, stdout: JSON.stringify(good), stderr: '' });
  await f.status('b');
  const env = calls[0].opts.env;
  assert.equal(env.GIT_OPTIONAL_LOCKS, '0');
  assert.equal(env.FOREMAN_SHOW, 'never', 'forced over the user\'s own');
  assert.equal(env.FOREMAN_COLOR, 'never');
  assert.equal(env.FOREMAN_INTRO, 'never');
  assert.equal(env.PATH, 'C:\\Windows');
  assert.equal(env.FOREMAN_MAX_COST_USD, '5', 'a FOREMAN_ setting still beats foreman.conf, as in a terminal');
  assert.equal(env.SECRET_TOKEN, undefined, 'nothing else is passed on');
});

test('cliEnv keeps what Git Bash needs to start, and nothing like a token', () => {
  const env = cliEnv({ Path: 'x', SystemRoot: 'C:\\Windows', USERPROFILE: 'C:\\Users\\me', TEMP: 'C:\\T', ANTHROPIC_API_KEY: 'k', DOCKER_PAT: 'p', GITHUB_TOKEN: 't' });
  assert.equal(env.Path, 'x');
  assert.equal(env.SystemRoot, 'C:\\Windows');
  assert.equal(env.USERPROFILE, 'C:\\Users\\me');
  assert.equal(env.TEMP, 'C:\\T');
  for (const k of ['ANTHROPIC_API_KEY', 'DOCKER_PAT', 'GITHUB_TOKEN']) assert.equal(env[k], undefined, k);
});

test('a batch path must be repo-relative with forward slashes, and cannot reach out or look like a flag', () => {
  assert.equal(checkBatchPath('.scratch/gui'), '.scratch/gui');
  assert.equal(checkBatchPath('batch'), 'batch');
  for (const bad of ['', '--all', '-x', 'C:/x', 'C:\\x', '/abs', '../up', 'a/../../up', '.scratch\\gui', 'a\0b', 42, null, undefined]) {
    assert.throws(() => checkBatchPath(bad), (e) => e instanceof ForemanError && e.kind === 'bad-batch', String(bad));
  }
  assert.equal(checkBatchPath('a/./b'), 'a/./b', 'a dot segment inside is harmless');
});

test('a non-zero exit is an error carrying the CLI\'s own words', async () => {
  const { f } = setup({ code: 1, stdout: '', stderr: 'foreman: no such directory: nope\n' });
  await assert.rejects(f.status('nope'), (e) => e.kind === 'exit' && e.code === 1 && /no such directory/.test(e.stderr) && /no such directory/.test(e.message));
});

test('a non-zero exit with nothing on stderr still says what happened', async () => {
  const { f } = setup({ code: 3, stdout: '', stderr: '' });
  await assert.rejects(f.status('b'), (e) => e.kind === 'exit' && /exited 3/.test(e.message));
});

test('stdout that is not JSON, or not an object, is a parse error', async () => {
  for (const stdout of ['', 'hello', '[1]', '"x"', '{"foreman_json":1,']) {
    const { f } = setup({ code: 0, stdout, stderr: '' });
    await assert.rejects(f.status('b'), (e) => e.kind === 'parse', JSON.stringify(stdout));
  }
});

test('a foreman_json the app does not know is refused, saying which it expected', async () => {
  const { f } = setup({ code: 0, stdout: JSON.stringify({ ...good, foreman_json: 2 }), stderr: '' });
  await assert.rejects(f.status('b'), (e) => e.kind === 'version' && /2/.test(e.message) && new RegExp(String(SUPPORTED_JSON)).test(e.message));
  const missing = setup({ code: 0, stdout: JSON.stringify({ command: 'status' }), stderr: '' });
  await assert.rejects(missing.f.status('b'), (e) => e.kind === 'version');
});

test('an answer to another command is refused', async () => {
  const { f } = setup({ code: 0, stdout: JSON.stringify({ ...good, command: 'doctor' }), stderr: '' });
  await assert.rejects(f.status('b'), (e) => e.kind === 'version' && /doctor/.test(e.message));
});

test('bash that cannot be started is its own error, with what was tried to start', async () => {
  const { f } = setup(() => { throw Object.assign(new Error('spawn ENOENT'), { code: 'ENOENT' }); });
  await assert.rejects(f.status('b'), (e) => e.kind === 'spawn' && /ENOENT/.test(e.message));
});

test('parseOutput is the whole of the parsing', () => {
  assert.deepEqual(parseOutput('status', { code: 0, stdout: JSON.stringify(good), stderr: '' }), good);
  assert.throws(() => parseOutput('status', { code: 2, stdout: '', stderr: 'x' }), ForemanError);
});

// ---- findRepoRoot: the directory the app was opened on -> the repository's root ----

const { findRepoRoot } = require('../foreman.cjs');

test('findRepoRoot asks git, through Git Bash, from the directory it was given', async () => {
  const calls = [];
  const run = async (file, args, opts) => { calls.push({ file, args, opts }); return { code: 0, stdout: 'C:/Projects/app\n', stderr: '' }; };
  const root = await findRepoRoot({ bash: 'C:\\Git\\bin\\bash.exe', dir: 'C:\\Projects\\app\\sub', run, env: { PATH: 'C:\\Windows', TOKEN: 'x' } });
  assert.equal(root, 'C:/Projects/app');
  assert.equal(calls[0].file, 'C:\\Git\\bin\\bash.exe');
  assert.deepEqual(calls[0].args, ['-c', 'git rev-parse --show-toplevel']);
  assert.equal(calls[0].opts.cwd, 'C:\\Projects\\app\\sub');
  assert.equal(calls[0].opts.env.GIT_OPTIONAL_LOCKS, '0');
  assert.equal(calls[0].opts.env.TOKEN, undefined);
});

test('findRepoRoot: a backslash path is given back with forward slashes, and a trailing newline is dropped', async () => {
  const run = async () => ({ code: 0, stdout: 'C:\\Projects\\app\r\n', stderr: '' });
  assert.equal(await findRepoRoot({ bash: 'b', dir: 'd', run }), 'C:/Projects/app');
});

test('findRepoRoot: not a repository is its own error, with git\'s words', async () => {
  const run = async () => ({ code: 128, stdout: '', stderr: 'fatal: not a git repository (or any of the parent directories): .git\n' });
  await assert.rejects(findRepoRoot({ bash: 'b', dir: 'd', run }), (e) => {
    assert.equal(e.kind, 'not-a-repo');
    assert.match(e.message, /not a git repository/);
    return true;
  });
});

test('findRepoRoot: Git Bash that cannot start is a spawn error; an empty answer is not a root', async () => {
  const boom = async () => { throw new Error('ENOENT'); };
  await assert.rejects(findRepoRoot({ bash: 'b', dir: 'd', run: boom }), (e) => e.kind === 'spawn');
  const empty = async () => ({ code: 0, stdout: '\n', stderr: '' });
  await assert.rejects(findRepoRoot({ bash: 'b', dir: 'd', run: empty }), (e) => e.kind === 'not-a-repo');
});

// ---- dry-run ----

const dry = { foreman_json: 1, command: 'dry-run', batch: { path: 'b' }, prompt: null };

test('dryRun runs bash on bin/foreman dry-run, from the repo root, the batch repo-relative and --json last', async () => {
  const { f, calls } = setup({ code: 0, stdout: JSON.stringify(dry) + '\n', stderr: '' });
  assert.deepEqual(await f.dryRun('.scratch/gui'), dry);
  assert.deepEqual(calls[0].args, ['C:/tools/foreman/bin/foreman', 'dry-run', '.scratch/gui', '--json']);
  assert.equal(calls[0].opts.cwd, 'C:/Projects/app');
  assert.equal(calls[0].opts.env.SECRET_TOKEN, undefined, 'nothing the CLI does not need is passed on');
});

test('dryRun takes a batch path the same way status does, and refuses a flag or a path out of the repository', () => {
  const { f, calls } = setup({ code: 0, stdout: JSON.stringify(dry), stderr: '' });
  for (const bad of ['', '--all', '../up', 'C:/x', null, undefined]) {
    assert.throws(() => f.dryRun(bad), (e) => e instanceof ForemanError && e.kind === 'bad-batch', String(bad));
  }
  assert.equal(calls.length, 0, 'nothing was run');
});

test('dryRun: the CLI\'s own words when it fails (a dirty tree), and a status answer is not a dry-run answer', async () => {
  const dirty = setup({ code: 1, stdout: '', stderr: 'foreman: the working tree is dirty.\n' });
  await assert.rejects(() => dirty.f.dryRun('b'), (e) => e.kind === 'exit' && e.message === 'foreman: the working tree is dirty.');
  const wrong = setup({ code: 0, stdout: JSON.stringify(good), stderr: '' });
  await assert.rejects(() => wrong.f.dryRun('b'), (e) => e.kind === 'version' && /asked for dry-run/.test(e.message));
});
