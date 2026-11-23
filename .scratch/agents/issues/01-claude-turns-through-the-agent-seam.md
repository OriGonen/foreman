# 01: Claude's turns and setup calls go through the agent seam

**Status:** ready-for-agent

**Blocked by:** None (can start immediately)

**What to build:**

The first half of moving Claude behind the agent seam (spec: "The agent seam", "The Claude
agent"; ADR 0006). Afterwards nothing outside the agent directory builds a `claude` command
line, sets Claude's environment, or prints Claude-specific text — and nothing a user sees
or runs is different.

Create the agent directory with one shell file for Claude, implementing the agent's fixed
set of functions for everything shell-side: the program and its display name; the command
line for a turn (prompt, model, effort, permission mode, `FOREMAN_CLAUDE_ARGS`, output
format, and the checkpoint/review limit, which for Claude is `--max-turns`); the command
line for a setup call; the environment a turn needs (the raised shell timeout); the
prompt's paragraph about long checks; and the hints the loop prints (log in again,
install, the permission hint and its git allowlist suggestion).

Then make every caller ask the agent instead: each execution adapter (`local`, `sandbox`,
`sandbox-mount`, and `fake`, which must still record what a real adapter would pass), the
loop's checkpoint and review turns, the loop's Claude-specific messages, `foreman init`'s
ordering call and `foreman commands`. The agent is chosen by a single internal variable
that is always `claude` for now; the setting itself is ticket 03.

This is a pure refactor. The golden files and the smoke suite are its acceptance test.

- [ ] The agent directory exists with Claude's shell file, and its functions are documented in the file's header
- [ ] No execution adapter, nor the loop, ordering or `foreman commands`, contains a `claude` command line, Claude's environment variables or Claude-specific hint text
- [ ] The prompt's paragraph about long checks comes from the agent; the rendered prompt is byte-for-byte unchanged
- [ ] Claude's command lines and environment are byte-for-byte unchanged in every mode, as the existing stub `claude`/`sbx` smoke cases assert
- [ ] Every golden file is unchanged
- [ ] The full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
