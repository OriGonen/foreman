# Bugs 06 - GUI main process, watching and run control

Scope: gui/main.cjs, runner.cjs, watch.cjs, live.cjs, foreman.cjs, bash.cjs, guard.cjs, conditions.cjs, ticket.cjs, plus app.js where main's behaviour surfaces. Repro scripts were run from the session scratchpad, outside the repo, and they `require` the pure gui modules.

## 1. Run-exit callback dereferences a nulled `ctx` (uncaught exception in main)
- File: gui/main.cjs:264-266 (with :137)
- Severity: med. Confidence: confirmed-by-repro.
- What is wrong: the `onExit` closure reads the module-global `ctx` at exit time, not the `ctx` that started the run. If the person uses "Choose folder" (`repo:choose` sets `ctx = null`) while a GUI-started run is alive, the run's later exit throws a TypeError inside a ChildProcess `exit` listener. That is an uncaught main-process exception, and Electron shows the "A JavaScript error occurred in the main process" dialog. If `ctx` was already rebuilt for another repo, `readOut(batch)` reads the wrong repo's `.foreman-run/out` and sends it as that batch's `run:exit`.
- Evidence (callback shape copied from main.cjs, runner with an injected spawn):
  ```
  ctx = null;  child.emit('exit', 0, null);
  -> THROWS Cannot read properties of null (reading 'runner')
  ```
  Source: `win.webContents.send('run:exit', { batch, code, signal, out: ctx.runner.readOut(batch) })`.
- Fix: capture `const runner = ctx.runner` before `start()` and use it in the callback. Wrap the callback body in try/catch. Drop the event if `ctx.runner !== runner`.

## 2. A stale or reused pid keeps a run "in flight" forever. The GUI refuses Start and cannot Stop, while the CLI would recover
- Files: lib/foreman-json.cjs:307-310 (the `in_flight` decision), gui/main.cjs:262-263, lib/foreman-loop.sh:1143, lib/foreman-control.sh:95
- Severity: high. Confidence: high (code reading; the PID-reuse case is not reproduced).
- What is wrong: three separate disagreements.
  - `status --json` takes `in_flight` from `process.kill(<WINDOWS pid>, 0)`, the second field of `pid`. The CLI's own start guard (loop.sh:1143) and `stop`/`keys` (control.sh:95) test the first field, the MSYS pid, with bash `kill -0`. After a hard kill or a crash, the Windows pid is soon reused by some unrelated process. Then `status` says in-flight and `run:start` throws "A run is already in flight". `foreman stop` and `foreman keys` fail with "no run in flight", and the CLI's own `run` would happily clear the stale dir.
  - The GUI is therefore stuck on a live screen with no working control, and only deleting `.foreman-run/pid` by hand recovers.
  - There is also no liveness event. watch.cjs has no timer, and a SIGKILLed loop or a closed terminal produces no fs event. A terminal-started run that dies leaves the screen "in flight" until some unrelated file changes. `run:exit` only exists for runs this app process spawned.
- Evidence: `const [msys, win = msys] = pids; if (!(io.alive || pidAlive)(win)) return none;` against `kill -0 "$RUN_CTL_PID"` (the first field) at loop.sh:1143.
- Fix: make `in_flight` require both pids alive, or check the Windows pid's image name or start time. Cheap GUI fix: while a run is shown in flight, re-read status on a slow timer (10-30 s) or on window focus.

## 3. The env whitelist drops `RALPH_*` and every non-system variable, so a GUI-started run differs from a terminal run
- Files: gui/foreman.cjs:36-55 (`cliEnv`), gui/runner.cjs:35
- Severity: med. Confidence: confirmed-by-repro for `RALPH_*`; high for the rest.
- What is wrong: `cliEnv` passes only a system list and `^FOREMAN_`. The CLI still honours legacy `RALPH_*` env knobs (lib/foreman-legacy.sh: `RALPH_MAX_COST_USD`, `RALPH_EXEC`, `RALPH_MODEL`, ...). A user with `RALPH_MAX_COST_USD=20` set gets a cost cap in a terminal run and NO cap in a GUI-started `foreman run`, and the confirm screen cannot show it either.
  - The same whitelist drops `ANTHROPIC_API_KEY`, `HTTP(S)_PROXY`/`NO_PROXY`, `SSH_AUTH_SOCK`, `GH_TOKEN`/`GITHUB_TOKEN`, `NODE_EXTRA_CA_CERTS`, `CLAUDE_CONFIG_DIR`, `DOCKER_HOST` and `MSYS*` settings. This bites most with `FOREMAN_EXEC=host` (claude runs directly) and for `git push` over ssh from a ticket.
  - The detached run is the only consumer that really needs the user's environment. The read-only `--json` calls are fine with the whitelist.
- Evidence:
  ```
  cliEnv({PATH, ANTHROPIC_API_KEY, HTTPS_PROXY, SSH_AUTH_SOCK, RALPH_EXEC, GH_TOKEN, NODE_EXTRA_CA_CERTS, ...})
  -> [ 'PATH', 'GIT_OPTIONAL_LOCKS', 'FOREMAN_SHOW', 'FOREMAN_COLOR', 'FOREMAN_INTRO' ]
  ```
- Fix: for the spawn in runner.cjs, pass the full `process.env` plus `RUN_FORCED`. Keep the whitelist only for the `--json` reads. At minimum add `/^RALPH_/` to the pattern.

## 4. No timeout on any CLI call; one hung bash freezes the UI and the watcher for good
- Files: gui/foreman.cjs:103-110, gui/watch.cjs:88-99 (and 41)
- Severity: med. Confidence: high.
- What is wrong: `execFile` has no `timeout`. A wedged Git Bash (an AV scan, a git lock wait, a stuck `sbx` probe inside `doctor`, a network share) leaves the promise pending forever.
  - `overview:load` never resolves, so the page is stuck on "loading".
  - The watcher is worse. `run()` sets `reading = true` and awaits `read()`, which never returns. Every later fs event only sets `dirtyWhileReading`, so the window stops updating for the rest of the session even after the hung process is gone.
  - `conditions.readRunners` memoises the pending doctor promise in `reading`, so later doctor reads also never start.
- Fix: pass `timeout` (for example 60 s, with `killSignal: 'SIGKILL'`) in `defaultRun`, longer for `stop --now`. Surface it as a `spawn`/`exit` ForemanError. The watcher then recovers through its retry and onError path.

## 5. Config readers disagree with how the shell resolves config
- Files: gui/live.cjs:53-65 (`capsFromConf`), gui/conditions.cjs:25-36 (`execModeOf`), gui/main.cjs:233-235 (`readConf`), gui/live.cjs:92
- Severity: med. Confidence: confirmed-by-repro (the first three bullets), high (ralph.conf).
- What is wrong: the shell `source`s foreman.conf, so the last assignment wins, `${X:-9}` expands, and FOREMAN_ beats RALPH_. The GUI regex-scans the text.
  - `capsFromConf('FOREMAN_MAX_COST_USD=5\nFOREMAN_MAX_COST_USD=50\n')` gives `cost: 5`, but the shell uses 50. The `m` regex takes the first match.
  - `capsFromConf('RALPH_MAX_COST_USD=7')` gives `null`, but the CLI treats it as a 7 USD cap.
  - `capsFromConf('FOREMAN_MAX_COST_USD=${X:-9}')` gives `null`.
  - `execModeOf('FOREMAN_EXEC=host\nRALPH_EXEC=sandbox\n')` gives `sandbox`. The CLI copies RALPH_ only when FOREMAN_ is unset, so it runs `host`. The "runner missing" banner then names the wrong tool.
  - `readConf` and `live.read` read only `<batch>/foreman.conf`. A batch with only the legacy `ralph.conf` is a valid batch for the CLI (foreman-repo.sh:144), but the GUI sees no conf: no caps on the live bar, no "where it is set", and the exec mode defaults to `sandbox`.
  - The result is wrong cap meters and wrong "runner missing" or login states.
- Fix: read the effective values from the CLI (`dry-run --json` already prints the settings) instead of regex-scanning conf. Otherwise take the last match, accept the `RALPH_` prefix with FOREMAN_ precedence, and fall back to `ralph.conf`.

## 6. Inline `style` attributes via `setAttribute` are blocked by the page's own CSP
- Files: gui/app.js:19 (the `attrs` loop), and 18 call sites, for example app.js:1048, 1070, 1079, 1083, 1305, 1309; gui/index.html:5
- Severity: low-med (layout only). Confidence: high (CSP semantics, not run in Electron).
- What is wrong: index.html sets `style-src 'self'` with no `'unsafe-inline'`, which also covers `style-src-attr`. `h()` applies `attrs.style` with `e.setAttribute('style', ...)`, and CSP blocks that. Only CSSOM writes (`el.style.width = ...`, as at app.js:531 and :1300) are allowed. The ~18 spacing and alignment tweaks (confirm-screen margins and gaps, the compact card's `align-items:flex-start`, the activity line's `padding-left`) are silently dropped. The console logs a CSP violation per call.
- Fix: in `h()`, special-case `style` by assigning `e.style.cssText = v`. CSSOM `cssText` is allowed, but test it under the real CSP. Or move the rules to classes in the stylesheet.

## 7. Races across `setup()`, `repo:choose` and the run start (no in-process lock)
- Files: gui/main.cjs:42-92 and the `if (!ctx) await setup()` lines (117, 159, 172, ...), :131-140, :254-266
- Severity: low. Confidence: needs-verification (timing windows; each step is plain code reading).
- What is wrong:
  - `setup()` awaits `findRepoRoot` before assigning `ctx` and `watcher`, and nothing serialises concurrent first calls. If two handlers both see `ctx === null`, the second assignment overwrites `ctx` and `watcher`. A watcher that was already `start()`ed is then never stopped, so its handles stay open and keep pushing stale refreshes.
  - A `setup()` already in flight when `repo:choose` runs finishes afterwards and installs the OLD repository's `ctx` and `watcher`. The new `chosenDir` is ignored until the next choose.
  - `run:start` checks `status.run.in_flight` and then spawns, with no lock. The renderer's `cf.starting` blocks a double click in one window. A second window, a terminal, or a stale `ctx.overview` can still produce two spawns. The second `start()` opens `out` with `'w'` and truncates the first run's log while the first run writes to it. The spawn count for two concurrent `runner.start` calls was 2.
- Fix: memoise setup (`let setting = null; ctx ||= await (setting ||= setup())`, with a generation counter that `repo:choose` bumps). Keep a per-batch `starting` Set in main. Open `out` with `'a'`, not `'w'`, when a run could be live.

## 8. `shell.openPath` is guarded only lexically and will execute whatever it names
- Files: gui/main.cjs:328-335, gui/guard.cjs:25-33
- Severity: low. Confidence: high (for the behaviour; exploitability depends on repo content).
- What is wrong: `repoPath` only applies `checkBatchPath` and a prefix check. It does not follow symlinks. ticket.cjs's `resolveInside` does, but `open` does not use it. It also does not refuse `.git`, NTFS streams (`a/x:y` passes: `repoPath('C:/r','a/x:y')` gives `C:\r\a\x:y`), or executable extensions.
  - The paths come from repo-controlled data: `ticket.file`, `ticket.handoff`, `batch.path`. So a cloned repo with an in-repo symlink or junction can make "Open ticket" or "Open the log" open a file or folder outside the repo, and an in-repo `.cmd`/`.bat`/`.exe`/`.lnk` named as a ticket or handoff file is launched by the default handler instead of opened in an editor.
- Fix: run the path through `resolveInside` (realpath containment) and reject `:` in segments. Allow-list extensions (`.md .txt .log`) or use `shell.showItemInFolder` for anything else.

---
Checked and found fine (not reported):
- `checkBatchPath` rejects `..`, backslash, a drive letter and a leading dash.
- `a/./b` and `a//b` normalise safely in `repoPath`.
- bash.cjs correctly refuses the WSL launcher.
- The watcher's debounce, one retry and `dirtyWhileReading` logic are sound apart from #4.
- Inline `style` in `h()` is the only CSP defect found.
