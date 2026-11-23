# 13: The fallback across clone sandboxes

**Status:** ready-for-agent

**Blocked by:** 10, 12

**What to build:**

The fallback agent works in `sandbox` mode, where each agent has its own sandbox and its
own clone, by carrying the first agent's uncommitted work into the fallback's clone (spec:
"The fallback agent"; user stories 51–52).

- Commits come out of the first agent's clone by bundle, as they do after every turn today.
- The uncommitted remainder — modified, deleted and untracked files, binary-safe — is carried through the host as a patch, never as a commit. The fallback's clone is first synced to the base ref the stall marker records, then the patch is applied, then the fallback's review turn runs.
- A run that starts with a stall marker naming another agent's sandbox than the agent about to run carries the work over the same way before its review turn.
- If the patch does not apply, nothing is lost: the work stays in its sandbox, the marker stays, and the run stops for a human, naming the sandbox that holds the work.
- Remove ticket 12's "not ready in `sandbox` mode" reason.

- [ ] Smoke cases with the stub `sbx` on two real clones: a usage limit in Claude's sandbox with modified, deleted, untracked and binary files left uncommitted; Antigravity's review turn sees exactly that tree
- [ ] A smoke case: a run whose marker names Antigravity's sandbox, started with Claude, carries the work into Claude's clone first
- [ ] A smoke case: a patch that does not apply stops the run for a human and leaves the work and the marker in place
- [ ] Nothing is committed by the carry-over itself
- [ ] The full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
