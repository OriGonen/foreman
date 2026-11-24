# 05: Tests that take a tool off PATH work on Git Bash

**Status:** ready-for-agent

**Blocked by:** None (can start immediately)

**What to build:**

The cases that check how foreman behaves without a tool should test exactly that tool being missing on
Git Bash, not foreman failing to start at all. Read the spec first
(`.scratch/smoke-failures-windows/spec.md`, cluster D).

- **Case 4** (`foreman doctor forced to show draws the same box in colour, and lists the checks when it cannot draw`):
  `no node: exit 1` got `127`.
- **Case 10** (`foreman order's result facts say when the call failed, when the login expired, and when there is no agent`):
  `no agent is not a failure` got `127`.

Exit code 127 means a command wasn't found. Print the PATH each test builds and find which command
returns 127. The hypothesis is that the PATH drops something foreman itself needs on Windows (`bash`,
`env`, coreutils, or wherever Git Bash keeps them) while it removes `node` or the agent. Another
possibility: a lookup that only exists on Windows finds the tool anyway.

If foreman itself would hit this on a real Windows machine, for example because it calls a tool by a
name that only resolves through a PATH entry it shouldn't rely on, that's a **product bug**. Fix it,
or split it into its own ticket under `.scratch/`. Otherwise fix how the test builds its PATH, so
that it still removes only the tool under test, on both platforms.

Run each case alone, never while another suite runs. Do not run the full suite.

- [ ] For each of cases 4 and 10, the command that returned 127 and the PATH in use are recorded in the closing note
- [ ] Both cases pass when run alone on Git Bash
- [ ] Each test still removes the tool it is about, and only that tool, on both platforms
- [ ] Each fix is labelled product bug or test-environment issue, and the closing note explains why Linux behaviour is unchanged
