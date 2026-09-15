# 03: A stalled turn is salvaged by a checkpoint turn and the ticket continues

**Status:** ready-for-agent

**Blocked by:** 01

**What to build:**

This is the tracer bullet: the whole path, end to end, from a stall to the next iteration
picking the ticket up.

A turn **stalls** when it ends cleanly — exit zero, no error reported — with the ticket
unflipped, HEAD where it started, and its work sitting uncommitted in the tree. It ran out
of room before reaching the checkpoint step the prompt asks it to perform itself. Today
that stops the run and the work is stranded.

Instead, recognise the stall as its own outcome and respond with a **checkpoint turn**: a
short, single-purpose agent turn that reads the uncommitted diff, commits it as a `wip:`
commit naming what remains, appends a progress entry ending in a `Remaining:` list, and
does **not** continue the ticket's work. That converts the stall into a progression — an
ending the loop already handles by continuing the same ticket on the next iteration.

Two constraints that are not incidental. The checkpoint turn runs the agent **without
syncing first**, which the exec seam already allows because putting the tree at a base and
running the agent are separate calls — so this needs **no new adapter function**. And it is
kept narrow by its prompt plus a low turn limit, **not** by a tool allowlist: both sandbox
modes default to a permission mode that bypasses the gate, where an allowlist plausibly
does not bite at all, and a restriction that silently does nothing is worse than none. See
`docs/adr/0001-checkpoint-turn-over-session-resume.md`.

The stall branch must sit **below** the permission-denial branch. A denied commit leaves
the tree dirty as a consequence, and a stall branch above it would report the symptom and
never name the cause.

Include the failure path: a checkpoint turn that cannot commit leaves the run exactly where
it would have been without it — stopped for a human, printing ticket 01's adapter-correct
note. The no-model test mode needs a behaviour for that case; an untested stop is how the
wrong recovery text survived as long as it did.

The loop still never auto-commits. An agent commits; the checkpoint turn is an agent.

**Acceptance criteria:**

- [ ] A clean-but-uncommitted ending with HEAD unmoved and the ticket unflipped is
      recognised as a stall and named as such in the terminal
- [ ] The stall branch is decided below the permission-denial branch, and a denied commit
      is still reported as a permission problem
- [ ] A checkpoint turn commits the stalled work as a `wip:` commit and writes a progress
      entry ending in a `Remaining:` list
- [ ] The checkpoint turn leaves the ticket's status line unflipped
- [ ] The checkpoint turn does not continue the ticket's work, and is bounded by a turn
      limit
- [ ] No function is added to the adapter interface for this, and the checkpoint turn is
      not preceded by a sync
- [ ] After a successful checkpoint turn the same ticket continues on the next iteration
      and can land
- [ ] A checkpoint turn that fails to commit stops the run for a human and prints the
      adapter-correct recovery note
- [ ] The no-model test mode drives the whole stall → checkpoint → continue path, and the
      failure path, without a model or a container
- [ ] The test recognises a checkpoint turn from the prompt it is given, so the real prompt
      assembly is exercised rather than a side channel
