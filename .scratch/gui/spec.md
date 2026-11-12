# Spec — the app: a Windows desktop window onto the same loop

**Status:** ready-for-agent

Vocabulary: `CONTEXT.md` (new terms: **the app**, **control directory**, **free action**). Why
Electron: `docs/adr/0004-electron-desktop-app.md`. The designs this spec builds: `designs/`
in this directory (see "The picks" below).

## Problem Statement

Foreman's only interface is the terminal. That works while a person is at the terminal. It
works less well for the rest of a batch's life. To see how far a batch has got, someone
runs `foreman status`. To see what a run is doing, they keep its terminal open and readable.
To fill in a handoff file, they find the path in the ticket and open it by hand. To learn what
a batch cost, they run `foreman report`.

None of that is hard, but it is scattered across commands and files. A run in a terminal tab
that was closed by mistake is gone from view, even though it is still running and its files
still say everything. Nothing shows the batch, the run and the bill together in one place.

The terminal is not the problem and must not change. The work is a second, optional window
onto the same files and the same loop. It must cost nothing when it is closed, and nothing
for someone who never installs it.

## Solution

**The app** is a desktop window on Windows that reads the same files the CLI reads and
starts the same `foreman run`. It is an Electron app in `gui/`, run from the git checkout
like the rest of foreman. `bash install.sh` offers it as an option, and `foreman gui` opens
it on the current repository.

It has three rules.

- **The files are the truth.** The app keeps nothing of its own. The truth is the ticket
  status lines, `order.md`, `foreman.conf`, `progress.txt`, `foreman-runs.jsonl`,
  `foreman-runs.log` and the run's **control directory**. The app reads them when it needs
  them and watches them for changes. If it is closed and reopened mid-run, it shows what
  the files say.
- **There is one loop.** Everything the app shows that needs a decision (what's next, what
  would run, what it cost, is the machine ready) comes from the CLI as JSON. The app never
  works out picking, budgets, stalls or landing itself. A run the app starts is a plain
  `foreman run`, detached, steered through the same control files that the run terminal's
  `+` / `-` / `L` keys write.
- **The terminal is unchanged.** Every addition to the CLI is new: new `--json` flags, two
  new commands, and a control directory that moves into the batch only when the repository
  ignores it. No command's plain output changes by a byte. `foreman help` stays as it is.
  `test/smoke.sh` passes untouched.

### The picks

Each screen was drawn as two or three takes on a canvas, dark and light, and one take was
picked. Each pick has its own page, with the picked take only. The canvas in
`designs/source/` keeps every take.

| Screen | Pick | Design | Canvas | Why this one |
|---|---|---|---|---|
| Batch overview | a · Dome and order | `designs/01-overview.html` | `source/OverviewTakes.dc.html` | `foreman status` as a window: the dome sized by tickets landed, the next ticket, the human ticket waiting, then the order with each ticket's spend. Everything is on one screen and it reads top to bottom. |
| Ticket detail | b · Ticket page (and b1, an agent ticket) | `designs/02-ticket.html` | `source/TicketTakes.dc.html` | It has room for the ticket and its handoff file side by side, which is the one edit the app makes. The drawer (a) is too narrow to fill in a handoff. |
| Start a run | a · The bill up front | `designs/03-run-confirm.html` | `source/ConfirmTakes.dc.html` | It costs money, so it is shaped like a bill. It shows what can run, every cap with where it comes from, a cap that isn't set (shown in rust), the exact command, and a button that says the most it can spend. |
| Live run | a · The site | `designs/04-live-run.html` | `source/LiveRunTakes.dc.html` | The terminal run screen in a window. Iterations are listed in order with each one's outcome, the feed is under the running iteration, and the bar along the bottom holds the same controls as the keys. |
| Run end | a · Banner on the run | `designs/05-run-end.html` | `source/EndTakes.dc.html` | The run screen stays where it was, with a banner on top for exit 0, 10, 20 or 30. Each banner has its one next step, with free and paid actions marked. Nothing jumps to another screen. |
| Dry run | a · Settings beside the prompt | `designs/06-dry-run.html` | `source/DryRunTakes.dc.html` | What would run and the settings are on the left, and the exact prompt with line numbers is on the right. Both are visible at once. |
| Report | a · The bill and the ledger | `designs/07-report.html` | `source/ReportTakes.dc.html` | The terminal's report (10a) in a window. Charts (b) would repeat the ledger's numbers for a handful of runs. |
| Doctor | a · The inspection sheet | `designs/08-doctor.html` | `source/DoctorTakes.dc.html` | The terminal's sections in the terminal's order, with the verdict as a stamp. Each fixable row says how to fix it, and **Fix what it can** is the one button. |
| Empty and error states | a · A scene and one step | `designs/09-empty-and-error.html` | `source/StatesTakes.dc.html` | Each of these states blocks everything below it, so it gets the whole pane: a picture, one sentence, the CLI's own message, and one button. |
| Install wizard (terminal) | a · Numbered choice (and a2, the rerun) | `designs/10-install-wizard.html` | `source/WizardTakes.dc.html` | `1` or `2` works with a plain `read` in every terminal, Git Bash's mintty included. An arrow-key menu (b) needs raw key reading for one question. |

Both themes: the app follows Windows' light/dark setting (`prefers-color-scheme`). Dark is
ADR 0003's palette. Light is the app's own (below). The install wizard is terminal output,
so it is dark only.

## User Stories

1. As a person who runs batches, I want to open one window and see every batch in the repo, with how far each has got, so that I don't run `foreman status` once per batch.
2. As a person who runs batches, I want the overview to show the dome, the next ticket and the order, in the same words as `foreman status`, so that the window and the terminal never disagree.
3. As a person who runs batches, I want each ticket in the order to show what it has cost so far, so that I can see where the money went without a report.
4. As a person with a human ticket coming up, I want the overview to say the run will stop at it, so that I do it before starting a run.
5. As a person doing a human ticket, I want to open it and see its text, its criteria and its handoff file side by side, so that I can fill in the handoff while reading what it asks.
6. As a person filling in a handoff file, I want to edit and save it in the app, so that I don't have to find its path.
7. As a person filling in a handoff file, I want a reminder that a secret's location goes there and never its value, so that no secret gets committed.
8. As a person who has done a human ticket, I want to open it in my editor to flip its status line, so that marking it done stays a deliberate edit in the file.
9. As a person reading an agent ticket, I want to see its status, Blocked by, Checks, and its notes from `progress.txt`, so that I know what the loop knows about it.
10. As a person about to spend money, I want starting a run to show the bill first (iterations, `FOREMAN_MAX_COST_USD`, `FOREMAN_MAX_MINUTES`, the model, the exact command), so that I know the most it can cost.
11. As a person about to spend money, I want a cap that isn't set to say so plainly, so that "no limit" is never a surprise.
12. As a person about to start a run, I want to see where it will start and where it will stop, so that I know what I'm paying for.
13. As a person watching a run, I want each iteration listed with its outcome (landed, progressed, stalled, checkpoint, review turn) and its cost, so that I can tell at a glance whether it's going well.
14. As a person watching a run, I want the live tool-call feed of the iteration that is running, so that I can see what the agent is doing right now.
15. As a person watching a run, I want to add or take away iterations, and turn the live feed on and off, so that the app steers a run the way the terminal's keys do.
16. As a person watching a run, I want "Stop after this iteration" and "Stop now", so that I can end a run cleanly or at once.
17. As a person who closed the app mid-run, I want to reopen it and see the same run, so that closing the window never loses or stops anything.
18. As a person who started a run in a terminal, I want the app to show it too, so that the app is a view of the run and not its owner.
19. As a person whose run ended, I want a banner that says how it ended (done, paused, needs a human, waiting on a human) and the one next step, so that I know what to do.
20. As a person whose run needs a human, I want the reason the run gave, so that I'm not guessing.
21. As a person checking before a run, I want a dry run that shows what would run, the settings and the exact prompt, marked as free, so that I can check without spending.
22. As a person reviewing spend, I want the report as a bill and a ledger, by run and by ticket, marked as free, so that I can see what each run cost and produced.
23. As a person setting up a machine, I want doctor in the app, with each problem's fix beside it and a "Fix what it can" that shows what it will append, so that I can get to "ready to run" without reading a log.
24. As a person on a machine missing Git Bash, `claude` or `sbx`, I want the app to say exactly what's missing and the one step to fix it, so that I'm not stuck on a blank window.
25. As a person whose agent login expired, I want the app to say so after the run stops, and how to sign in again, so that I can resume.
26. As a person who opened the app outside a repo, or in a repo with no batch, I want to be told what to do next, so that an empty window still helps.
27. As a person installing foreman, I want the installer to ask whether I want the desktop app too, so that I don't download Electron unless I want it.
28. As a person scripting the install, I want `--gui` and `--no-gui`, so that the installer never stops to ask.
29. As a person who installed the CLI only, I want `foreman gui` to offer to install the app, so that adding it later is one step.
30. As a person removing foreman, I want `install.sh --uninstall` to remove the app and its shortcut too.
31. As a person who never installs the app, I want foreman to behave and cost exactly what it does today, so that the app is purely opt-in.
32. As a person who keeps secrets on this machine, I want the app never to show or store a token, so that the Docker PAT and `~/.config/foreman/env` stay where they are.
33. As a person with the app closed, I want it to cost nothing: no daemon, nothing at login, no extra process when I run a command.
34. As a person running the smoke suite, I want it to pass untouched, so that the app can't have broken the CLI.

## Implementation Decisions

### Answers recorded

The questions asked before designing, and their answers:

| Question | Answer |
|---|---|
| What kind of GUI | An Electron desktop app, **Windows only for now**. Run from the git checkout. No releases, signing or auto-update: updating is `git pull && bash install.sh`. |
| Dependencies | Vanilla HTML/CSS/JS. `electron` is the only npm dependency, pinned exactly in `gui/package-lock.json`. No native modules (no node-pty), no electron-builder, no framework, no bundler. Stable Electron APIs only: `BrowserWindow`, `contextBridge` / `ipcMain`, `child_process`, `shell.openPath`, `nativeTheme`. Electron is bumped once or twice a year by hand. |
| How it's installed | `bash install.sh` asks "CLI only" or "CLI + desktop app" when stdin and stdout are both terminals. `--gui` / `--no-gui` answer it up front. On a rerun it offers only the missing piece. `--uninstall` removes everything, the app and shortcut included. Installed-or-not is read from disk (`gui/node_modules` and the Start-menu shortcut). `foreman gui` offers to install when the app is missing. Doctor reports "desktop app installed · in sync" only when it is installed. |
| How +/-/L reach a run | Through an additive CLI control channel (the control directory and `foreman keys`), not a pseudo-terminal. |
| Performance | Zero cost when closed: no daemon, nothing at login, no other command touches `gui/`. `fs.watch` plus a debounce, never a timer poll. `--json` is worked out only when asked for. `test/bench.sh` shows no added process on any plain path. `GIT_OPTIONAL_LOCKS=0` on every command the app runs. The app tolerates a `DONE_` rename while it is reading. |
| Why Electron, not Tauri | See ADR 0004. |
| v1 scope | Status and overview, the ticket page, start / watch / `+` `-` `L` / stop a run, the order view, dry run, report, doctor and `--fix`, and filling in a human ticket's handoff. Later: `init`, `order` (writing it), `convert`, `commands`. |
| Which batches | Every batch in the one repository the app is opened on. |
| What the app edits | Only the handoff file a human ticket names. Reordering, `foreman.conf`, and flipping a status line stay in the person's editor. |

### Architecture

```
gui/
  package.json        "electron" only, exact version; "start": "electron ."
  package-lock.json
  main.cjs            the main process: window, IPC, spawning foreman, watching files
  preload.cjs         contextBridge: a small, named API, no Node in the page
  bash.cjs            finds Git Bash's bash.exe (below)
  foreman.cjs         runs `foreman <cmd> --json`, parses, returns; spawns and stops runs
  watch.cjs           fs.watch + debounce over a batch and its control directory
  index.html          strict CSP: default-src 'self'; no remote content, no eval
  app.css             the tokens and components from designs/source/gui.css
  app.js              the screens; renders text with textContent, never innerHTML
  art.js              dome / sunrise / inspector / figure SVG, from designs/source/canvas.js
  icon.ico            the dome mark
```

- **Main process.** It owns every child process and every file read. The page asks for
  things by name (`status(batch)`, `ticket(batch, file)`, `startRun(batch, n)`, `keys(batch, k)`,
  `stop(batch, now)`, `saveHandoff(batch, file, text)`, `openInEditor(path)`), and main
  answers with plain data. `contextIsolation: true`, `nodeIntegration: false`,
  `sandbox: true`. Navigation and `window.open` are refused.
- **Agent and ticket text is text.** Ticket markdown, `progress.txt`, the feed, the prompt
  and CLI stderr are shown as text (`textContent`, a `<pre>`). They are never parsed into
  HTML, so nothing in a ticket can run in the window. The ticket page shows markdown as
  plain text in the mono font, as the designs do.
- **No state.** The app writes nothing outside what the person asks for: the handoff file,
  and a run's output file (below). It has no settings file, no cache, and doesn't remember
  the last repo or window size. Electron's own `userData` directory gets only what Chromium
  writes by itself. The app never reads or writes the cookies or storage in it.
- **The repository.** `foreman gui` opens the app on the repository of the current
  directory (`git rev-parse --show-toplevel`). Opened from the Start menu, the app asks for
  a folder (the "not a git repo" state, 09).
- **Batches.** These are the directories under the repo with a `foreman.conf`, found by
  `foreman status --json --all`, which uses the same search `foreman doctor` uses for
  BATCHES. `DONE_` batches are listed last and dimmed.

### How data comes from the CLI

The main process runs the CLI through Git Bash:

```
<bash.exe> <checkout>/bin/foreman <command> [args] --json
  cwd: the repository root
  env: GIT_OPTIONAL_LOCKS=0  FOREMAN_SHOW=never  FOREMAN_COLOR=never  FOREMAN_INTRO=never
```

and parses stdout as one JSON object. Stderr is kept as text for the error states. Every
`--json` object has `"foreman_json": 1` (a version, bumped only on an incompatible change)
and the `"command"` it answers. Batch paths in JSON are **repo-relative with forward
slashes**, and the app passes batch paths to the CLI the same way, so no `C:\` ↔ `/c/`
conversion is ever needed on either side. Where an absolute path is unavoidable (the repo
root), it is given in mixed form (`C:/Projects/app`, from `cygpath -m` under MSYS, as is
elsewhere).

What the app reads straight from disk, as files rather than decisions:

| What | From | Why not the CLI |
|---|---|---|
| A ticket's text | the ticket file | It is shown, not interpreted. Its status line comes from `status --json`. |
| Notes for a ticket | `progress.txt` | Shown as text, filtered by the ticket's name. |
| A handoff file | the path on the ticket's `Handoff:` line, from `status --json` | It is edited. |
| Iterations and their outcomes | `foreman-runs.jsonl` (`kind`, `ticket`, `committed`, `status_flipped`, `progressed`, `stalled`, `auth_failed`, `limit_hit`, `cost_usd`, `duration_ms`) | The record is already machine-readable, one line per iteration. The outcome word comes from the same fields `foreman report` uses, via `report --json --run <id>`, so the app has no outcome logic of its own. |
| How a run ended | `foreman-runs.log`, its last `# complete` / `# paused:` / `# stopped:` lines | These are the loop's own words. Read by `status --json` and given back as `last_run.end`. |
| The running ticket | the stall marker | It is the loop's own record of the turn in flight. Read by `status --json`. |
| Live budget and feed | the control directory | Below. |

### The additive CLI changes

All are new. None changes an existing command's output when the new flag or command isn't
used. `foreman help` is byte for byte as it is. The additions are documented in a new README
section (ticket 14).

1. **`foreman status --json [<batch>] [--all]`**: the batch, its tickets in order (file,
   number, title, status word, done, human, `Blocked by`, `Checks`, `Handoff`), next,
   human tickets remaining, the run-until note, the warnings `status` prints, spend per
   ticket (from the jsonl), `last_run` (id, end, reason, exit), and `run` (in flight or not,
   its id, started at, iteration, budget, live, control directory). It is built from the
   values `--status` already works out, emitted by `lib/foreman-draw.cjs`'s neighbour
   `lib/foreman-json.cjs` instead of being printed. `--all` lists every batch in the repo
   with its counts only.
2. **`foreman dry-run --json`**: what would run (the ticket, and up to how far the budget
   reaches before a human ticket), the settings `dry-run` prints, and the exact prompt. Free:
   nothing is sent and no sandbox starts.
3. **`foreman report --json [--run <id>] [--by-ticket]`**: the totals, the per-run rows and
   each iteration's outcome word, from `lib/foreman-report.cjs` (which already computes
   them).
4. **`foreman doctor --json`**: each section's rows (`ok` / `warn` / `fail`, label, detail,
   fix), the verdict and the next command. Credentials appear only as `"set"` / `"unset"`.
   A value, or part of one, is never included. `--fix --json` reports what it appended.
5. **The control directory moves into the batch**, as `<batch>/.foreman-run/`, **only when
   `**/.foreman-run/` is ignored** (`git check-ignore`). Otherwise the run keeps today's
   `mktemp -d`, and the app shows the run but can't steer it. The overview says
   "Steering needs `doctor --fix`". The directory holds today's files (`budget`, `live`,
   `iteration`, `screen`, `activity`, `foot`, `spent`) plus three new ones:
   - `pid`: the loop's MSYS pid and Windows pid.
   - `run`: the run id and start time.
   - `feed`: the tool-call lines `--live` shows, one per line, truncated at each iteration
     and written only while live is on.

   The loop removes the directory on exit, except `out` (below), and before any `DONE_`
   rename.
6. **`**/.foreman-run/` in `.gitignore`**: `foreman doctor` checks for it, `doctor --fix`
   appends it, and `foreman init` writes it, **only when the app is installed**. On a
   machine without the app, doctor, init and `--fix` behave and print exactly as they do
   today.
7. **`foreman keys <batch> <+|-|L>...`** applies keys to the batch's running loop through
   `lib/foreman-keys.sh --apply`, as if they were pressed in its terminal. It exits
   non-zero with a one-line message when no run is in flight, or the run's control
   directory is not in the batch.
8. **`foreman stop [<batch>] [--now]`**. Without `--now`, it sets the budget to the
   iteration in flight: the run finishes this iteration and pauses (exit 10, "budget
   reached"), exactly as pressing `-` down to it would. With `--now`, it acts as Ctrl-C in
   the run's terminal does: the loop's own INT handling runs, the stall marker stays, and
   the next run's review turn picks it up. How to deliver that on Windows to a detached
   MSYS process is ticket 09's spike.
9. **`# reason: …`** after `# stopped: needs a human` in `foreman-runs.log`: the one-line
   reason the loop already prints to the terminal (red flag, login expired, attempts
   spent, dirty tree). It is a new line in a log file, not in any command's output.
10. **`foreman gui [<dir>]`** opens the app on the repository holding `<dir>` (default:
    the current directory), detached, and returns at once. If the app isn't installed, it
    says so and, at a terminal, offers to install it (`[y/N]`). Doctor's MACHINE section
    gets "desktop app installed · in sync" (or "out of date: rerun install.sh"), shown only
    when the app is installed.

### Starting, watching and stopping a run

- **Start.** **Start run…** opens the confirmation (03). Its facts come from
  `dry-run --json` and `foreman.conf`: where it starts, how far it can reach, the iteration
  budget (which the person can change, as the CLI argument), `FOREMAN_MAX_COST_USD` and
  `FOREMAN_MAX_MINUTES` with where each is set ("none set" in rust when 0), the model and
  exec mode, and the exact command. The button reads "Start run · up to $X" when a spend cap
  is set, and "Start run · no spend cap" otherwise. The app doesn't override a cap. Caps
  change in `foreman.conf`, in the person's editor.
- **Only with the control directory in the batch.** If `**/.foreman-run/` isn't ignored,
  Start run is disabled and reads "Starting from the app needs `doctor --fix`". The app
  writes `out` there, so an unignored file there would dirty the tree, and a run the app
  can't steer couldn't be stopped from it. Runs started in a terminal are unaffected.
- **Spawn.** `<bash.exe> bin/foreman run <batch> <n|--unlimited> --live`, with
  `detached: true`, `windowsHide: true`, stdin ignored, stdout and stderr to
  `<batch>/.foreman-run/out`, and env `FOREMAN_SHOW=never FOREMAN_COLOR=never
  GIT_OPTIONAL_LOCKS=0`. The app doesn't wait on it. A run outlives the window, as a run in
  a closed terminal tab would if it were detached.
- **Watch.** `watch.cjs` watches the batch directory and its `.foreman-run/` with
  `fs.watch`, debounced 150 ms, and re-reads only what changed. A `DONE_` rename shows up
  as the batch vanishing: the watcher re-finds it through `status --json --all` and
  carries on. A read that fails mid-rename is retried once after the debounce.
- **Steer.** `+` / `-` / `L` in the run bar call `foreman keys`. Nothing in the app writes
  the control files directly.
- **Stop.** "Stop after this iteration" calls `foreman stop`. "Stop now…" asks first ("The
  ticket's uncommitted work is kept, and the next run reviews it"), then calls
  `foreman stop --now`.
- **Reattach.** On open, `status --json` reports `run.in_flight` (the pid is alive) for
  each batch. The live screen rebuilds from the jsonl, the stall marker and the control
  directory. A run started in a terminal is shown the same way, and can be steered if its
  control directory is in the batch.
- **End.** When the run's pid is gone, the app reads `status --json` again. `last_run.end`
  and `last_run.reason` pick the banner (05): exit 0 done, 10 paused, 20 needs a human
  (with the reason; "login expired" gets its own state, 09), 30 waiting on a human. `out`
  is kept until the next run the app starts, so a preflight failure (exit 1) is shown as
  the CLI's own text.

### Windows paths

- **Finding Git Bash** (`bash.cjs`), in this order:
  1. `FOREMAN_BASH`, if set.
  2. `git.exe` on `PATH`, resolved to `<git root>\bin\bash.exe`.
  3. `C:\Program Files\Git\bin\bash.exe`.

  It never uses `C:\Windows\System32\bash.exe` or `…\WindowsApps\bash.exe`, which are WSL
  launchers (the human-tickets handoff 07 found `bash` resolving to WSL in PowerShell).
  When nothing is found, the app shows the "Git Bash missing" state with the paths it tried.
- **Paths to the CLI** are repo-relative with forward slashes, with `cwd` set to the repo
  root, so the CLI never gets a `C:\` path.
- **Paths from the CLI** are repo-relative, or mixed form for the root. The app joins them
  with `path.win32` for `fs` and `shell.openPath`.
- **The shortcut** is `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Foreman.lnk`,
  written by `install.sh` through `powershell.exe -NoProfile` and `WScript.Shell`. Its
  target is `gui\node_modules\electron\dist\electron.exe`, its argument the `gui` directory,
  and its icon `gui\icon.ico`.
- **Line endings.** The handoff editor keeps whatever line endings the file has, and
  writes LF for a file it creates. `.gitattributes` already keeps `foreman.conf` LF. The
  app never writes `foreman.conf`.

### Secrets

The app shows no credential and writes none. `doctor --json` gives `set` / `unset` only.
The app never reads `~/.config/foreman/env`, the Docker PAT, or any environment variable
beyond what it passes to the CLI (`PATH` and the `FOREMAN_*` display variables above). The
handoff editor carries the handoff file's own reminder: "Record where a secret is stored
(a password manager entry, an env var name), never its value."

### Free and paid

Every action is labelled. **Free** marks status, next, dry run, doctor (and `--fix`) and
report, as the README does. **Costs money** marks Start run and Resume. Only "costs money"
actions open the confirmation.

### The light palette

ADR 0003's palette, which is dark, is the app's dark theme. The light theme is the app's
own, and the terminal is not affected:

| Token | Dark | Light |
|---|---|---|
| bg | `#0d0c0b` | `#f4efe6` |
| panel | `#171614` | `#fffcf6` |
| panel-2 | `#1c1a17` | `#f9f3e8` |
| line | `#3a3732` | `#e2d8c6` |
| text | `#ece8e1` | `#2a2117` |
| muted | `#a8a299` | `#6b6154` |
| dim | `#5c574f` | `#a2978a` |
| accent (text) | `#e0a84a` | `#9a5a17` |
| sun fill | `#f6d58e` | `#eaa43a` |
| rust | `#c9772f` | `#a3561b` |
| ok | `#8fcf8f` | `#2e7d3c` |
| err | `#f08078` | `#b43a2f` |
| sky | `#1c1a17` → `#3a2a18` | `#fff8ea` → `#fbe2b0` |

The full token set is `designs/source/gui.css` (`.theme-dark`, `.theme-light`). The app
copies it into `gui/app.css`.

## Testing Decisions

- **`test/smoke.sh` is not edited, and passes.** Every ticket that touches `bin/` or `lib/`
  runs the full suite and records `Full smoke suite: N passed in Mm Ss` in its closing note.
- **New CLI behaviour gets a new suite**, `test/smoke-json.sh`, using `test/fixture.sh`'s
  fixtures. It covers:
  - each `--json` (parses, has `foreman_json: 1`, matches the plain output's facts on the
    same fixture);
  - the control directory moving only when ignored;
  - `foreman keys` and `foreman stop` against a loop on the fake exec;
  - `# reason:`;
  - doctor, init and `--fix` unchanged byte for byte when the app isn't installed, and the
    new line when it is (faked by creating `gui/node_modules/electron`).
- **Plain output is unchanged** is checked directly: for each command, plain output on a
  fixture is compared before and after the ticket (`test/golden/` where it exists, or a
  captured copy in the ticket's test).
- **`test/bench.sh`**: no added process on any plain path, so `status`, `next` and
  `dry-run` start nothing new unless `--json` is passed.
- **The app's own logic** (`bash.cjs` lookup order, `foreman.cjs` parsing and errors,
  `watch.cjs` debounce and rename handling) is plain Node, tested with `node --test` in
  `gui/test/`, without Electron. These tests run in `test/smoke-json.sh` when `node` is
  there.
- **The screens** are checked by a person against their design, on Windows, in light and
  dark. Each app ticket's verification says which design and which states to look at. No
  browser-automation dependency is added. Ticket 15 is the whole-app walkthrough.

## Out of Scope

- macOS and Linux. The app's code avoids Windows-only APIs outside `bash.cjs` and the
  shortcut, but nothing is built or tested there.
- Releases, installers, code signing and auto-update. The app runs from the checkout.
- `foreman init`, `foreman order` (writing an order), `foreman convert`, `foreman commands`
  in the app.
- Reordering tickets, editing `foreman.conf` or a ticket, and flipping a status line from
  the app. "Open in editor" covers all of them.
- More than one repository in a window, and remembering the last one opened.
- A tray icon, a mini mode, notifications, starting at login.
- Showing or storing any credential, and the credential setup work in
  `.scratch/(maybe later) credentials-setup/`.
- Changing `foreman help`, or any command's plain output.

## Further Notes

- The canvases share `designs/source/gui.css` and `designs/source/canvas.js`. The pick
  pages inline both, so each opens on its own. The SVG art in `canvas.js` (dome, sunrise,
  inspector, figure) is the starting point for `gui/art.js`.
- Sample data in the designs is illustrative. The report's totals are the real ones of
  `DONE_terminal-design`, and its expanded iterations are made up.
- Doctor doesn't check the `claude` login (it can't without spending). Login expiry is
  found by the run (`auth_failed`) and shown as an end state.
