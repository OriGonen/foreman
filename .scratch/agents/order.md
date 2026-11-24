# agents — implementation order

`foreman-loop.sh` reads the block at the bottom of this file, takes the first ticket
whose Status line is not flipped, and runs exactly that one.

Generated from `.scratch/agents` in filename order. **Re-order it.** Filename
order is a starting point, not a plan — put shared foundations first, put the
sweep-everything tickets last, and keep two tickets that fight over the same file
adjacent so the conflict is a sequential edit rather than a merge.

Anything the loop cannot infer belongs in prose here: a dependency that crosses
issue directories. A step only a person can do belongs in its own ticket instead —
give it `**Status:** ready-for-human`, a `**Handoff:**` file, and a followup
ticket that `Checks:` it; `foreman order` places them, and the loop stops there.

<!--
The machine-readable order. One repo-relative ticket path per line, in run order.
foreman-next.sh reads only the lines between the ORDER markers.
-->

<!-- ORDER:BEGIN -->
```
.scratch/agents/issues/01-claude-turns-through-the-agent-seam.md
.scratch/agents/issues/02-claude-output-through-the-agent-seam.md
.scratch/agents/issues/03-the-agent-setting-and-foreman-agents.md
.scratch/agents/issues/04-the-antigravity-capture-script.md
.scratch/agents/issues/05-install-antigravity-and-run-the-capture-script.md
.scratch/agents/issues/05a-followup-install-antigravity-and-run-the-capture-script.md
.scratch/agents/issues/06-write-the-smoke-test-findings-into-the-spec.md
.scratch/agents/issues/07-antigravity-in-foreman-agents-with-the-agent-cache.md
.scratch/agents/issues/08-antigravity-turns-in-local-mode.md
.scratch/agents/issues/09-antigravity-cost-estimate.md
.scratch/agents/issues/10-antigravity-in-the-sandbox-modes.md
.scratch/agents/issues/11-antigravity-setup-calls-and-skills.md
.scratch/agents/issues/12-the-fallback-agent-on-a-shared-tree.md
.scratch/agents/issues/13-the-fallback-across-clone-sandboxes.md
.scratch/agents/issues/14-doctor-checks-every-agent.md
.scratch/agents/issues/15-the-app-agent-model-and-fallback-pickers.md
.scratch/agents/issues/16-the-guide-to-adding-an-agent.md
.scratch/agents/issues/17-try-a-real-antigravity-batch-and-fallback.md
.scratch/agents/issues/17a-followup-try-a-real-antigravity-batch-and-fallback.md
```
<!-- ORDER:END -->
