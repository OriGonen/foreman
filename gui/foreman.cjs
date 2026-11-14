'use strict';
// How the app asks foreman a question: runs `bash <checkout>/bin/foreman <command> ... --json` from
// the repository root and turns what came back into an object, or into an error that says what
// went wrong in one of four ways:
//   spawn       Git Bash could not be started
//   exit        foreman ran and failed — its own stderr is the message
//   parse       what it printed was not one JSON object
//   version     it was JSON, but not an answer this app understands (a newer `foreman_json`, or to
//               a different command)
// plus `bad-batch`, for a batch path the page should never have produced, and `not-a-repo`, for a
// directory that is not inside a git repository.
//
// The paths given to foreman are repo-relative with forward slashes and the working directory is
// the repo root, so a `C:\` path never reaches the CLI (spec: "Windows paths").
//
// Starting and stopping runs is a later ticket; this is the read side.
const { execFile } = require('child_process');

const SUPPORTED_JSON = 1;

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

// The default runner: resolves with the exit code and both streams, rejects only when the process
// could not be started at all.
function defaultRun(file, args, opts) {
  return new Promise((resolve, reject) => {
    execFile(file, args, { ...opts, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err && typeof err.code !== 'number') return reject(err);
      resolve({ code: err ? err.code : 0, stdout, stderr });
    });
  });
}

function createForeman({ bash, checkout, repoRoot, run = defaultRun, env = process.env }) {
  const script = `${checkout.replace(/\\/g, '/')}/bin/foreman`;

  async function call(command, args) {
    let out;
    try {
      out = await run(bash, [script, command, ...args], {
        cwd: repoRoot, env: cliEnv(env), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (e) {
      throw new ForemanError('spawn', `could not start ${bash}: ${e.message}`, { cause: e });
    }
    return parseOutput(command, out);
  }

  return {
    status: (batch) => call('status', [checkBatchPath(batch), '--json']),
    statusAll: () => call('status', ['--json', '--all']),
  };
}

// The repository the app was opened on: the top of the working tree that holds `dir`. Asked of git
// itself, through Git Bash, so a worktree or a subdirectory gives the same answer a terminal would.
// Mixed form (C:/x), the form the CLI and `status --json` use for the root.
async function findRepoRoot({ bash, dir, run = defaultRun, env = process.env }) {
  let out;
  try {
    out = await run(bash, ['-c', 'git rev-parse --show-toplevel'], {
      cwd: dir, env: cliEnv(env), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (e) {
    throw new ForemanError('spawn', `could not start ${bash}: ${e.message}`, { cause: e });
  }
  const root = String(out.stdout || '').trim().replace(/\\/g, '/');
  if (out.code !== 0 || root === '') {
    const said = String(out.stderr || '').trim();
    throw new ForemanError('not-a-repo', said || `${dir} is not inside a git repository`, { dir });
  }
  return root;
}

module.exports = { findRepoRoot, createForeman, parseOutput, checkBatchPath, cliEnv, ForemanError, SUPPORTED_JSON };
