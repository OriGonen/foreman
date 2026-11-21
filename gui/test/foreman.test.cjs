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

// ---- report ----

const rep = { foreman_json: 1, command: 'report', batch: { path: 'b', name: 'b' }, by: 'run', rows: [] };

test('report runs bin/foreman report from the repo root: the batch repo-relative, --json, and --by-ticket / --run only when asked', async () => {
  const { f, calls } = setup({ code: 0, stdout: JSON.stringify(rep) + '\n', stderr: '' });
  assert.deepEqual(await f.report('.scratch/gui'), rep);
  assert.deepEqual(calls[0].args, ['C:/tools/foreman/bin/foreman', 'report', '.scratch/gui', '--json']);
  assert.equal(calls[0].opts.cwd, 'C:/Projects/app');
  await f.report('.scratch/gui', { byTicket: true });
  assert.deepEqual(calls[1].args, ['C:/tools/foreman/bin/foreman', 'report', '.scratch/gui', '--json', '--by-ticket']);
  await f.report('.scratch/gui', { run: '20261021T091200Z-4411' });
  assert.deepEqual(calls[2].args, ['C:/tools/foreman/bin/foreman', 'report', '.scratch/gui', '--json', '--run', '20261021T091200Z-4411']);
  await f.report('.scratch/gui', { byTicket: false, run: null });
  assert.deepEqual(calls[3].args, ['C:/tools/foreman/bin/foreman', 'report', '.scratch/gui', '--json'], 'false and null ask for nothing');
});

test('report takes a batch path the way status does, and a run id that cannot be read as a flag or a shell word', () => {
  const { f, calls } = setup({ code: 0, stdout: JSON.stringify(rep), stderr: '' });
  for (const bad of ['', '--all', '../up', 'C:/x', null, undefined]) {
    assert.throws(() => f.report(bad), (e) => e instanceof ForemanError && e.kind === 'bad-batch', String(bad));
  }
  for (const bad of ['', '--json', '-x', 'a b', 'a;b', '$(x)', 'a\nb', 'a\0b', 7, {}, '../x']) {
    assert.throws(() => f.report('b', { run: bad }), (e) => e instanceof ForemanError && e.kind === 'bad-run', JSON.stringify(bad));
  }
  assert.equal(calls.length, 0, 'nothing was run');
});

test('report accepts the run ids the loop writes, and the one a record with no id is filed under', async () => {
  const { f, calls } = setup({ code: 0, stdout: JSON.stringify(rep), stderr: '' });
  for (const ok of ['20261021T091200Z-4411', '20261021T091200Z-4411-with-a-long-name', '(unknown)', 'run_1.2']) {
    await f.report('b', { run: ok });
  }
  assert.equal(calls.length, 4);
});

test('report: the CLI\'s own words when there is no log, and a status answer is not a report answer', async () => {
  const none = setup({ code: 1, stdout: '', stderr: 'No run log at b/foreman-runs.jsonl — nothing has been run for this batch yet.\n' });
  await assert.rejects(() => none.f.report('b'), (e) => e.kind === 'exit' && /nothing has been run/.test(e.message));
  const wrong = setup({ code: 0, stdout: JSON.stringify(good), stderr: '' });
  await assert.rejects(() => wrong.f.report('b'), (e) => e.kind === 'version' && /asked for report/.test(e.message));
});

test('report with no options, or null, asks for the default view', async () => {
  const { f, calls } = setup({ code: 0, stdout: JSON.stringify(rep), stderr: '' });
  await f.report('b', null);
  await f.report('b', undefined);
  assert.deepEqual(calls.map((c) => c.args.slice(1)), [['report', 'b', '--json'], ['report', 'b', '--json']]);
});

// ---- doctor ----

const doc = { foreman_json: 1, command: 'doctor', sections: [], verdict: { passed: true } };

test('doctor runs bin/foreman doctor --json from the repo root, and doctorFix adds --fix before it; neither names a batch', async () => {
  const { f, calls } = setup({ code: 0, stdout: JSON.stringify(doc) + '\n', stderr: '' });
  assert.deepEqual(await f.doctor(), doc);
  assert.deepEqual(calls[0].args, ['C:/tools/foreman/bin/foreman', 'doctor', '--json']);
  assert.equal(calls[0].opts.cwd, 'C:/Projects/app');
  assert.deepEqual(await f.doctorFix(), doc);
  assert.deepEqual(calls[1].args, ['C:/tools/foreman/bin/foreman', 'doctor', '--fix', '--json']);
});

test('doctor: the environment is the one every question gets (no display, no stray secret), and the CLI\'s words when it fails', async () => {
  const { f, calls } = setup({ code: 0, stdout: JSON.stringify(doc), stderr: '' });
  await f.doctor();
  assert.equal(calls[0].opts.env.FOREMAN_SHOW, 'never');
  assert.equal(calls[0].opts.env.SECRET_TOKEN, undefined);
  const outside = setup({ code: 1, stdout: '', stderr: 'foreman doctor: not inside a git repository.\n' });
  await assert.rejects(() => outside.f.doctor(), (e) => e.kind === 'exit' && /not inside a git repository/.test(e.message));
  const wrong = setup({ code: 0, stdout: JSON.stringify(good), stderr: '' });
  await assert.rejects(() => wrong.f.doctorFix(), (e) => e.kind === 'version' && /asked for doctor/.test(e.message));
});

// ---- steering a run: keys, stop, and whether the control directory can be reached (ticket 10) ----

test('keys: foreman keys <batch> <keys>, no --json, and the terminal\'s echo on stderr is cleaned', async () => {
  const { f, calls } = setup({ code: 0, stdout: '', stderr: '\r\u001b[2K⌨ iterations: 1 of 4\n' });
  const r = await f.keys('.scratch/gui', '+');
  assert.deepEqual(calls[0].args, ['C:/tools/foreman/bin/foreman', 'keys', '.scratch/gui', '+']);
  assert.equal(calls[0].opts.cwd, 'C:/Projects/app');
  assert.equal(r.stderr, '⌨ iterations: 1 of 4');
  await f.keys('.scratch/gui', '-');
  assert.deepEqual(calls[1].args.slice(1), ['keys', '.scratch/gui', '-'], 'a lone - is a key, not an option');
});

test('keys: only +, -, = , _, L and l are passed on; a batch that is not a repo path never reaches the CLI', async () => {
  const { f, calls } = setup({ code: 0, stdout: '', stderr: '' });
  for (const bad of ['', 'x', '+x', '; rm -rf /', '--now', undefined, 3]) {
    await assert.rejects(async () => f.keys('b', bad), (e) => e.kind === 'bad-keys', String(bad));
  }
  await assert.rejects(async () => f.keys('../out', '+'), (e) => e.kind === 'bad-batch');
  await assert.rejects(async () => f.keys('--help', '+'), (e) => e.kind === 'bad-batch');
  assert.equal(calls.length, 0);
});

test('keys and stop that fail say what the CLI said, as an exit error', async () => {
  const { f } = setup({ code: 1, stdout: '', stderr: 'foreman keys: no run in flight in batch b\n' });
  await assert.rejects(f.keys('b', 'L'), (e) => e.kind === 'exit' && e.message === 'foreman keys: no run in flight in batch b' && e.code === 1);
  await assert.rejects(f.stop('b'), (e) => e.kind === 'exit' && /no run in flight/.test(e.message));
});

test('stop: foreman stop <batch>; with now, --now before the batch', async () => {
  const { f, calls } = setup({ code: 0, stdout: 'foreman stop: the run will stop after iteration 2\n', stderr: '' });
  const r = await f.stop('.scratch/gui');
  assert.deepEqual(calls[0].args, ['C:/tools/foreman/bin/foreman', 'stop', '.scratch/gui']);
  assert.match(r.stdout, /will stop after iteration 2/);
  await f.stop('.scratch/gui', { now: true });
  assert.deepEqual(calls[1].args, ['C:/tools/foreman/bin/foreman', 'stop', '--now', '.scratch/gui']);
  await assert.rejects(async () => f.stop('a b\\c'), (e) => e.kind === 'bad-batch');
});

// ---- time limits ----

const { defaultRun, CALL_TIMEOUT_MS } = require('../foreman.cjs');

test('every CLI call is given a timeout and a kill signal; stop --now is given longer', async () => {
  const ok = { code: 0, stdout: JSON.stringify(good), stderr: '' };
  const { f, calls } = setup(ok);
  await f.status('b');
  await f.keys('b', '+');
  await f.stop('b');
  await f.stop('b', { now: true });
  for (const c of calls) {
    assert.equal(c.opts.killSignal, 'SIGKILL', c.args.join(' '));
    assert.ok(c.opts.timeout >= 30000, `a generous timeout: ${c.args.join(' ')}`);
  }
  assert.equal(CALL_TIMEOUT_MS, 60000);
  assert.equal(calls[0].opts.timeout, CALL_TIMEOUT_MS);
  assert.ok(calls[3].opts.timeout > calls[2].opts.timeout, '`stop --now` waits up to a minute for the run itself');
});

test('defaultRun: a process that outlives its timeout is killed and rejects with a clear ForemanError', async () => {
  const t0 = Date.now();
  await assert.rejects(
    defaultRun(process.execPath, ['-e', 'setTimeout(() => {}, 30000)'], { timeout: 300 }),
    (e) => e instanceof ForemanError && e.kind === 'timeout' && /did not answer within/.test(e.message),
  );
  assert.ok(Date.now() - t0 < 10000, 'and it did not wait for the process');
});

test('defaultRun still resolves with the exit code and streams for a process that finishes (and fails)', async () => {
  const r = await defaultRun(process.execPath, ['-e', 'console.log("hi"); process.exit(3)'], {});
  assert.equal(r.code, 3);
  assert.match(r.stdout, /hi/);
});

test('a timed-out call is a timeout, not "could not start bash", whichever call it was', async () => {
  const hung = () => { throw new ForemanError('timeout', 'foreman did not answer within 60 s and was stopped'); };
  const { f } = setup(hung);
  for (const ask of [() => f.status('b'), () => f.keys('b', '+'), () => f.stop('b'), () => f.doctor()]) {
    await assert.rejects(ask(), (e) => e.kind === 'timeout' && !/could not start/.test(e.message));
  }
  await assert.rejects(findRepoRoot({ bash: 'b', dir: 'd', run: hung }), (e) => e.kind === 'timeout');
});
