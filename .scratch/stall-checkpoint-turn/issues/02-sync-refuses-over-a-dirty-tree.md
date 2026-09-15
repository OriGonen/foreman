# 02: The agent's tree can be asked whether it is dirty, and syncing refuses over it

**Status:** ready-for-agent

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

- [ ] The exec seam answers "is the agent's tree dirty?" as a read-only question, in every
      mode, with no side effects
- [ ] Syncing refuses rather than resetting when the agent's tree is dirty
- [ ] The refusal explains what was found and prints the adapter-correct recovery note from
      ticket 01
- [ ] A run that refuses to sync exits for a human and commits nothing
- [ ] The refusal is reachable and asserted in the no-model test mode, not only in a real
      sandbox
- [ ] A clean tree syncs exactly as before, with no extra output
