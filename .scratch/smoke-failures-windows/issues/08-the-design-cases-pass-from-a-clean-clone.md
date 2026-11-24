# 08: The design cases pass from a clean clone

**Status:** ready-for-agent

**Blocked by:** None (can start immediately)

**What to build:**

The design cases (the `foreman-draw` cases that compare colours and cells against the designs under
`.scratch/DONE_terminal-design/designs/`) should pass from a clean clone. They should never depend on
something only this checkout has. Read the spec first (`.scratch/smoke-failures-windows/spec.md`,
"Baseline differences worth noting").

The spec says those designs are untracked, so a clean clone would fail. While slicing, though, all 40
files in that directory turned out to be committed. So the baseline worktree's design-case failures
(`dryrun`, `next`, `next-count`, `order-head`, `status`, `version`, plus
`foreman doctor warns when the installed skill copy is stale`) have some other cause.

Clone the repo into a fresh temporary directory at another path. Run the design cases and the
stale-skill doctor case there, alone. If they pass, record that and the spec's question is answered:
nothing to decide. If they fail, find the cause (the clone's path, an ignored file, a stale installed
skill copy, the app's `node_modules`) and fix it so they pass from the clone. Or, if what they need
can't be committed, make them skip and say why. Remove the temporary clone afterwards.

Run each case alone, never while another suite runs. Do not run the full suite.

- [ ] Whether every file the design cases read is committed is recorded in the closing note, with the check used
- [ ] The design cases and the stale-skill doctor case were run from a fresh clone at another path, and the result is recorded
- [ ] Any that failed there has its cause recorded and now passes from a fresh clone, or skips with a stated reason
- [ ] The temporary clone is removed
