'use strict';
// How the app asks foreman a question: runs `bash <checkout>/bin/foreman <command> ... --json` from
// the repository root and turns what came back into an object, or into an error that says what
// went wrong in one of four ways:
//   spawn       Git Bash could not be started
//   exit        foreman ran and failed — its own stderr is the message
//   parse       what it printed was not one JSON object
//   version     it was JSON, but not an answer this app understands (a newer `foreman_json`, or to
//               a different command)
// plus `bad-batch` (and `bad-run`), for a batch path or run id the page should never have produced, and `not-a-repo`, for a
// directory that is not inside a git repository.
//
// The paths given to foreman are repo-relative with forward slashes and the working directory is
// the repo root, so a `C:\` path never reaches the CLI (spec: "Windows paths").
//
// The read side (status, dry-run, report, doctor), `doctorFix`, and the steering of a run in flight:
// `keys` and `stop`, which print words, not JSON, and are free (they only write the run's control files).
// Starting a run is runner.cjs.
const { execFile } = require('child_process');
const Ctl = require('../lib/foreman-ctl.cjs');

const SUPPORTED_JSON = 1;

// How long any one CLI call may take before it is killed and reported. Generous: the doctor probes
// the machine and takes seconds. `stop --now` waits for the run to end (up to a minute itself).
const CALL_TIMEOUT_MS = 60 * 1000;
const STOP_NOW_TIMEOUT_MS = 150 * 1000;

class ForemanError extends Error {
  constructor(kind, message, extra = {}) {
    super(message);
    this.name = 'ForemanError';
    this.kind = kind;
    Object.assign(this, extra);
  }
}

// What the CLI is given from the app's own environment. Not all of it: Git Bash and node need the
// Windows system variables to start at all, and a FOREMAN_ setting must still beat foreman.conf as
// it does in a terminal. A token, a password or anything else the app has no business with is not
// passed on (spec: "Secrets"); the CLI reads its own credentials file itself.
const PASS = new Set([
  'path', 'systemroot', 'systemdrive', 'windir', 'comspec', 'pathext', 'temp', 'tmp', 'tmpdir',
  'userprofile', 'home', 'homedrive', 'homepath', 'appdata', 'localappdata', 'programdata',
  'programfiles', 'programfiles(x86)', 'programw6432', 'commonprogramfiles', 'allusersprofile',
  'username', 'userdomain', 'computername', 'os', 'processor_architecture', 'number_of_processors',
  'lang', 'lc_all', 'term', 'msystem', 'ssl_cert_file', 'git_exec_path',
]);

// What the app forces, so the CLI prints what a program can read: no drawing, no colour, no
// intro, and no optional git lock for a command that only reads.
const FORCED = { GIT_OPTIONAL_LOCKS: '0', FOREMAN_SHOW: 'never', FOREMAN_COLOR: 'never', FOREMAN_INTRO: 'never' };

function cliEnv(base = process.env) {
  const env = {};
  for (const [k, v] of Object.entries(base)) {
    if (v === undefined) continue;
    if (PASS.has(k.toLowerCase()) || /^FOREMAN_/i.test(k)) env[k] = v;
  }
  return Object.assign(env, FORCED);
}

// A batch path the CLI may be given: repo-relative, forward slashes, inside the repo, and not
// something that would be read as a flag.
function checkBatchPath(p) {
  const bad = (why) => new ForemanError('bad-batch', `not a batch path (${why}): ${JSON.stringify(p)}`);
  if (typeof p !== 'string' || p === '') throw bad('empty');
  if (p.includes('\0')) throw bad('has a NUL');
  if (p.includes('\\')) throw bad('has a backslash');
  if (p.startsWith('-')) throw bad('looks like a flag');
  if (p.startsWith('/') || /^[A-Za-z]:/.test(p)) throw bad('is absolute');
  if (p.split('/').includes('..')) throw bad('reaches out of the repository');
  return p;
}

// A run id as the loop writes them (20261021T091200Z-4411, longer if the batch's name is), or the
// `(unknown)` a record with no id is filed under. Letters, digits and . _ - : ( ) + only, never a
// leading dash: it is handed to the CLI as the value of --run, and must not be read as anything else.
function checkRunId(id) {
  if (typeof id !== 'string' || !/^[A-Za-z0-9(][A-Za-z0-9._:()+-]*$/.test(id)) {
    throw new ForemanError('bad-run', `not a run id: ${JSON.stringify(id)}`);
  }
  return id;
}

function parseOutput(command, { code, stdout, stderr }) {
  if (code !== 0) {
    const said = String(stderr || '').trim();
    throw new ForemanError('exit', said || `foreman ${command} exited ${code}`, { code, stderr: String(stderr || '') });
  }
  let doc;
  try { doc = JSON.parse(stdout); } catch (e) {
    throw new ForemanError('parse', `foreman ${command} --json did not print JSON: ${e.message}`, { stdout });
  }
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) {
    throw new ForemanError('parse', `foreman ${command} --json did not print one JSON object`, { stdout });
  }
  if (doc.foreman_json !== SUPPORTED_JSON) {
    throw new ForemanError('version', `foreman_json is ${JSON.stringify(doc.foreman_json)}; this app understands ${SUPPORTED_JSON}. Update the app with git pull and bash install.sh.`);
  }
  if (doc.command !== command) {
    throw new ForemanError('version', `asked for ${command}, got an answer to ${JSON.stringify(doc.command)}`);
  }
  return doc;
}

// The default runner: resolves with the exit code and both streams, rejects when the process could
// not be started at all, or ran past its timeout and was killed (ForemanError 'timeout').
function defaultRun(file, args, opts) {
  return new Promise((resolve, reject) => {
    const limit = { timeout: CALL_TIMEOUT_MS, killSignal: 'SIGKILL', ...opts };
    execFile(file, args, { ...limit, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err && err.killed && limit.timeout > 0) {
        return reject(new ForemanError('timeout', `foreman did not answer within ${Math.round(limit.timeout / 1000)} s and was stopped`, { cause: err }));
      }
      if (err && typeof err.code !== 'number') return reject(err);
      resolve({ code: err ? err.code : 0, stdout, stderr });
    });
  });
}

// What a command that prints words said, as lines a person can read: no escape codes (`foreman keys`
// echoes the terminal's own `⌨ …` line, with a carriage return and a clear-line before it), no blank ends.
function plainText(s) {
  return String(s || '')
    .replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '')
    .replace(/[\r\x00-\x08\x0b-\x1f]/g, '\n')
    .split('\n').map((l) => l.trim()).filter(Boolean).join('\n');
}

// What a failed `run` is told as: a ForemanError (a timeout) as it is, anything else as a failure to start.
function startFailure(bash, e) {
  return e instanceof ForemanError ? e : new ForemanError('spawn', `could not start ${bash}: ${e.message}`, { cause: e });
}

function createForeman({ bash, checkout, repoRoot, run = defaultRun, env = process.env }) {
  const script = `${checkout.replace(/\\/g, '/')}/bin/foreman`;

  async function call(command, args) {
    let out;
    try {
      out = await run(bash, [script, command, ...args], {
        cwd: repoRoot, env: cliEnv(env), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], timeout: CALL_TIMEOUT_MS, killSignal: 'SIGKILL',
      });
    } catch (e) {
      throw startFailure(bash, e);
    }
    return parseOutput(command, out);
  }

  // A command with no JSON to give back: resolves with what it printed, rejects with the CLI's own
  // words when it exited non-zero.
  async function words(command, args, timeout = CALL_TIMEOUT_MS) {
    let out;
    try {
      out = await run(bash, [script, command, ...args], {
        cwd: repoRoot, env: cliEnv(env), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], timeout, killSignal: 'SIGKILL',
      });
    } catch (e) {
      throw startFailure(bash, e);
    }
    if (out.code !== 0) {
      const said = plainText(out.stderr) || plainText(out.stdout);
      throw new ForemanError('exit', said || `foreman ${command} exited ${out.code}`, { code: out.code });
    }
    return { stdout: plainText(out.stdout), stderr: plainText(out.stderr) };
  }

  return {
    status: (batch) => call('status', [checkBatchPath(batch), '--json']),
    statusAll: () => call('status', ['--json', '--all']),
    // What a run would do, its settings and its exact prompt. Free: nothing is sent and no sandbox
    // starts (the CLI says so; this only reads).
    dryRun: (batch) => call('dry-run', [checkBatchPath(batch), '--json']),
    // What the batch has cost: the totals and a row for each run (or ticket, with byTicket). With
    // `run`, also that run's iterations and the outcome word of each. Free: it reads the run record.
    report: (batch, opts) => {
      const { byTicket = false, run = null } = opts || {};
      const args = [checkBatchPath(batch), '--json'];
      if (byTicket) args.push('--by-ticket');
      if (run !== null && run !== undefined) args.push('--run', checkRunId(run));
      return call('report', args);
    },
    // The inspection sheet of the machine and the repository (no batch): `foreman doctor --json`. Free,
    // and it writes nothing. `doctorFix` is `doctor --fix --json`: it appends the lines the sheet's plan
    // lists to .gitignore and .gitattributes, and answers with what it appended.
    // Press keys in a run's terminal, from outside it: + one more iteration, - one fewer, L the live view.
    // Free. `foreman keys` writes the control files and nothing else; what it echoes is the terminal's.
    keys: (batch, keys) => {
      if (typeof keys !== 'string' || !/^[-+Ll=_]+$/.test(keys)) {
        throw new ForemanError('bad-keys', `not keys foreman understands: ${JSON.stringify(keys)}`);
      }
      return words('keys', [checkBatchPath(batch), keys]);
    },
    // Finish the iteration in flight, then pause; with `now`, end it at once as Ctrl-C does (the CLI
    // keeps the ticket's uncommitted work, and the next run reviews it). `stop --now` waits for the run
    // to end, up to a minute. Free.
    stop: (batch, { now = false } = {}) => words('stop', [...(now ? ['--now'] : []), checkBatchPath(batch)], now ? STOP_NOW_TIMEOUT_MS : CALL_TIMEOUT_MS),
    // Whether the repository ignores the batch's control directory (`**/.foreman-run/`): without it a
    // run cannot be steered from here, and the app's own `out` would show up as a change. Asked of git,
    // as the loop asks it.
    controlIgnored: async (batch) => {
      let out;
      try {
        out = await run(bash, ['-c', `git check-ignore -q -- "$1/${Ctl.DIRNAME}/${Ctl.FILES.pid}"`, '_', checkBatchPath(batch)], {
          cwd: repoRoot, env: cliEnv(env), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], timeout: CALL_TIMEOUT_MS, killSignal: 'SIGKILL',
        });
      } catch (e) {
        throw startFailure(bash, e);
      }
      if (out.code === 0) return true;
      if (out.code === 1) return false;
      throw new ForemanError('exit', plainText(out.stderr) || `git check-ignore exited ${out.code}`, { code: out.code });
    },
    doctor: () => call('doctor', ['--json']),
    doctorFix: () => call('doctor', ['--fix', '--json']),
  };
}

// The repository the app was opened on: the top of the working tree that holds `dir`. Asked of git
// itself, through Git Bash, so a worktree or a subdirectory gives the same answer a terminal would.
// Mixed form (C:/x), the form the CLI and `status --json` use for the root.
async function findRepoRoot({ bash, dir, run = defaultRun, env = process.env }) {
  let out;
  try {
    out = await run(bash, ['-c', 'git rev-parse --show-toplevel'], {
      cwd: dir, env: cliEnv(env), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], timeout: CALL_TIMEOUT_MS, killSignal: 'SIGKILL',
    });
  } catch (e) {
    throw startFailure(bash, e);
  }
  const root = String(out.stdout || '').trim().replace(/\\/g, '/');
  if (out.code !== 0 || root === '') {
    const said = String(out.stderr || '').trim();
    throw new ForemanError('not-a-repo', said || `${dir} is not inside a git repository`, { dir });
  }
  return root;
}

module.exports = { CALL_TIMEOUT_MS, defaultRun, plainText, findRepoRoot, createForeman, parseOutput, checkBatchPath, checkRunId, cliEnv, ForemanError, SUPPORTED_JSON };
