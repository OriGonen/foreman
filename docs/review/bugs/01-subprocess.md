# Bugs 01: subprocess lifecycle and signals

Scope: lib/foreman-loop.sh, foreman-control.sh, foreman-keys.sh, foreman-exec.sh, lib/exec/*.sh, foreman-stream.cjs, foreman-order.sh.
Repros ran in a throwaway repo built from test/fixture.sh with FOREMAN_EXEC=fake (git-bash 5.2.26, MSYS). No tracked file was touched.

Checked and found fine: `agent_status=${PIPESTATUS[0]}` survives a trap handler that runs when the pipeline returns (repro: handler ran, `PIPESTATUS=7 0` intact). A stale `stop` file does not poison the next run (`run_ctl_clear` removes it). The keys reader notices a dead loop within 1s and restores the tty.

## 1. No run lock: a second `foreman run` on a batch that is already running starts a second agent (high, confirmed-by-repro)
foreman-loop.sh:1139-1153 (pid-file check at :1143, fallback `RUN_CTL_DIR="$(mktemp -d)"` at :1153).
A live pid in `<batch>/.foreman-run/pid` only makes the second run use a private control dir; it carries on. Nothing else stops it, and the dirty-tree check does not either between an agent's turns or before its first write. Both loops pick the same head ticket and run the agent on the same tree (double spend, interleaved commits). The `stop`/`keys` channel reaches only the loop that wrote the pid file last.
Repro: run A with `FOREMAN_FAKE_BEHAVIOUR=land FOREMAN_FAKE_SLEEP=12`, start B 3s later in the same repo. B printed `iteration 1 · batch/issues/01-ticket.md` and ran the agent for the same ticket. When A finished and renamed the batch to DONE_batch, B died with `awk: fatal: cannot open file 'batch/issues/01-ticket.md'`, then `ENOENT ... batch\foreman-runs.jsonl` from foreman-record.cjs (exit 1, no footer).
Fix: refuse to start (exit 1, "a run is already in flight, pid N") when the pid in the ctl dir is alive. If concurrent runs are intended, key the lock on the batch rather than the ctl dir.

## 2. `stop` trusts a stale pid file: PID reuse makes `stop --now` SIGINT and `kill -9` an unrelated process tree (medium, confirmed-by-repro for the mechanism)
foreman-control.sh:94-99 (liveness is only `kill -0`), :169-180 (INT, then `stop_force` on every descendant). Same weak test at foreman-loop.sh:1143.
A run killed hard (SIGKILL, taskkill /F, power loss) leaves `pid`. Once the number is reused, `stop` believes a run is in flight. MSYS pids are recycled. Repro: pid file set to a live unrelated `bash -c 'sleep 300 & wait'`, then `foreman-control.sh stop --now batch`. Output: `foreman stop: stopped the run in batch (paused, as Ctrl-C does)`, and the unrelated bash was dead (`Interrupt`). Had it ignored INT, its children would have gone to `kill -9`/`taskkill /F /T` after the grace period. The same reuse makes a new run silently fall back to the unreachable temp ctl dir.
Fix: the pid file already holds `pid winpid`. Treat the run as live only if `/proc/$pid/winpid` equals the stored second field and `/proc/$pid/cmdline` names foreman-loop.sh; otherwise treat the file as stale and say so.

## 3. Pause beats `sync_failed`: an interrupt during sandbox collect drops the "work is stranded" warning, and the next run resets over that work (high impact, narrow window; high confidence from code, needs-verification against real `sbx`)
foreman-loop.sh:1801 (`exec_collect ... || sync_failed=1`), :1843-1846 (marker removed when `sync_failed=1`), :1860 (`PAUSE_REQUESTED` -> exit 10) before :1891 (the stranded branch with `exec_recovery_note`).
Ctrl-C, or `stop --now`, delivers SIGINT to the whole foreground group, and `sbx exec ... bundle` / `sbx cp` inside `exec_collect` (sandbox.sh:129-146) are in it. They die, `exec_collect` returns 1 ("could not bundle the sandbox's commits"), the trap has set PAUSE_REQUESTED, and the loop pauses cleanly. Result: no recovery note, no marker, exit 10. The loop's own comment at :1888 says a retry "would reset the clone over it", and the next run does `git reset --hard BASE_REF` in the clone (sandbox.sh:64). Commits the agent made, but which were never bundled out, are lost.
Fix: test `sync_failed` before the `PAUSE_REQUESTED` pause (or print the recovery note on that pause too), and keep the marker when `sync_failed=1`. Better, shield exec_collect from the interrupt (`trap '' INT` around it, or run it in its own session).

## 4. SIGTERM does nothing to the agent: `kill <loop>` waits out the whole turn (medium, confirmed-by-repro)
foreman-loop.sh:1266 (`trap on_interrupt INT TERM`, which only sets a flag), foreman-order.sh:247 (`trap 'exit 143' TERM`, deferred behind `RESPONSE=$(claude ...)` at :264).
Bash runs the trap only after the foreground pipeline returns, and nothing forwards TERM to the pipeline. Anything that ends a job with TERM (a service stop, CI cancel, a plain `kill`, a GUI that does not know about `stop --now`) leaves a live `claude` for up to the agent's full turn, and the follow-up KILL then orphans it (finding 5).
Repro: `FOREMAN_FAKE_BEHAVIOUR=hang-dirty FOREMAN_FAKE_HANG=15`, `kill -TERM <loop pid>` -> "Interrupt received - finishing this iteration's bookkeeping", loop exited 19s later (exit 10).
Fix: for TERM, have the handler `kill` the pipeline's children (remember the pipeline pid with `jobs -p`, or run exec_run via `coproc`/background + `wait`, which makes the trap fire at once), keeping INT as is. Same for order.sh: run claude in the background and `wait` on it.

## 5. A hard-killed loop leaves the agent, the stream filter and the pid file running (medium, confirmed-by-repro; consequence with real claude is needs-verification)
foreman-loop.sh:1787-1789, :1196 (EXIT trap does not run on SIGKILL); nothing records the agent's pid.
Repro: `kill -9` the loop during `hang-dirty`. Afterwards the exec_run subshell (ppid 1), `node foreman-stream.cjs` and the `sleep` stayed alive, `.foreman-run/pid` still named the dead loop, and VERDICT_FILE/PAYLOAD_FILE and the mktemp ctl dir stayed in /tmp. With a real `claude` the orphan keeps editing and committing in the working tree while the next `foreman run` starts its marker/review turn on the same tree.
Fix: write the agent pipeline's pid next to `pid`. At startup, if the previous loop is dead and that pid is alive, refuse (or kill it). `stop --now` could also work from that file instead of a /proc scan taken once.

## 6. No watchdog on the agent, `sbx exec` or `sbx cp`: a hung call blocks the run for good, and `MAX_MINUTES` is not a limit (medium, needs-verification)
foreman-loop.sh:1787 (pipeline), :1703 (time budget checked only between iterations); _sbx.sh:17 (`_sbx_sh`), :125; sandbox.sh:64, :81-95, :129-146. foreman-order.sh:264 as well.
The code documents `sbx exec` failing with `inspect exec: context deadline exceeded` (_sbx.sh:119); the same hang in a sync, collect or `sbx ls` call has no timeout, and the run and its time budget wait indefinitely until someone runs `stop --now`. An unattended run (the reason for the time budget) can sit for hours.
Fix: wrap the sbx control calls (`sync_down`, `tree_dirty`, `collect`, `_sbx_exists`, `sbx cp`) in `timeout 120`. For the agent turn, use an idle or wall-clock watchdog that sends INT/TERM to the pipeline once `MAX_MINUTES` plus slack has passed.

## 7. `trap - INT TERM` before the footer leaves a window where a stop kills the run mid-bookkeeping (low-medium, high confidence from code)
foreman-loop.sh:2094. The footer runs `refresh_budget`, the summary, log appends, `run_ctl_end` and then `mark_batch_done_on_disk` (a `git mv` followed by `git commit`, :482-487). In that window SIGINT/TERM (Ctrl-C, or a `stop --now` sent while the last turn was finishing) uses the default action: exit 130 or 143 instead of 0 or 10. The "Appended to ..." line and the final rename can be skipped, and a kill between `git mv` and `git commit` leaves a staged rename (the rollback at :485 only covers a failed commit). `stop --now` still prints "stopped ... (paused, as Ctrl-C does)".
Fix: leave the trap in place until `exit` (the flag is simply ignored by then), or `trap '' INT TERM` around `mark_batch_done_on_disk`.

## 8. `foreman order` spinner outlives a killed order (low, high confidence from code)
foreman-order.sh:208 (`while :; do ... sleep 0.2`) started with `order_spinner &` at :254. It has no parent check, so it is stopped only by `order_exit`. If `order` is SIGKILLed (taskkill /F, the terminal host dropping it), the background spinner keeps redrawing `\r\033[2K ...` on that terminal forever, and the real `claude` call stays alive.
Fix: `while kill -0 "$PARENT" 2>/dev/null; do` with `PARENT=$$` captured before the fork, as foreman-keys.sh does for its loop.
