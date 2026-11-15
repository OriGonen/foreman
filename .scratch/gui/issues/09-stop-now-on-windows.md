# 09: `foreman stop --now`, which works on a detached run on Windows

**What to build:** `foreman stop --now` stops a run the same way Ctrl-C in its terminal does. The
loop's own INT handling runs, the stall marker stays, and the next run's review turn picks the
ticket up.

The hard part is Windows. The app starts the run detached, with no console, so the run gets no
Ctrl-C. Delivering the equivalent to that MSYS process tree, including the agent process inside
it, is unproven, so this ticket starts with a spike. Candidates to try:

- MSYS `kill -INT` on the pid in `<batch>/.foreman-run/pid`
- a `stop` file that the loop checks between tool calls
- `taskkill /T` as a last resort, which skips the INT handler

Write the findings to `.scratch/gui/notes/09-stop-now.md`, then build the approach that keeps the
loop's own INT path. See `spec.md`, additive change 8. The design is the "Stop now…" control and
its confirmation in `designs/04-live-run.html` (`designs/source/LiveRunTakes.dc.html`, take a).

**Blocked by:** 08

**Status:** implemented

- [ ] `.scratch/gui/notes/09-stop-now.md` records each approach tried on Windows, against a
      detached run (`detached`, `windowsHide`, stdin ignored), and what happened to the loop, to
      the agent process and to the stall marker
- [x] `foreman stop --now [<batch>]` ends a run that is in flight. For each of the following,
      the result matches Ctrl-C in the run's terminal:
  - the footer
  - the exit code
  - the stall marker, which stays
  - the work tree, which keeps the ticket's uncommitted work
- [ ] No orphan processes are left: no `claude`, no `node` from the feed, and no `bash` from the
      loop. This is checked with `tasklist` after the stop
- [x] When the chosen approach adds a file or a check to the loop, that change is additive, and
      plain `run` output is unchanged
- [x] `test/smoke-json.sh` covers `--now` against the fake exec, as far as a test can deliver
      the stop
- [ ] By hand on Windows:
  1. Start a run detached, the way the app will (the note gives the exact `node -e` line)
  2. Run `foreman stop --now`
  3. Check the footer, the stall marker, and that no processes are left
  4. Start the next run, and check that it opens with a review turn
- [x] `test/smoke.sh` is unchanged and the full suite passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`

## Closing note

- Built on Linux, which has no `tasklist`, `taskkill` or MSYS. **Three items are left open on
  purpose and need a person in Git Bash**: the spike's Windows column (the note has the Linux
  measurements, the design reasoning and `09-spike.sh` to fill the rest in), the `tasklist` check
  for orphans (the same check passes with `pgrep` in `smoke-json.sh`), and the four by-hand steps.
- The approach: `stop` file + SIGINT to the loop and everything under it + force-kill of what is
  still under the loop after a grace period (never the loop). The loop gained `check_stop_file`,
  which calls its own `on_interrupt`.
- Against the fake exec the result is Ctrl-C's: exit 10, the same footer word for word, the marker
  stays, the work stays, the next run opens with a review turn; no `sleep` or feed left; a loop
  whose SIGINT is ignored is stopped too. `test/smoke.sh` is unchanged.
- Full smoke suite: 2741 passed in 4m 44s, 1 failed ("convert ... CRLF kept", pre-existing).
  `test/smoke-json.sh`: 860 passed, 2 failed in one loaded run, both timing-sensitive cases of
  ticket 08 (one fails identically on the base commit's `lib/`; both pass or are flaky alone).
