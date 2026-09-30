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

**Status:** ready-for-agent

- [ ] Each selected case prints a progress line when it starts and its elapsed seconds when it ends
- [ ] The run ends with the slowest cases (up to 10) and the total elapsed time, alongside the pass count
- [ ] Timing uses bash's own clock and adds no processes per case
- [ ] Filtering by case name still works, and progress counts only the selected cases
- [ ] Pass/fail counts, failure messages and the exit status mean exactly what they did before
- [ ] `INT`, `TERM` and `HUP` trigger the same cleanup as `EXIT`; `RALPH_KEEP_FIXTURES=1` still keeps the fixtures
- [ ] Verified by hand: an interrupted run leaves no fixture directory behind
- [ ] The header comment of the suite describes the new output
- [ ] No existing assertion is edited, and `bash test/smoke.sh` passes in full; the closing note records `Full smoke suite: N passed in Mm Ss`
