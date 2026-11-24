# 04: Widths are counted in characters on Git Bash

**Status:** ready-for-agent

**Blocked by:** None (can start immediately)

**What to build:**

A smoke case that checks how wide a drawn line is should count characters on Git Bash, as it does on
Linux. Read the spec first (`.scratch/smoke-failures-windows/spec.md`, cluster C).

**Case 9** (`foreman-draw init writes the design's header and files, and its other pieces say what they are given`):
`the rule is 96 wide` got 288, and `no wider than the terminal` got 240 instead of 80. That's exactly
three times, one per byte of a 3-byte `▔`, so `wc -m` is counting bytes. Check the locale the suite
runs under (`locale`, and whether `C.UTF-8`, which other cases set, exists under MSYS at all) and record
what you find.

Fix the count so it measures characters on both platforms: a UTF-8 locale that exists on both, or a
count that doesn't depend on locale. Then check every other `wc -m` use, and every
character-width check that leans on the locale, such as `${#var}`. A check that passes on Git Bash for
the wrong reason counts as broken.

Run each case alone, never while another suite runs. Do not run the full suite.

- [ ] The suite's locale on Git Bash, and whether `C.UTF-8` works there, is recorded in the closing note
- [ ] Case 9 passes when run alone on Git Bash
- [ ] Every other width check that depends on locale is listed in the closing note as either fixed or shown to count characters
- [ ] The fix is labelled product bug or test-environment issue, and the closing note explains why Linux counts are unchanged
