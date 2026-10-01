# 10: Smoke cases run in parallel

**What to build:** Run the smoke suite's cases concurrently, so the full suite finishes in
ten minutes or less under Git Bash. Per-case output is buffered and printed in case order
and whole, so the log reads the same as a serial run; each case's pass and fail counts are
written to a file under the run's work directory and summed at the end; concurrency is
capped. Pass and fail counts, the exit status, the case-name filter, `RALPH_KEEP_FIXTURES`
and the cleanup traps keep meaning what they mean today. See `spec.md` in this directory,
"Smoke suite harness", and user stories 30-32.

**Why this ticket exists:** ticket 04's last step compared the suite total with the spec's
ten minutes. After 05-09 and 04 the full suite is **484 passed in 12m 42s**, over by 2m 42s
(a 21% cut is needed). The library work and the template have landed; what is left is
`ralph` calls inside cases, which only running cases side by side will overlap.

**Blocked by:** 04.

**Status:** ready-for-agent

- [ ] First step, before any change: the shared-state audit (user stories 30-32). List every piece of state two cases could both touch, and say for each how it is made safe or why it already is. At least: fixed paths under `$WORK` (log files such as `$WORK/ctx-prompts.txt`, and the install cases' `$WORK/<name>-home`, `-config`, `-bin`), the real home directory and `~/.claude`, the install targets, `RALPH_KEEP_FIXTURES`, the fake adapter's per-PID call counter in `$TMPDIR`, the template (read-only after the build), environment variables a case exports (`RALPH_FAKE_BEHAVIOUR` and the like), and anything a case does to the working directory or the repository `ralph` itself lives in
- [ ] The audit's result is recorded here before the harness changes, with any case that cannot run alongside another named
- [ ] Output is printed in case order, each case's lines whole, with the `[position/total] name` and elapsed-seconds lines as today
- [ ] Pass and fail counts are per-case files under the run's work directory, summed at the end; the `N passed, M failed` line, the `N passed in Mm Ss` line, the slowest-cases list and the exit status mean exactly what they do today
- [ ] Concurrency is capped, and the cap can be set (for example `RALPH_SMOKE_JOBS`); a cap of 1 gives the serial run
- [ ] The case-name filter, `RALPH_KEEP_FIXTURES=1`, and the `INT`/`TERM`/`HUP` cleanup keep working; an interrupted parallel run leaves no fixture directory and no stray case process behind
- [ ] No existing assertion is edited
- [ ] The suite passes in full **several times in a row, in parallel** (spec, "Testing Decisions"), each with a fresh `TMPDIR`; the ticket records every run's total, and the closing note records `Full smoke suite: N passed in Mm Ss`
- [ ] The last run's total is compared with ten minutes and the result stated here. If it is still over, say by how much and what the slowest cases are (the 04 run's slowest are `ralph run` cases of 18-34 s, which bound what parallelism can save)

**Evidence to start from (ticket 04's "after" run, 2026-10-01):** 91 cases, 484 assertions,
12m 42s serial. The ten slowest cases are 18-34 s each; the machine's core count and how Git
Bash process creation scales across cores are not yet measured, and the cap should be chosen
from that measurement rather than guessed.
