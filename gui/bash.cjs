'use strict';
// Finds Git Bash's bash.exe, in the order the spec gives ("Windows paths"):
//   1. FOREMAN_BASH, if set
//   2. git.exe on PATH, resolved to <git root>\bin\bash.exe
//   3. C:\Program Files\Git\bin\bash.exe
//
// It never answers with a WSL launcher — C:\Windows\System32\bash.exe or ...\WindowsApps\bash.exe —
// which is what a bare `bash` resolves to on a machine with WSL, and which would run foreman in
// a Linux that has none of the user's repository paths. Even FOREMAN_BASH is refused when it names one.
//
// Windows paths all through, whatever the platform this runs on, so the lookup can be tested
// anywhere: the environment and the "does it exist" question are arguments.
const fs = require('fs');
const win = require('path').win32;

const PROGRAM_FILES_BASH = 'C:\\Program Files\\Git\\bin\\bash.exe';

// The two places Windows puts a launcher for the Linux subsystem's bash.
function isWslLauncher(p) {
  const n = String(p).replace(/\//g, '\\').toLowerCase();
  return /\\windows\\(system32|sysnative)\\bash\.exe$/.test(n) || /\\windowsapps\\bash\.exe$/.test(n);
}

// <git root> from the folder git.exe is in: Git for Windows has one in cmd\, bin\, mingw64\bin\
// and usr\bin\, all under the same root.
function gitRoot(dir) {
  const parts = dir.split('\\');
  const last = (parts[parts.length - 1] || '').toLowerCase();
  const prev = (parts[parts.length - 2] || '').toLowerCase();
  if ((last === 'bin' && (prev === 'mingw64' || prev === 'mingw32' || prev === 'usr'))) return win.dirname(win.dirname(dir));
  if (last === 'cmd' || last === 'bin') return win.dirname(dir);
  return dir;
}

function pathEntries(env) {
  const raw = env.PATH !== undefined ? env.PATH : env.Path !== undefined ? env.Path : '';
  return String(raw).split(';').map((s) => s.trim().replace(/^"|"$/g, '')).filter(Boolean);
}

// -> { bash: 'C:\\...\\bash.exe' | null, tried: [what was looked at, in order, with why it was not used] }
function findGitBash({ env = process.env, exists = fs.existsSync } = {}) {
  const tried = [];

  if (env.FOREMAN_BASH) {
    if (isWslLauncher(env.FOREMAN_BASH)) {
      tried.push(`${env.FOREMAN_BASH} (FOREMAN_BASH: that is the WSL launcher, not Git Bash)`);
    } else if (exists(env.FOREMAN_BASH)) {
      return { bash: env.FOREMAN_BASH, tried };
    } else {
      tried.push(`${env.FOREMAN_BASH} (FOREMAN_BASH)`);
    }
  }

  let gitFound = false;
  for (const dir of pathEntries(env)) {
    const git = win.join(dir, 'git.exe');
    if (!exists(git)) continue;
    gitFound = true;
    const bash = win.join(gitRoot(dir), 'bin', 'bash.exe');
    if (!isWslLauncher(bash) && exists(bash)) return { bash, tried };
    tried.push(`${bash} (next to git.exe on PATH)`);
    break;
  }
  if (!gitFound) tried.push('git.exe on PATH (not found)');

  if (exists(PROGRAM_FILES_BASH)) return { bash: PROGRAM_FILES_BASH, tried };
  tried.push(PROGRAM_FILES_BASH);
  return { bash: null, tried };
}

module.exports = { findGitBash, isWslLauncher, PROGRAM_FILES_BASH };
