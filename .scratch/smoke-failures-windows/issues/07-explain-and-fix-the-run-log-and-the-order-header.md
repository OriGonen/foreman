# 07: Explain and fix the run log and the order header

**Status:** ready-for-agent

**Blocked by:** 03, 04

**What to build:**

The last two unexplained failures should be explained and pass. Read the spec first
(`.scratch/smoke-failures-windows/spec.md`, cluster G), and the closing notes of tickets 03 (the app
line) and 04 (the locale). Either one may already explain these.

- **Case 15** (`foreman run is the text it always was, and writes the logs it always wrote, wherever the show is not wanted`):
  `foreman-runs.log is the same` fails. The log is long, so save `want` and `got` and diff them. It
  failed only in the run at `abfb292`, like the app-related cases. Check whether it still fails now
  that ticket 03 has landed.
- **Case 16** (`foreman order piped is the text it always was, down to the byte`):
  `the header is there: expected to find '▄█▄'`. Check whether it still fails now that ticket 04 has
  landed. If it does, find out what the piped output holds where the header should be.

Label each cause product bug, test-environment issue or flaky, with the evidence. Fix it here, or
split it into its own ticket under `.scratch/` if it's a product bug too big for this ticket.

Run each case alone, never while another suite runs. Do not run the full suite.

- [ ] For each of cases 15 and 16, the cause is recorded in the closing note with evidence (a `want`/`got` diff, or the output in place of the header)
- [ ] Each one is labelled product bug, test-environment issue or flaky
- [ ] Both cases pass when run alone on Git Bash, or the remaining product bug has its own ticket under `.scratch/`
- [ ] The closing note explains why Linux results are unchanged
