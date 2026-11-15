'use strict';
// runner.cjs: the process the app starts for a run — its arguments, its environment, where its words
// go, and that the app does not wait on it. A fake spawn stands in for child_process.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { createRunner, spawnPlan, checkRequest } = require('../runner.cjs');

const BASH = 'C:\\Program Files\\Git\\bin\\bash.exe';
const ENV = { PATH: 'C:\\Windows', SECRET_TOKEN: 'hunter2', FOREMAN_SHOW: 'always', FOREMAN_COLOR: 'always', GIT_OPTIONAL_LOCKS: '1', SystemRoot: 'C:\\Windows' };

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
  const runner = createRunner({ bash: BASH, checkout: 'C:\\tools\\foreman', repoRoot: root.replace(/\\/g, '/'), env: ENV, spawn });
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
  assert.equal(env.SECRET_TOKEN, undefined, 'nothing else is passed on');
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
