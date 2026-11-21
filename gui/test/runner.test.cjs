'use strict';
// runner.cjs: the process the app starts for a run — its arguments, its environment, where its words
// go, and that the app does not wait on it. A fake spawn stands in for child_process.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { spawnSync } = require('node:child_process');
const { createRunner, spawnPlan, checkRequest, bashGit } = require('../runner.cjs');

const BASH = 'C:\\Program Files\\Git\\bin\\bash.exe';
const ENV = { PATH: 'C:\\Windows', SECRET_TOKEN: 'hunter2', FOREMAN_SHOW: 'always', FOREMAN_COLOR: 'always', GIT_OPTIONAL_LOCKS: '1', SystemRoot: 'C:\\Windows' };

// What git says in a repository that ignores **/.foreman-run/ (check-ignore exits 0): the control
// directory is the batch's own, as it always was.
const IGNORED = () => ({ status: 0, stdout: '' });

function rig(over = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'runner-'));
  fs.mkdirSync(path.join(root, 'b'));
  const spawned = [];
  const spawn = (file, args, opts) => {
    const child = new EventEmitter();
    child.pid = 4242; child.unrefd = false; child.unref = () => { child.unrefd = true; };
    spawned.push({ file, args, opts, child });
    if (over.error) setImmediate(() => child.emit('error', Object.assign(new Error('spawn ENOENT'), { code: 'ENOENT' })));
    else setImmediate(() => child.emit('spawn'));
    return child;
  };
  const runner = createRunner({ bash: BASH, checkout: 'C:\\tools\\foreman', repoRoot: root.replace(/\\/g, '/'), env: ENV, spawn, git: over.git || IGNORED });
  return { root, spawned, runner };
}

test('spawn: bash on bin/foreman run <batch> <n> --live, detached, hidden, stdin ignored, from the repo root', async () => {
  const { root, spawned, runner } = rig();
  const r = await runner.start('b', { iterations: 3, live: true });
  assert.equal(r.pid, 4242);
  const s = spawned[0];
  assert.equal(s.file, BASH);
  assert.deepEqual(s.args, ['C:/tools/foreman/bin/foreman', 'run', 'b', '3', '--live']);
  assert.equal(s.opts.detached, true);
  assert.equal(s.opts.windowsHide, true);
  assert.equal(s.opts.cwd, root.replace(/\\/g, '/'));
  assert.equal(s.opts.stdio[0], 'ignore');
  assert.equal(typeof s.opts.stdio[1], 'number');
  assert.equal(s.opts.stdio[1], s.opts.stdio[2], 'stdout and stderr go to the same file');
  assert.equal(s.child.unrefd, true, 'the app does not wait on it');
});

test('spawn env: the run is told not to draw, not to colour and not to take optional locks, over the person\'s own', async () => {
  const { spawned, runner } = rig();
  await runner.start('b', { iterations: 1, live: true });
  const env = spawned[0].opts.env;
  assert.equal(env.FOREMAN_SHOW, 'never');
  assert.equal(env.FOREMAN_COLOR, 'never');
  assert.equal(env.GIT_OPTIONAL_LOCKS, '0');
  assert.equal(env.PATH, 'C:\\Windows', 'what Git Bash needs to start');
  assert.equal(env.SECRET_TOKEN, 'hunter2', 'the whole environment is passed on: the run is the person own, as in a terminal');
  assert.equal(env.FOREMAN_MAX_COST_USD, undefined, 'no edit, no cap in the environment: foreman.conf decides');
  assert.equal(env.FOREMAN_MAX_MINUTES, undefined);
});

test('an edited cap is passed to this run in its environment, and only that', async () => {
  const { spawned, runner } = rig();
  await runner.start('b', { iterations: null, live: false, caps: { cost: '$7.50', minutes: '030' } });
  const s = spawned[0];
  assert.deepEqual(s.args.slice(1), ['run', 'b', '--unlimited']);
  assert.equal(s.opts.env.FOREMAN_MAX_COST_USD, '7.50');
  assert.equal(s.opts.env.FOREMAN_MAX_MINUTES, '30');
  assert.equal(ENV.FOREMAN_MAX_COST_USD, undefined, 'the app\'s own environment is not changed');
  assert.equal(process.env.FOREMAN_MAX_COST_USD, undefined);
});

test('the run\'s words go to <batch>/.foreman-run/out, which is made, and is replaced by the next run', async () => {
  const { root, runner } = rig();
  const out = path.join(root, 'b', '.foreman-run', 'out');
  await runner.start('b', { iterations: 1, live: true });
  assert.ok(fs.existsSync(out), 'the file exists for the run to write to');
  fs.writeFileSync(out, 'preflight: the working tree is dirty.\n\u001b[31mcolour\u001b[0m\n');
  assert.equal(runner.readOut('b'), 'preflight: the working tree is dirty.\ncolour');
  await runner.start('b', { iterations: 1, live: true });
  assert.equal(fs.readFileSync(out, 'utf8'), '', 'the previous run\'s text is gone');
  assert.equal(runner.readOut('nope'), null);
  assert.equal(runner.readOut('b'), '');
});

test('foreman.conf is not written', async () => {
  const { root, runner } = rig();
  const conf = path.join(root, 'b', 'foreman.conf');
  fs.writeFileSync(conf, 'FOREMAN_MAX_COST_USD=25\n');
  const before = fs.statSync(conf).mtimeMs;
  await runner.start('b', { iterations: 1, live: true, caps: { cost: '5' } });
  assert.equal(fs.readFileSync(conf, 'utf8'), 'FOREMAN_MAX_COST_USD=25\n');
  assert.equal(fs.statSync(conf).mtimeMs, before);
});

test('a request that is not understood, or a batch that is not a repo path, starts nothing', async () => {
  const { spawned, runner } = rig();
  for (const bad of [{ iterations: 0 }, { iterations: 1, caps: { cost: 'free' } }, {}, null]) {
    await assert.rejects(async () => runner.start('b', bad), (e) => e.kind === 'bad-request', JSON.stringify(bad));
  }
  await assert.rejects(async () => runner.start('../x', { iterations: 1 }), (e) => e.kind === 'bad-batch');
  await assert.rejects(async () => runner.start('--help', { iterations: 1 }), (e) => e.kind === 'bad-batch');
  await assert.rejects(async () => runner.start('C:/x', { iterations: 1 }), (e) => e.kind === 'bad-batch');
  assert.equal(spawned.length, 0);
  assert.throws(() => checkRequest({ iterations: 2.5 }), (e) => e.kind === 'bad-request');
});

test('a process that cannot be started is reported, and an early exit is heard', async () => {
  const bad = rig({ error: true });
  await assert.rejects(bad.runner.start('b', { iterations: 1 }), (e) => e.kind === 'spawn' && /ENOENT/.test(e.message));

  const { spawned, runner } = rig();
  const heard = [];
  await runner.start('b', { iterations: 1, live: true }, (x) => heard.push(x));
  spawned[0].child.emit('exit', 1, null);
  assert.deepEqual(heard, [{ code: 1, signal: null }]);
});

test('spawnPlan: the same arguments and env without starting anything', () => {
  const p = spawnPlan({ bash: BASH, checkout: 'C:\\tools\\foreman', repoRoot: 'C:/p', batch: '.scratch/gui', plan: checkRequest({ iterations: 2, live: true, caps: { minutes: '15' } }), env: ENV });
  assert.deepEqual(p.args, ['C:/tools/foreman/bin/foreman', 'run', '.scratch/gui', '2', '--live']);
  assert.equal(p.env.FOREMAN_MAX_MINUTES, '15');
  assert.equal(p.cwd, 'C:/p');
});

// ---- the run gets the person's whole environment (the whitelist is for the read-only calls) ----

test('a run is spawned with the whole environment: RALPH_*, keys, proxy, ssh agent; the app\'s own forced values and caps still win', () => {
  const env = { ...ENV, RALPH_MAX_COST_USD: '20', ANTHROPIC_API_KEY: 'k', HTTPS_PROXY: 'http://p', SSH_AUTH_SOCK: '/s', FOREMAN_MAX_MINUTES: '5', UNSET: undefined };
  const p = spawnPlan({ bash: BASH, checkout: 'C:\\tools\\foreman', repoRoot: 'C:/p', batch: 'b', plan: checkRequest({ iterations: 1, caps: { minutes: '15' } }), env });
  for (const k of ['RALPH_MAX_COST_USD', 'ANTHROPIC_API_KEY', 'HTTPS_PROXY', 'SSH_AUTH_SOCK', 'SECRET_TOKEN']) assert.equal(p.env[k], env[k], k);
  assert.equal('UNSET' in p.env, false);
  assert.equal(p.env.FOREMAN_SHOW, 'never', 'forced over the user\'s own');
  assert.equal(p.env.FOREMAN_COLOR, 'never');
  assert.equal(p.env.GIT_OPTIONAL_LOCKS, '0');
  assert.equal(p.env.FOREMAN_MAX_MINUTES, '15', 'the run\'s cap beats the environment');
});

test('the process the runner spawns is given that environment', async () => {
  const { spawned, runner } = rig();
  await runner.start('b', { iterations: 1 });
  assert.equal(spawned[0].opts.env.SECRET_TOKEN, 'hunter2');
});

// ---- when the run ends ----

const { exitNotifier } = require('../runner.cjs');

test('exitNotifier: sends the batch\'s own output from the runner that started it', () => {
  const sent = [];
  const runner = { readOut: (b) => `out of ${b}` };
  exitNotifier({ runner, batch: 'b', current: () => true, send: (m) => sent.push(m) })({ code: 0, signal: null });
  assert.deepEqual(sent, [{ batch: 'b', code: 0, signal: null, out: 'out of b' }]);
});

test('exitNotifier: says nothing, and does not throw, when the app has moved to another repository', () => {
  const sent = [];
  let ctx = { runner: {} };
  const runner = { readOut: () => { throw new Error('must not read another repository\'s output'); } };
  const n = exitNotifier({ runner, batch: 'b', current: () => !!ctx && ctx.runner === runner, send: (m) => sent.push(m) });
  ctx = null;                                       // "Choose folder"
  assert.doesNotThrow(() => n({ code: 0, signal: null }));
  ctx = { runner: { readOut: () => 'other repo' } };   // another repository set up meanwhile
  assert.doesNotThrow(() => n({ code: 0, signal: null }));
  assert.deepEqual(sent, []);
});

test('exitNotifier: a window that is gone by the send does not throw out of the exit listener', () => {
  const n = exitNotifier({ runner: { readOut: () => 'x' }, batch: 'b', current: () => true, send: () => { throw new TypeError('Object has been destroyed'); } });
  assert.doesNotThrow(() => n({ code: 1, signal: null }));
});

test('main.cjs hands start() an exitNotifier made from the runner it captured, and the callback never names the global ctx', () => {
  const m = fs.readFileSync(path.join(__dirname, '..', 'main.cjs'), 'utf8');
  assert.match(m, /const runner = ctx\.runner;\s*\n\s*const started = await runner\.start\(batch, request, exitNotifier\(\{/);
  assert.doesNotMatch(m, /ctx\.runner\.readOut/);
});

// ---- the control directory is where the CLI's resolver puts it (D4) ----

const GIT = (cwd, args) => { const r = spawnSync('git', args, { cwd, encoding: 'utf8', windowsHide: true }); return { status: r.status, stdout: r.stdout }; };
const sh = (cwd, ...args) => {
  const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
};
const fakeSpawn = (pid, spawned = []) => (file, args, opts) => {
  const child = new EventEmitter();
  child.pid = pid; child.unref = () => {};
  spawned.push({ file, args, opts, child });
  setImmediate(() => child.emit('spawn'));
  return child;
};
const forward = (p) => p.replace(/\\/g, '/');

function realRepo({ ignoreLine }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'runner-git-'));
  sh(root, 'init', '-q');
  fs.mkdirSync(path.join(root, '.scratch', 'b'), { recursive: true });
  if (ignoreLine) fs.writeFileSync(path.join(root, '.gitignore'), '**/.foreman-run/\n');
  const spawned = [];
  const runner = createRunner({ bash: BASH, checkout: 'C:\\tools\\foreman', repoRoot: forward(root), env: ENV, spawn: fakeSpawn(7, spawned), git: GIT });
  return { root, spawned, runner };
}

test('without the ignore line, a run starts, and its words go to <git-dir>/foreman-run/<key>/out, not into the batch', async () => {
  const { root, spawned, runner } = realRepo({ ignoreLine: false });
  const batch = '.scratch/b';
  const r = await runner.start(batch, { iterations: 1, live: true });
  assert.equal(r.pid, 7, 'not refused');
  assert.equal(spawned.length, 1);
  const out = path.join(root, '.git', 'foreman-run', '%2Escratch%2Fb', 'out');
  assert.ok(fs.existsSync(out), 'the file exists for the run to write to, under the git directory');
  assert.equal(fs.existsSync(path.join(root, batch, '.foreman-run')), false, 'nothing is put in the batch');
  fs.writeFileSync(out, 'preflight: the working tree is dirty.\n');
  assert.equal(runner.readOut(batch), 'preflight: the working tree is dirty.');
  await runner.start(batch, { iterations: 1, live: true });
  assert.equal(fs.readFileSync(out, 'utf8'), '', 'the previous run\'s text is replaced here too');
});

test('with the ignore line, the words still go to <batch>/.foreman-run/out', async () => {
  const { root, runner } = realRepo({ ignoreLine: true });
  await runner.start('.scratch/b', { iterations: 1, live: true });
  assert.ok(fs.existsSync(path.join(root, '.scratch', 'b', '.foreman-run', 'out')));
  assert.equal(fs.existsSync(path.join(root, '.git', 'foreman-run')), false);
  assert.equal(runner.readOut('.scratch/b'), '');
});

test('in a worktree the control directory is under that worktree\'s own git directory (absolute)', async () => {
  const main = fs.mkdtempSync(path.join(os.tmpdir(), 'runner-wt-main-'));
  sh(main, 'init', '-q');
  fs.mkdirSync(path.join(main, 'b'));
  fs.writeFileSync(path.join(main, 'b', 'x'), 'x');
  sh(main, 'add', '.');
  sh(main, 'commit', '-q', '-m', 'one');
  const wt = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'runner-wt-')), 'w');
  sh(main, 'worktree', 'add', '-q', '-b', 'wtb', wt);
  const runner = createRunner({ bash: BASH, checkout: 'C:\\tools\\foreman', repoRoot: forward(wt), env: ENV, spawn: fakeSpawn(8), git: GIT });
  await runner.start('b', { iterations: 1 });
  const gitDir = GIT(wt, ['rev-parse', '--git-dir']).stdout.trim();
  assert.ok(path.isAbsolute(gitDir), 'a worktree has an absolute git dir');
  const out = path.join(gitDir, 'foreman-run', 'b', 'out');
  assert.ok(fs.existsSync(out), out);
  assert.equal(runner.readOut('b'), '');
});

test('the end-of-run read finds out where start put it, even if the repository changed its mind meanwhile', async () => {
  let ignored = false;
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'runner-stick-'));
  sh(root, 'init', '-q');
  fs.mkdirSync(path.join(root, 'b'));
  const git = (cwd, args) => (ignored && args[0] === 'check-ignore' ? { status: 0, stdout: '' } : GIT(cwd, args));
  const runner = createRunner({ bash: BASH, checkout: 'C:\\tools\\foreman', repoRoot: forward(root), env: ENV, spawn: fakeSpawn(9), git });
  await runner.start('b', { iterations: 1 });
  fs.writeFileSync(path.join(root, '.git', 'foreman-run', 'b', 'out'), 'said this');
  ignored = true;                                   // .gitignore gained the line while the run went
  assert.equal(runner.readOut('b'), 'said this');
});

test('a repository with no git directory is reported, and nothing is started', async () => {
  const bad = rig({ git: (cwd, args) => (args[0] === 'check-ignore' ? { status: 1, stdout: '' } : { status: 128, stdout: '' }) });
  await assert.rejects(bad.runner.start('b', { iterations: 1 }), (e) => e.kind === 'spawn' && /no git directory/.test(e.message));
  assert.equal(bad.spawned.length, 0);
  assert.equal(bad.runner.readOut('b'), null);
});

test('bashGit runs git through Git Bash from the given directory, the way the app runs everything else', () => {
  const calls = [];
  const git = bashGit({ bash: BASH, env: ENV, spawnSync: (file, args, opts) => { calls.push({ file, args, opts }); return { status: 0, stdout: '.git\n' }; } });
  assert.deepEqual(git('C:/p', ['rev-parse', '--git-dir']), { status: 0, stdout: '.git\n' });
  assert.equal(calls[0].file, BASH);
  assert.deepEqual(calls[0].args, ['-c', 'git "$@"', '_', 'rev-parse', '--git-dir']);
  assert.equal(calls[0].opts.cwd, 'C:/p');
  assert.equal(calls[0].opts.windowsHide, true);
});

test('main.cjs no longer refuses to start without the ignore line', () => {
  const m = fs.readFileSync(path.join(__dirname, '..', 'main.cjs'), 'utf8');
  assert.doesNotMatch(m, /not-ignored/);
  assert.doesNotMatch(m, /controlIgnored/);
});
