'use strict';
// The six states that take the pane, chosen from what main read (designs/09-empty-and-error.html, take a).
//
// Loaded two ways, like model.js: as a plain <script> (it puts `ForemanStates` on the window) and with
// require() in the tests. No DOM and no Node in here.
//
// The app writes no message of its own. A state has a heading and a sentence — fixed words that say what
// kind of state it is — and then `message`, which is the CLI's: git's stderr, foreman's stderr, the doctor's
// row, the loop's own `# reason:` line, passed through untouched. What each state's button does is named
// (`action.do`) and done by app.js.
//
// The conditions that need a second CLI read (a runner missing for the batch's exec mode, a login that
// expired) arrive as `data.conditions`, worked out in main (conditions.cjs). Nothing here asks the CLI
// anything.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ForemanStates = factory();
}(typeof self !== 'undefined' ? self : this, function () {

  // What No batch shows and copies: the command as the CLI's own usage spells it, with the batch's
  // name left for the person to choose.
  const INIT_COMMAND = 'foreman init .scratch/<name>';

  const basename = (p) => String(p).split('/').pop();

  // The first `.md` file a stderr line names that lies inside the repository, as a repo-relative path
  // with forward slashes; a bare `order.md` is the batch's own. null when it names none.
  function fileNamed(said, batch) {
    for (const raw of String(said || '').replace(/\\/g, '/').split(/\s+/)) {
      const word = raw.replace(/^[('"`]+|[)'"`.,:;]+$/g, '');
      if (!/\.md$/i.test(word)) continue;
      if (word.startsWith('/') || /^[A-Za-z]:/.test(word) || word.startsWith('-') || word.split('/').includes('..')) continue;
      return word.includes('/') ? word : `${batch}/${word}`;
    }
    return null;
  }

  function notRepo(error) {
    return {
      id: 'not-a-repo', whole: true, cap: 'not a git repo',
      art: { kind: 'dome', p: 0, stakes: '.....' },
      heading: "This folder isn't a git repository",
      sentence: "Foreman works on a repo's batches. Pick the folder that holds your repo.",
      message: error.message || null,
      detail: error.dir ? { kind: 'path', text: String(error.dir) } : null,
      action: { do: 'choose-folder', label: 'Choose a folder…' },
    };
  }

  function bashMissing(error) {
    return {
      id: 'git-bash-missing', whole: true, cap: 'Git Bash missing',
      art: { kind: 'inspector', sign: 'stop' },
      heading: "Git Bash wasn't found",
      sentence: 'The app runs foreman through Git Bash, as the CLI does. Install Git for Windows, then look again.',
      message: error.message || null,
      detail: Array.isArray(error.tried) && error.tried.length ? { kind: 'tried', lines: error.tried.slice() } : null,
      action: { do: 'look-again', label: 'Look again' },
    };
  }

  function noBatch() {
    return {
      id: 'no-batch', whole: true, cap: 'no batch',
      art: { kind: 'dome', p: 0.05, stakes: '.' },
      heading: 'No batch in this repo yet',
      sentence: 'A batch is a folder with a foreman.conf. Make one in a terminal:',
      message: null,
      detail: { kind: 'command', text: INIT_COMMAND },
      action: { do: 'copy-command', label: 'Copy command' },
    };
  }

  function unreadable(data) {
    const file = fileNamed(data.statusError, data.selected) || data.selected;
    const named = file !== data.selected;
    return {
      id: 'batch-unreadable', whole: true, cap: 'batch unreadable',
      art: { kind: 'dome', p: 0.5, stakes: 'ddx..' },
      heading: "foreman can't read this batch",
      sentence: 'This is what foreman said:',
      message: data.statusError,
      detail: null,
      action: { do: 'open-file', file, label: named ? `Open ${basename(file)} in editor` : 'Open the batch folder' },
    };
  }

  function runnerMissing(c) {
    return {
      id: 'runner-missing', whole: false, cap: 'claude / sbx missing',
      art: { kind: 'inspector', sign: 'stop' },
      heading: `${c.tool} isn't installed`,
      sentence: `This batch runs with FOREMAN_EXEC=${c.mode}. Runs are off until it's there; status, dry run and report still work.`,
      message: c.fix ? `${c.message}\n${c.fix}` : c.message,
      detail: null,
      action: { do: 'doctor', label: 'Doctor', tag: { cls: 'free', text: 'free' } },
    };
  }

  function loginExpired(c) {
    return {
      id: 'login-expired', whole: false, cap: 'login expired',
      art: { kind: 'inspector', sign: 'stop' },
      heading: "The agent's login has expired",
      sentence: `Run ${c.runId} stopped with exit ${c.exit} and auth_failed. Sign in again, then resume: resuming costs money.`,
      message: c.message || null,
      detail: null,
      action: { do: 'resume', label: 'Resume…', tag: { cls: 'paid', text: 'costs money' } },
    };
  }

  // The runner condition of the batch on screen, or null.
  const runnersOf = (data) => {
    const c = data && data.conditions && data.conditions.runners;
    return c && c.batch === data.selected ? c : null;
  };
  const loginOf = (data) => {
    const c = data && data.conditions && data.conditions.login;
    const run = data && data.status && data.status.run;
    return c && c.batch === data.selected && !(run && run.in_flight) ? c : null;
  };

  // The state that takes the pane, or null: the overview shows. `data` is the overview answer, or the
  // `{ ok: false, error }` that stood in for it.
  function choose(data) {
    if (!data) return null;
    if (!data.ok) {
      const e = data.error || {};
      if (e.kind === 'not-a-repo') return notRepo(e);
      if (e.kind === 'git-bash-missing') return bashMissing(e);
      return null;
    }
    if (!data.all || data.all.batches.length === 0) return noBatch();
    if (!data.status) return data.statusError ? unreadable(data) : null;
    const runners = runnersOf(data);
    if (runners) return runnerMissing(runners);      // runs are off, so a login that expired cannot be mended by resuming
    const login = loginOf(data);
    if (login) return loginExpired(login);
    return null;
  }

  // Why Start run is off for this batch, in the CLI's words, or null. Resume… is the same start, so it is off too.
  function startBlock(data) {
    const c = runnersOf(data);
    return c ? c.message : null;
  }

  return { choose, startBlock, fileNamed, INIT_COMMAND };
}));
