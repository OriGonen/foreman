'use strict';
// Starts a run: a plain `foreman run`, spawned detached, that the app does not wait on and that
// outlives the window — closing the app never stops it, as a run in a terminal tab that was detached
// would not stop. The arguments come from runplan.js, the one place the command is spelled, and are
// built here from what the page sent, never taken from it as they are.
//
//   <bash.exe> <checkout>/bin/foreman run <batch> <n|--unlimited> [--live]
//
// with its working directory the repository root, stdin ignored, stdout and stderr in
// `<batch>/.foreman-run/out` (which the CLI leaves alone when the run ends, so a preflight failure can
// still be read), and in its environment what any CLI call from the app gets, FOREMAN_SHOW=never,
// FOREMAN_COLOR=never, GIT_OPTIONAL_LOCKS=0, and the caps the person edited for this run only.
// foreman.conf is never written.
const nodeFs = require('fs');
const { spawn: nodeSpawn } = require('child_process');
const RP = require('./runplan.js');
const { cliEnv, checkBatchPath, plainText, ForemanError } = require('./foreman.cjs');

const RUN_FORCED = { FOREMAN_SHOW: 'never', FOREMAN_COLOR: 'never', GIT_OPTIONAL_LOCKS: '0' };

// The request, checked and turned into a plan, or a ForemanError('bad-request') saying what is wrong.
function checkRequest(request) {
  const r = RP.planFrom(request);
  if (!r.ok) throw new ForemanError('bad-request', r.message);
  return r.plan;
}

// { file, args, env, cwd } for the process, without starting it: what the tests look at.
function spawnPlan({ bash, checkout, repoRoot, batch, plan, env = process.env }) {
  const script = `${String(checkout).replace(/\\/g, '/')}/bin/foreman`;
  return {
    file: bash,
    args: [script, ...RP.runArgs(checkBatchPath(batch), plan)],
    cwd: repoRoot,
    env: Object.assign(cliEnv(env), RUN_FORCED, RP.capEnv(plan)),
  };
}

function createRunner({ bash, checkout, repoRoot, env = process.env, spawn = nodeSpawn, fs = nodeFs }) {
  const outPath = (batch) => `${repoRoot}/${batch}/.foreman-run/out`;

  return {
    // Start the run. Resolves with { pid, command } once the process exists (not when it ends), and
    // calls `onExit({ code, signal })` when it does, if the app is still there to hear it.
    start(batch, request, onExit) {
      const plan = checkRequest(request);
      const p = spawnPlan({ bash, checkout, repoRoot, batch, plan, env });
      const command = RP.command(batch, plan).full;
      return new Promise((resolve, reject) => {
        let fd;
        try {
          fs.mkdirSync(`${repoRoot}/${batch}/.foreman-run`, { recursive: true });
          fd = fs.openSync(outPath(batch), 'w');          // the previous run's words are replaced, not appended to
        } catch (e) {
          reject(new ForemanError('spawn', `could not open ${outPath(batch)}: ${e.message}`, { cause: e }));
          return;
        }
        const done = () => { try { fs.closeSync(fd); } catch { /* already closed */ } };
        let child;
        try {
          child = spawn(p.file, p.args, {
            cwd: p.cwd, env: p.env, detached: true, windowsHide: true, stdio: ['ignore', fd, fd],
          });
        } catch (e) {
          done();
          reject(new ForemanError('spawn', `could not start ${p.file}: ${e.message}`, { cause: e }));
          return;
        }
        child.once('error', (e) => { done(); reject(new ForemanError('spawn', `could not start ${p.file}: ${e.message}`, { cause: e })); });
        child.once('spawn', () => {
          done();                                          // the child holds its own copy of the descriptor
          if (typeof child.unref === 'function') child.unref();
          resolve({ pid: child.pid, command });
        });
        if (typeof onExit === 'function') child.once('exit', (code, signal) => onExit({ code, signal }));
      });
    },

    // What the run said on its own stdout and stderr, as far back as `max` characters: the CLI's own
    // text for a run that never began. null when there is no such file.
    readOut(batch, max = 4000) {
      let text;
      try { text = fs.readFileSync(outPath(checkBatchPath(batch)), 'utf8'); } catch { return null; }
      const tail = text.length > max ? text.slice(text.length - max) : text;
      return plainText(tail);
    },
  };
}

module.exports = { createRunner, spawnPlan, checkRequest, RUN_FORCED };
