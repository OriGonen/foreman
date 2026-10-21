# 01: Smoke suite reports progress and timing, and cleans up when interrupted

**What to build:** A developer running the smoke suite can see what it is doing and where
its time goes. Each case announces itself as it starts (its position, the total, its name)
and prints its elapsed seconds when it ends, so a slow run is distinguishable from a hung
one. The run ends with the slowest cases and a total line in the form
`N passed in Mm Ss`, ready to paste into a ticket's closing note. The same output appears
when the suite is filtered to a subset of cases, with the position and total counting only
the selected cases. Interrupting the run (Ctrl-C), terminating it, or closing its terminal
removes its fixtures, as a normal exit already does. See `spec.md` in this directory,
"Smoke suite harness".

**Blocked by:** None within this feature. Start once `human-tickets` ticket 08 is
committed, so the tree is clean.

**Status:** done

- [x] Each selected case prints a progress line when it starts and its elapsed seconds when it ends
- [x] The run ends with the slowest cases (up to 10) and the total elapsed time, alongside the pass count
- [x] Timing uses bash's own clock and adds no processes per case
- [x] Filtering by case name still works, and progress counts only the selected cases
- [x] Pass/fail counts, failure messages and the exit status mean exactly what they did before
- [x] `INT`, `TERM` and `HUP` trigger the same cleanup as `EXIT`; `FOREMAN_KEEP_FIXTURES=1` still keeps the fixtures
- [x] Verified by hand: an interrupted run leaves no fixture directory behind
- [x] The header comment of the suite describes the new output
- [x] No existing assertion is edited, and `bash test/smoke.sh` passes in full; the closing note records `Full smoke suite: N passed in Mm Ss`

## Comments

**Closing note.** Only `test/smoke.sh` changed; no case body or assertion was edited.

- A pre-scan counts the selected cases off the file's own `if case_is "…"; then` lines (87 of 87 match), so `[n/total]` counts only what the filter selects. Timing uses `EPOCHREALTIME`, `printf -v` and arithmetic: no process per case. One `sort | head` runs once at the end for the slowest-10 list.
- The old `N passed, M failed` line is unchanged; `N passed in Mm Ss` follows it. The exit status is still the last command's.
- `INT`, `TERM` and `HUP` now `exit` with 130, 143 and 129, which runs the `EXIT` cleanup. Verified by hand: each signal sent mid-run left no `foreman-smoke-*` directory under a scratch `TMPDIR`, and with `FOREMAN_KEEP_FIXTURES=1` the directory was kept.
- A signal that arrives mid-case takes effect when that case's current command returns (Ctrl-C also reaches the command). The header says so.
- The code review (standards and spec) found nothing blocking. Known limit: the case count depends on every case keeping the `if case_is "…"; then` form.

Full smoke suite: 466 passed in 29m 40s
