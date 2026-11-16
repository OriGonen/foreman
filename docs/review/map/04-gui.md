# Map 04 - gui/ (Electron app) + lib/foreman-gui.sh

Windows-only desktop window over the CLI. Electron 45.3.1 is the sole dependency (gui/package.json:12). It runs from the git checkout; nothing is persisted (main.cjs:6-7).

## 1. Process architecture
- **Main** (main.cjs, 365 lines) owns every child process, every fs read and the single `BrowserWindow`. The window is `contextIsolation`, `sandbox`, no node, no webview (main.cjs:343-347). Navigation and `window.open` are denied (guard.cjs:19-20). Permission requests are denied (main.cjs:358).
- **Preload** (preload.cjs) exposes `window.foreman` through `contextBridge`. It is a flat set of `ipcRenderer.invoke` wrappers plus three subscribe helpers that return an unsubscribe fn. No channel names reach the page.
- **Renderer** (index.html) loads plain scripts: model, states, runplan, runview, runend, art, preview, app. The CSP is strict: `default-src 'self'`, no inline script or style (index.html:5). All DOM is built with createElement/textContent, so there is no markup injection path.
- Every handler first calls `trusted(event)`, which compares `senderFrame.url` to the page's file URL (main.cjs:108-112).
- **Invoke channels (renderer -> main).** Each returns `{ok:true,...}` or `{ok:false,error:{kind,message,tried,dir}}` via `describe()` (main.cjs:38):

| channel | payload | does |
|---|---|---|
| overview:load | batch or null | `status --all` + `status <b>`, decorated with conditions, starts the watcher (114) |
| repo:choose | - | folder picker; drops ctx and watcher, sets `chosenDir` (131) |
| clipboard:init | - | writes the constant `INIT_COMMAND` (148) |
| dryrun:load / report:load(batch,{byTicket,run}) / doctor:load / doctor:fix | | one CLI `--json` call each (156-201) |
| ticket:load(batch,name) / ticket:save(batch,name,text,base) | | ticket.cjs; save is the only fs write in the app (205-226) |
| run:confirm | batch | dry-run + `git check-ignore` + conf text + env caps (237) |
| run:start(batch,request) | | re-validates, spawns a detached `foreman run` (254) |
| run:load / run:keys(batch,"+-L") / run:stop(batch,now) | | live.read / `foreman keys` / `foreman stop [--now]` (273-310) |
| window:compact(bool) | | resizes the window (314) |
| open | repo-relative path | `shell.openPath` (328) |

- **Push channels (main -> renderer).** `overview:update` carries an overview doc or `{ok:false,error}` (main.cjs:102). `run:update` carries `{batch, run|null}` (105). `run:exit` carries `{batch, code, signal, out}` (265).
- **Pure modules** (UMD, loaded both as `<script>` and by `require`): model.js, states.js, runplan.js, runview.js, runend.js, preview.js. DOM only: art.js, app.js. Pure logic with injected IO: guard.cjs (win32 path math only), conditions.cjs, overview.cjs.
- **fs:** ticket.cjs (r/w, injectable `io`), live.cjs (read, injectable `fs`), runner.cjs (mkdir/open `out`, injectable), watch.cjs (`fs.watch`), bash.cjs (`existsSync`), main.cjs `readConf` (233).
- **child_process:** foreman.cjs (`execFile`, injectable `run`) and runner.cjs (`spawn`, injectable).

## 2. Talking to the CLI
- Every call is `<bash.exe> <checkout>/bin/foreman <cmd> ...`, with cwd = repoRoot, `windowsHide`, stdin ignored, and a 64 MB maxBuffer (foreman.cjs:121-134, 103-110). There is no timeout.
- `checkout` is `path.resolve(__dirname,'..')` (main.cjs:51), so the GUI always drives the toolkit it lives in.
- Env is a whitelist, `cliEnv` (foreman.cjs:36-55): system vars plus anything `FOREMAN_*`, with forced `FOREMAN_SHOW/COLOR/INTRO=never` and `GIT_OPTIONAL_LOCKS=0`. Tokens are not passed, so the CLI reads its own credentials file.
- **Commands used.**
  - JSON: `status <b> --json`, `status --json --all`, `dry-run <b> --json`, `report <b> --json [--by-ticket] [--run id]`, `doctor --json`, `doctor --fix --json`.
  - Words: `keys <b> <[-+Ll=_]+>`, `stop [--now] <b>`.
  - Raw git through `bash -c`: `git rev-parse --show-toplevel` (foreman.cjs:208), `git check-ignore -q -- "$1/.foreman-run/pid"` (187).
  - Run: `run <b> <n|--unlimited> [--live]` (runner.cjs).
- `parseOutput` (foreman.cjs:80) requires one JSON object, `foreman_json === 1` and `doc.command === asked`. Error kinds are spawn, exit, parse, version, bad-batch, bad-run, not-a-repo.
- **Watching.** watch.cjs uses `fs.watch(dir,{recursive:true})` on each non-finished batch dir, plus the selected one (overview.cjs:68). There is no timer polling (watch.cjs:4). Events are debounced 150 ms.
  - One retry is allowed after a failed read, because the loop may have renamed things to `DONE_`.
  - `sync()` re-asks for the dir set after every read, so the watch follows renames.
  - A read is a full overview refresh (2 bash spawns, plus `report --run` for a live run). The exception is when a run is in flight and every change is under `.foreman-run/` but is not `pid` or `run` (live.cjs:109-114, main.cjs:78). Then only the control files are read from disk, with no process spawned.
- **Stop / pause.** `stop` sets the budget to the current iteration (the run finishes the iteration, then pauses). `stop --now` is the CLI's own sequence (lib/foreman-control.sh:15-41): a `stop` file, SIGINT to the loop and its descendants, then after `FOREMAN_STOP_GRACE` (5 s) `taskkill /F /T` on the children. It waits up to 60 s. The GUI never signals or kills anything itself. `+`/`-`/`L` go through `foreman keys`, which writes the control files.

## 3. Modules (deps)
- main.cjs: wiring, IPC and window. Requires bash, foreman, watch, overview, ticket, runner, live, conditions, states (`INIT_COMMAND`), guard.
- preload.cjs: the bridge. Requires electron only.
- bash.cjs: finds Git Bash. Order is FOREMAN_BASH, then `git.exe` on PATH -> `<root>\bin\bash.exe`, then `C:\Program Files\Git\bin\bash.exe`. It refuses the WSL launcher. No deps.
- foreman.cjs: CLI client, `cliEnv`, `checkBatchPath`, `checkRunId`, `findRepoRoot`, `ForemanError`, `plainText`. Requires child_process.
- runner.cjs: builds and spawns the detached run, and reads the tail of `out`. Requires runplan and foreman.
- runplan.js: validates a run request, builds the argv, the cap env and the command string, and the confirm-screen view-model and help text. No deps.
- watch.cjs: debounced recursive watcher. Requires fs.
- overview.cjs: selected batch, epoch guard against stale refreshes, `statusOf`, watch dirs. Requires model.js (`pickBatch`).
- live.cjs: reads `<batch>/.foreman-run/{budget,iteration,live,activity,feed,spent}`, caches the last `report --run`, and exports `onlyControlFiles`. Requires fs only (foreman injected).
- conditions.cjs: the "runner missing" and "login expired" states, from `doctor --json` and `report --run`. The doctor read is async behind the overview and fires `onChange`. No deps.
- ticket.cjs: ticket page read and handoff save, with symlink-safe `resolveInside`, a base-text conflict check and EOL preservation. Requires foreman (for `ForemanError`).
- guard.cjs: argv -> repo, navigation denial, `repoPath` (lexical check, then win32 join). Requires foreman.
- model.js: all screen wording, rail, `pickBatch`, `renamedTo`, ticket page and notes. Pure.
- states.js: the six pane states, `INIT_COMMAND`. Pure.
- runview.js: live screen view-model. Pure.
- runend.js: maps `status.last_run` (exit code) to an end scene. Pure.
- preview.js: tiny markdown -> node list. Pure.
- art.js: SVG dome and scenes. DOM.
- app.js (1643 lines): every screen, one IIFE. Depends on the six `window.Foreman*` globals and `window.foreman`.
- lib/foreman-gui.sh: `foreman gui [dir]`. It looks for `gui/node_modules/electron/dist/electron[.exe]`. If it is missing, it offers `install.sh --gui` on a tty. Then it resolves the git toplevel (or uses dir), converts paths with `foreman_mixed_path`, unsets `ELECTRON_RUN_AS_NODE`, and starts `nohup [setsid] electron <gui> <repo> </dev/null >/dev/null &` in a subshell, then `exit 0`.

## 4. Child process lifecycle
- **Spawn.** runner.cjs:61 uses `detached:true, windowsHide:true, stdio:['ignore',fd,fd]`, with stdout and stderr in `<batch>/.foreman-run/out`, truncated per run. It calls `child.unref()` on the `spawn` event. `start` resolves `{pid,command}` as soon as the process exists. The pid is returned but never used again.
- **Exit.** `child.once('exit')` calls back into main, which sends `run:exit` with the tail of `out`. This only fires while the app is alive and only for runs started by this app process.
- **Quit.** `window-all-closed` -> `app.quit()`. `before-quit` only stops the watcher (main.cjs:364-365). Nothing is killed, so a run outlives the app by design (runner.cjs:3). A relaunch finds it through `status.run.in_flight`, and caps then come from conf/env (live.cjs:53).
- **Windows.** Git Bash is a hard requirement. Paths given to the CLI are mixed form (`C:/x`) or repo-relative with forward slashes, and `repoPath` converts them back to backslashes for `shell.openPath`. `stop --now` depends on `taskkill` and `/proc/<pid>/winpid` (an MSYS detail). `foreman-gui.sh` copes with MSYS `setsid` being absent.

## 5. Logic duplicated from lib/
- **Conf parsing, four regex readers, no shared one**:
  - `capsFromConf` (live.cjs:53) takes the first numeric match, for the caps.
  - `execModeOf` (conditions.cjs:25) takes the last match and knows the legacy `RALPH_` prefix.
  - `capSource` (runplan.js:112) only tests whether a line exists.
  - `readConf` (main.cjs:233) is a raw read feeding those three.
  - The CLI itself `source`s conf (foreman-config.sh), so quoted values, `${VAR:-x}` and later lines are handled differently from the GUI.
- **Ticket and batch naming**:
  - `ticketName` is re-implemented in model.js:209, runview.js:24 and runend.js:32. Each carries its own copy of the DONE_ strip regex `^[A-Za-z]+_(?=\d)`, and runend.js adds `slugOf` (21).
  - The DONE_ prefix is configurable in the CLI (`FOREMAN_DONE_PREFIX`, lib/foreman-tickets.sh:130), but the GUI hard-codes the shape.
  - `renamedTo` (model.js:517) guesses where a batch was renamed to, from name suffixes.
- **Run control-dir format**: filenames and line shapes (`budget`, `spent "COST MAX"`, `activity "EPOCH LABEL"`, feed `mm:ss · Tool text`) mirror foreman-keys.sh and foreman-stream.cjs (live.cjs:20-48). So does the pid/run start/end signal (live.cjs:110).
- **Control-dir path** `.foreman-run` is repeated in runner.cjs:52, main.cjs and foreman.cjs:190.
- **Path safety**: three separate validators: `checkBatchPath` (foreman.cjs:59), `repoPath` (guard.cjs:25) and `resolveInside` (ticket.cjs:26). Only the last follows symlinks.
- Status, dry-run and report parsing are NOT duplicated: the GUI trusts the CLI's JSON (a strength).

## 6. Smells
- **Run exit callback can crash main.** The closure at main.cjs:264-266 reads the global `ctx`. After `repo:choose` sets `ctx = null` (:137), a later exit throws a TypeError in the main process. It also reports on a stale repo.
- **`if (!ctx) await setup()` races.** It is repeated in 12 handlers (e.g. main.cjs:117, 159). Two concurrent first calls run `setup()` twice and overwrite the global `watcher`, so the old watcher's handles leak. The `trusted`+try/catch+describe boilerplate is also copy-pasted 15 times; a wrapper would remove it.
- **A dead run is never noticed from the GUI side.** There is no liveness poll (watch.cjs:4 is deliberate). A loop that is hard-killed, or a terminal run that crashes, leaves the `pid` file stale. That produces no fs event, so the screen stays "in flight". The `run:exit` event covers only runs this app process started.
- **Elapsed clocks don't tick.** There is no setInterval anywhere in the renderer. `runview` computes `now - activity.epoch` from `at: Date.now()` captured at read time (live.cjs:97, runview.js:82), so the clock only advances on file events.
- **Cost of each change.** Any non-control change during a run (progress.txt, the record, tickets) triggers `status --all` + `status <b>` + `report --run`. Each is a Git Bash spawn that takes seconds (per overview.cjs:3). `execFile` has no timeout, so a hung bash hangs the IPC call forever (foreman.cjs:105).
- **Inline style under strict CSP.** app.js:1309 sets `attrs:{style:'padding-left:16px'}`. `style-src 'self'` (index.html:5) blocks an inline style attribute, so the padding is silently dropped. app.js:531 correctly uses CSSOM.
- **`shell.openPath` on repo-relative paths** (main.cjs:331) uses only the lexical `repoPath` check. A symlink inside the repo can point outside, and an in-repo `.cmd`/`.exe` is executed by the default handler. `resolveInside` isn't used here.
- **Env whitelist is too strict for the run.** `cliEnv` is also what the detached `foreman run` gets (runner.cjs:35). It drops `HTTP(S)_PROXY`, `SSH_AUTH_SOCK`, `GH_TOKEN`/`GIT_*` and `ANTHROPIC_*`, so a run started from the GUI can behave differently from a terminal one when anything but credentials-file auth is used.
- **bash.cjs:66** only knows `C:\Program Files\Git`. Per-user Git installs (`%LOCALAPPDATA%\Programs\Git`) and x86 are found only if git.exe is on PATH.
- **TOCTOU on starting a run.** The in-flight check (`status`) and the spawn (main.cjs:262-264) are not atomic and there is no in-process lock, so a double click can start two. The CLI's own guard is the only backstop.
- **Conf regex divergence** (see 5): `capsFromConf` takes the FIRST match but the shell takes the LAST. It also ignores the legacy `RALPH_MAX_*`, so the "caps" shown for a running terminal run can be wrong.
- **app.js is a 1643-line IIFE** with many module-level mutables (`data, lv, cf, rep, dr, tp`) and a second block of consts mid-file (:945-947). Behaviour is only testable through a DOM harness. `typeof api.onRunUpdate === 'function'` guards (app.js:1603, 1612) imply preload/app version skew was a concern.
- `checkBatchPath` is imported twice in main.cjs (:17, :23). The `describe()` error shape drops `code`/`stderr` and everything but four fields (main.cjs:38).
