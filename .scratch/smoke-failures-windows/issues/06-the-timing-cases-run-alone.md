# 06: The timing cases, run alone

**Status:** ready-for-agent

**Blocked by:** None (can start immediately)

**What to build:**

Timing failures that were only load noise should be named as noise, and the ones that are real should
be fixed. Read the spec first (`.scratch/smoke-failures-windows/spec.md`, cluster F). The full run
that found them shared the CPU with two other suites.

- **Case 22** (`SIGTERM during a turn ends the turn at once and pauses the run, footer and all`):
  `TERM ended the run in 22 s, not at once`. The baseline got 20 s, so it fails in both runs. That makes
  it the one most likely to be real.
- **Case 13** (`turn timeout: what a native Windows agent started is ended with it, not left running (Windows only)`):
  `the turn was ended at its timeout (the run took 65 s of the hang's 735)`.
- **Case 8** (`foreman-keys.sh --text draws the design's foot when the loop left one: …`): the live
  ticker shows `01:20` where the test wants `01:1x`.

Rerun each one alone, three times, with nothing else running. A case that passes every time is
**flaky under load**: record its timings, and harden the test only if it can be done without loosening
what it asserts. A case that fails alone is a real bug. Find where the time goes (for case 22, what is
still running after TERM, and what the run waits on before it pauses) and fix it, or split it into
its own ticket under `.scratch/` if the fix is too big for this one.

Run each case alone, never while another suite runs. Do not run the full suite.

- [ ] Each of cases 8, 13 and 22 has three timings from runs alone, recorded in the closing note
- [ ] Each one is classified as product bug, test-environment issue or flaky under load, with the evidence
- [ ] Each real bug is fixed and its case passes alone three times in a row, or it has its own ticket under `.scratch/`
- [ ] No assertion's tolerance is widened without the closing note saying why the old tolerance was wrong
