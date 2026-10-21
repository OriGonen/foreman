# Hung-process watchdog ("claude-reaper") — report

Status: design agreed in a grilling session on 2026-10-01. No code yet. No tickets written.

## The problem

On 2026-09-30 a `python3 -` process (PID 20028) sat waiting on stdin from 22:14 until it was
killed by hand the next morning: about two hours alive, about 0.08 s of CPU. It came from a
**Claude Code desktop app (Code tab) session**, not from foreman. The user reports this happens
often: processes started by the implementing session, possibly including the smoke suite, never
stop.

## What actually causes it

Verified in this session (desktop app, Claude Code 2.1.284), and confirmed against the Claude Code
docs ([tools reference](https://code.claude.com/docs/en/tools-reference.md),
[headless](https://code.claude.com/docs/en/headless.md),
[env vars](https://code.claude.com/docs/en/env-vars.md),
[hooks](https://code.claude.com/docs/en/hooks.md)):

- **A foreground Bash command that reaches its timeout is moved to the background, not killed**
  (documented; the only exception is a command starting with `sleep`). A probe
  `python3 -c "time.sleep(600)"` with a 5 s timeout came back "moved to the background"
  and kept running, using 0.09 s of CPU: the same profile as the incident.
- **Background tasks have their own limit: 30 min by default, 2 h at most**, and the env vars can
  only raise it. The incident's ~2 h fits that cap (an inference, not verified).
- **Stopping the background task kills the whole tree.** After TaskStop, both the `python3.exe`
  launcher and the `python.exe` child it starts were gone. So the cause is a hung command moved to
  the background and then forgotten, not processes that survive their parent being killed.
- The only off switch, `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`, disables **all** background work.
  Timed-out commands would then die at the 2-10 min foreground limit, which kills the hour-plus
  smoke suite and every deliberately backgrounded command. Rejected.
- In `claude --print`, **background tasks are killed about 5 s after the turn ends**, so foreman's
  agents already can't leave processes running after their turn. The leak is mainly an
  interactive-session problem.
- In both the Bash and PowerShell tools, stdin is empty (`/dev/null`), so a bare `python3 -` exits
  at once. The incident's process was most likely reading from a pipe whose writer had stopped,
  e.g. `something | python3 -`. The idle rule below catches that whatever the cause.

## Foreman today (for reference)

foreman has no hang protection of its own. The design below doesn't change foreman's code; these facts
explain why it doesn't need to.

- The agent call is a plain foreground pipeline: `exec_run … | node foreman-stream.cjs > payload`
  ([foreman-loop.sh:949](../../lib/foreman-loop.sh:949); checkpoint turn at
  [foreman-loop.sh:706](../../lib/foreman-loop.sh:706)). There is no timeout, kill or idle check
  anywhere in `lib/` or `bin/`.
- Agent launch points: [local.sh:19](../../lib/exec/local.sh:19),
  [_sbx.sh:98](../../lib/exec/_sbx.sh:98), and `foreman order`'s own call at
  [foreman-order.sh:163](../../lib/foreman-order.sh:163).
- `FOREMAN_MAX_MINUTES` is checked only between iterations
  ([foreman-loop.sh:883](../../lib/foreman-loop.sh:883)).
- `on_interrupt` only sets a flag ([foreman-loop.sh:603](../../lib/foreman-loop.sh:603)).
- The default output format is `json`, a single object printed at the end of the turn. `stream-json`
  is used only under `--live` ([foreman-exec.sh:122-124](../../lib/foreman-exec.sh:122)). A detector
  based on output going quiet would therefore need every run switched to `stream-json`.
- The prompt tells the agent to run checks in the foreground "however long it takes"
  ([prompt.template.md:50](../../lib/prompt.template.md:50)), so long silent commands are legitimate.
- `claude.exe` and `sbx.exe` are native Windows programs. MSYS `kill`/`timeout` may not reach their
  child processes; `taskkill` is on PATH.

## Measurements (this machine, 395 processes)

| What | Cost |
|---|---|
| Full process query (`Get-CimInstance Win32_Process` with parent and CPU) | about 170 ms CPU, 270 ms wall time |
| Cheap check (`Get-Process` by name, includes CPU time and start time) | about 9 ms CPU |
| PowerShell (`pwsh`) cold start | about 535 ms (`powershell` 5.1: about 463 ms) |
| Minimal resident `pwsh` | 79 MB in RAM / 27 MB private |
| Tiny compiled C# program (built with Windows' own `csc.exe`), resident | 21 MB in RAM / 17 MB private, about 40 ms per sample |

The desktop app is itself a `claude.exe`: PID 7568, parent `sihost`, running since 29/09. It had
17 `claude.exe` children, some alive for two days. Only one child's command line has been checked:
`…\Claude\claude-code\2.1.284\claude.exe --output-format stream-json …`, a Code-tab session.

## Decisions

### Scope
- **Desktop-app Code-tab sessions are the main target**; that's where the incident came from.
  The CLI and foreman's local runs are covered by the same rule at no extra cost.
- The smoke suite is covered whenever an agent runs it. There is no separate per-case guard in
  `test/smoke.sh`.
- **Out of scope:** sandbox (`FOREMAN_EXEC=sandbox`) runs. The agent's processes are inside the
  container, where the host can't see them, and `--print` already kills its background tasks when
  the turn ends. `sbx` itself is never killed.

### What counts as a Claude Code session
- A session is a `claude.exe` running from `…\AppData\Roaming\Claude\claude-code\<version>\`
  (desktop-app Code-tab sessions) or `~/.local/bin/` (CLI and foreman). The watchdog watches these,
  and their tool-command trees can be killed.
- **Never** treat the desktop app's own `claude.exe` as a session, and never kill it. That covers
  the app window (the long-lived process whose parent is `sihost`) and its helper processes
  (rendering, GPU and other internal helpers). They share the `claude.exe` name, so the rule must
  **match on the program's path, not its name**.

### Form and home
- A standalone PowerShell script under `tools/claude-reaper/` in this repo, with a short install
  note. No change to foreman's loop.
- It runs as a **Windows scheduled task every 5 minutes**, started headless so no console window
  flashes. Nothing is resident between runs (0 MB). State (each process's last-seen CPU time) is
  kept in a small file between runs. It doesn't depend on hooks and finds nothing to do when
  Claude isn't running.
- Each run does the cheap check (about 9 ms). The full parent lookup runs only when some process is
  older than 15 min and its CPU time hasn't moved. Average cost is about 0.15% of one core,
  dominated by PowerShell startup.
- Rejected:
  - resident PowerShell (79 MB, always running, because the desktop app is always open);
  - a compiled C# program (smallest resident footprint, but adds a language and a build step);
  - a SessionStart hook launcher (unnecessary once the task is scheduled).

### What counts as hung
- The unit is the **whole tree under a Claude Code tool command**: the shell (Bash/PowerShell) that
  the session spawned, plus everything under it. A `bash` waiting on its child uses no CPU, so
  single processes can't be judged alone.
- **Hung = the tree's total CPU grew by less than 0.5 s over 15 minutes.** With 5-minute runs, a
  hung tree is caught 15-20 min after it goes idle.
- Any tool-command tree qualifies, foreground or background. Foreground commands are capped by
  Claude Code's own timeout (10 min at most), so in practice only backgrounded ones last 15 min.

### Never killed
- A session `claude.exe` itself, and anything that isn't under a session's tool command.
- A session's direct children that aren't shells: MCP servers and language servers.
- The desktop app's own `claude.exe` and its helpers.
- Any tree containing a process that used CPU in the window.
- Anything younger than 15 min.
- Anything on the keep list in a config file next to the script, matched by process name anywhere
  in the tree. Defaults: `docker`, `sbx`, `sleep`.
- Any tree whose shell command line contains the marker `# reaper:keep` (e.g.
  `npm run dev  # reaper:keep`). Agents learn the marker from the user-level `~/.claude/CLAUDE.md`,
  so every project gets it.

### The kill and what follows
- `taskkill /T /F` on the tool's shell, which removes the whole tree.
- The agent finds out indirectly: its tool call or background task ends with an error. No retry
  logic is needed; the agent decides what to do.
- **Report-only by default.** It only logs what it would kill. Killing is turned on with a flag after
  about a week, once the 15 min / 0.5 s numbers and the keep list have been checked against real
  use.
- Notification, in both modes:
  - a line in a log file;
  - a Windows notification, at most one per process;
  - if the tree belongs to a background task, a line in that task's output file
    (`…\tasks\<id>.output`) saying it was killed by the reaper and why, if that turns out to be
    feasible.

## Before relying on the path rule

First implementation step: list the path and command line of **every** `claude.exe` child of the
desktop app, to confirm which are Code-tab sessions and which are app helpers. Do this before
trusting the "session = program under `claude-code\<version>\`" rule. Only one of the 17 children
has been checked so far.

## Open questions left for implementation

- Can the scheduled task run with no window at all (`conhost --headless`, or a hidden launcher)?
- Can the background task's output file be found from the process tree, so the "killed by reaper"
  line (Notification, above) can be written?
- How to show the Windows notification from PowerShell without installing a module.
