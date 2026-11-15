# 09: `foreman stop --now`, findings

**Read this first: nothing below was run on Windows.** The session that built ticket 09 ran on
Linux (no `tasklist`, no `taskkill`, no MSYS). The Linux column is measured; the Windows column is
what the approach is built to survive, and what is still to be confirmed by hand. The harness that
produces the table is `09-spike.sh` beside this note (`bash .scratch/gui/notes/09-spike.sh -v` in
Git Bash fills the Windows column in about 40 seconds).

## What Ctrl-C does, and what is missing for a detached run

In a terminal, Ctrl-C sends SIGINT to the whole foreground group: the loop (`foreman-loop.sh`), the
agent (`claude`), the feed (`node foreman-stream.cjs`) and whatever the agent started. The loop's
`on_interrupt` only sets `PAUSE_REQUESTED`; bash runs a trap only when its foreground child is
done, so it is the agent dying from the same SIGINT that lets the loop move on. It then records the
turn, keeps the stall marker (tree dirty + `PAUSE_REQUESTED`), writes the footer
(`PAUSED: interrupted (Ctrl-C)`) and exits 10.

The app starts the run with `detached`, `windowsHide` and stdin ignored: no console, so nothing
sends it a Ctrl-C, and a stop has to send what the terminal would have.

The line the app starts a run with, and the by-hand check uses:

```
node -e 'const {spawn}=require("child_process"),fs=require("fs");const fd=fs.openSync(".foreman-run-out.txt","w");const p=spawn("foreman",["run","<batch>"],{cwd:process.cwd(),detached:true,windowsHide:true,stdio:["ignore",fd,fd],shell:process.platform==="win32"});p.unref()'
```

(On Windows `foreman` is `foreman.cmd`, hence `shell`; `.foreman-run-out.txt` is any file.)

## What was tried

The stand-in tree is a detached bash "loop" with an INT trap like the real one, whose foreground
child is a native node "agent" with a native child of its own. After each action, 4 seconds.
`loop-int` = the loop's INT handler ran.

| # | Approach | Linux: loop-int | loop | agent | grandchild | Windows |
|---|----------|-----------------|------|-------|------------|---------|
| A | `kill -INT <loop pid>` (the pid in `pid`) | no | alive | alive | alive | not run |
| B | `kill -INT` the loop and every process below it | **yes** | exited | gone | gone | not run |
| C | a `stop` file the loop checks (no signal) | no | alive | alive | alive | not run |
| D | `kill -INT` the agent only | no | exited | gone | **alive** | not run |
| E | `taskkill /F /T` on the agent (`kill -9` here) | no | exited | gone | **alive** (`/T` would take it on Windows) | not run |
| F | `taskkill /F /T` on the loop (`kill -9` here) | no | exited | **alive** (`/T` would take it on Windows) | alive | not run |
| G | the chosen one: C + B, then force what is left below the loop | **yes** | exited | gone | gone | not run |

What the Linux column says, and why it matters on Windows too:

- **A does nothing on its own.** The signal is held until the foreground child is done, and the
  agent is the foreground child. Delivering to the loop alone is never a stop. (It is also lost
  entirely if the loop was started by `&` in a script, which ignores SIGINT from its birth: bash
  cannot trap a signal that was ignored on entry. The test for that case is in `smoke-json.sh`.)
- **F is the "last resort" of the ticket, and it is wrong for this job**, on every platform: the
  loop dies without its handler, so there is no record of the turn, no footer and no marker's
  rewrite, and what was below it is left running (Linux) or only killed by the tree walk (Windows).
- **B is Ctrl-C.** It is the only single action that gives `loop-int=yes` and a clean tree.
- **C only works once the agent is gone**, because the loop reads the file between turns.

## The approach built: G

`foreman stop --now` (`lib/foreman-control.sh`) does, in this order:

1. writes `<batch>/.foreman-run/stop`;
2. sends SIGINT to the loop and to every process below it (found by walking `/proc/*/stat`, which
   MSYS has; `ps` where there is no `/proc`);
3. after `FOREMAN_STOP_GRACE` seconds (default 5), ends what is still running below the loop:
   `taskkill /F /T /PID <winpid>` where `/proc/<pid>/winpid` exists and `taskkill` is there (this
   takes a native process's own children with it), then `kill -9`. **Never the loop**: skipping
   its INT handling is exactly what the ticket does not want, and it is why F is not the plan;
4. waits up to `FOREMAN_STOP_WAIT` seconds (default 60) for the loop to finish and exit. Exit 0
   once it has; exit 1 and a line saying so if it has not (the loop is not killed).

The loop (`lib/foreman-loop.sh`) gets one additive function, `check_stop_file`: if a `stop` file
is in the control directory it calls the loop's own `on_interrupt`. It runs at the top of every
iteration and straight after the agent's turn. The result is the Ctrl-C result by the same code, not
a copy of it: the same warning, `PAUSE_REASON="interrupted (Ctrl-C)"`, the marker rewritten, the
same footer, exit 10. With no file, one `[ -e ]`: plain `run` output is unchanged. The file is
removed with the rest of the directory when the run ends, or when the next run starts there.

Why each layer is there, given that Windows was not available:

- **Step 2 is Ctrl-C itself** and works wherever MSYS can signal the process (the loop and any MSYS
  `bash`, `sleep`, `git` below it). It is what keeps the loop's own INT path in the common case.
- **MSYS cannot hand SIGINT to a native Windows process** (`claude.exe`, `node.exe`) the way it can
  to its own, so step 3 is how the agent and the feed end on Windows if step 2 did not: through the
  Windows pid and `taskkill /T`. When they end, the loop's foreground wait returns and the trap (if
  step 2 reached it) or the stop file (if it did not) turns that into the pause.
- **The stop file is why the stop does not depend on step 2 reaching the loop.**

## What the Windows run must confirm (the by-hand part of the ticket)

1. `bash .scratch/gui/notes/09-spike.sh -v` in Git Bash. Fill in the Windows column. The row to
   look at is G (`loop-int=yes`, everything gone); if B shows `agent=ALIVE` there, step 3 is what
   does the work on Windows, and that is fine; if G shows `loop=ALIVE` or `grandchild=ALIVE`, the
   chosen approach needs another look (probably `/proc/<pid>/winpid` for the agent's children).
2. Start a run with the `node -e` line above, on a batch whose repository ignores
   `**/.foreman-run/` and has a long ticket.
3. `foreman stop --now`. Expect: exit 0; the output file ends with `PAUSED: interrupted (Ctrl-C)`
   and exit status 10; `batch/.foreman-stall-marker` exists; `git status` shows the ticket's
   work.
4. `tasklist | findstr /i "claude node bash"`: nothing left from the run.
5. `foreman run <batch>` again: it opens with a review turn.

Open questions the Windows run answers: whether MSYS `kill -INT` between two separate MSYS process
trees reaches the loop (the harness's A and B); whether `/proc/<pid>/stat` lists the native agent
under the loop (the harness's `descendants`); whether `taskkill /F /T` leaves the loop alone when
given only the agent's pid (it does by construction, but the agent's parent link is what Windows
uses).
