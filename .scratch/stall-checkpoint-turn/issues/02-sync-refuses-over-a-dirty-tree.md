# 02: The agent's tree can be asked whether it is dirty, and syncing refuses over it

**Status:** done

**Blocked by:** 01

**What to build:**

Rerunning a batch must never destroy uncommitted work.

Today the first thing any iteration does is put the agent's tree at the host's HEAD, and on
the clone-based sandbox mode that is a hard reset plus a wipe of untracked files. It runs
before anything has looked at whether the tree is dirty. So the most natural operator
response to any stop — rerun it — is also the most destructive action available.

Give the exec seam a read-only question: is the agent's tree dirty? Every mode can answer
it, including the no-model test mode, and answering must have no side effects — in
particular it must not move commits the way collecting an iteration's work does. Then have
the loop ask before syncing: if the tree is dirty, refuse to sync, say why, and print
ticket 01's recovery note instead of resetting over it.

This query is deliberately introduced here rather than in ticket 07, which needs the same
question at the start of a run. Make the change easy, then make the easy change.

**Acceptance criteria:**

- [x] The exec seam answers "is the agent's tree dirty?" as a read-only question, in every
      mode, with no side effects
- [x] Syncing refuses rather than resetting when the agent's tree is dirty
- [x] The refusal explains what was found and prints the adapter-correct recovery note from
      ticket 01
- [x] A run that refuses to sync exits for a human and commits nothing
- [x] The refusal is reachable and asserted in the no-model test mode, not only in a real
      sandbox
- [x] A clean tree syncs exactly as before, with no extra output

## Comments

Implemented via a new `exec_tree_dirty` seam function: `_common.sh` (shared by `local`,
`sandbox-mount`, `fake`) answers with a plain `git status --porcelain` on the host repo;
`sandbox.sh` answers by querying the clone inside the sandbox, with no bundling and no
`EXEC_AGENT_HEAD` — read-only, unlike `exec_collect`. `ralph-loop.sh` asks it at the top of
every iteration, before `exec_sync_down`; a dirty answer prints `exec_show_dirty` and ticket
01's `exec_dirty_recovery_note`, then stops for a human without syncing or running the agent.

A background `/code-review` pass flagged that this refusal is unconditional — it does not
check `RALPH_ALLOW_DIRTY`, so that flag (which already skips the separate, older
clean-tree *preflight*) no longer gets a dirty `local`/`fake`/`sandbox-mount` tree past this
new check. Traced through deliberately: making the refusal respect `RALPH_ALLOW_DIRTY`
would also suppress it under `RALPH_EXEC=sandbox` whenever that flag is set (e.g. left on in
`ralph.conf` for unrelated reasons), silently reopening the destructive-reset hole this
ticket exists to close. Kept the refusal unconditional and tightened the `RALPH_ALLOW_DIRTY`
usage comment in `ralph-loop.sh` instead, so it no longer implies it reaches this check.

The second finding — one extra `sbx exec` round trip per iteration under `RALPH_EXEC=sandbox`
to ask the question — is the direct cost of asking before every sync, which is what the
ticket asks for; not changed.

Full smoke suite: 177 passed, 0 failed.
