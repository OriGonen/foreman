# 02: foreman-draw shows the paths you'd expect on Windows

**Status:** ready-for-agent

**Blocked by:** 01

**What to build:**

The scene drawer's paths should come out on Windows Git Bash the way the user would expect, following
the product-or-test decision recorded in ticket 01's closing note. Read the spec first
(`.scratch/smoke-failures-windows/spec.md`, cluster A).

Two failures, seen directly:

- **Case 14** (`foreman-draw reads the palette from foreman-ui.sh and keeps no copy`): expected
  `no _UI_PALETTE in /c/Projects/foreman/README.md`, got `… C:/Projects/foreman/README.md`.
- **Case 5** (`foreman-draw version is the design's mark beside the build, and tilde shortens only what is under home`):
  expected `/opt/foreman`, got `C:/Program Files/Git/opt/foreman`. MSYS rewrites POSIX-looking
  arguments passed to native `node.exe`. A home of `/` gave `~/opt/foreman`.

For case 5, work out whether a real user could hit it. Does foreman ever pass a POSIX path to node as
an argument where MSYS would rewrite it? Or is only the test's made-up `/opt/foreman` affected? Label
each fix **product bug** or **test-environment issue**. Tilde shortening with a home of `/` must still
shorten nothing that isn't under home, on every platform.

Run each case alone, never while another suite runs. Do not run the full suite.

- [ ] Cases 5 and 14 each pass when run alone on Git Bash
- [ ] The closing note says, for each case, what caused it, with the evidence, and labels it product bug or test-environment issue
- [ ] The fix follows ticket 01's decision, or the closing note says why this case differs
- [ ] The closing note explains why Linux output and assertions are unchanged
