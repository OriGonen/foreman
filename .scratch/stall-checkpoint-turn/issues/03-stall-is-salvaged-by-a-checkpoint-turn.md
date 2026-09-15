# 03: A stalled turn is salvaged by a checkpoint turn and the ticket continues

**Status:** done

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

- [x] A clean-but-uncommitted ending with HEAD unmoved and the ticket unflipped is
      recognised as a stall and named as such in the terminal
- [x] The stall branch is decided below the permission-denial branch, and a denied commit
      is still reported as a permission problem
- [x] A checkpoint turn commits the stalled work as a `wip:` commit and writes a progress
      entry ending in a `Remaining:` list
- [x] The checkpoint turn leaves the ticket's status line unflipped
- [x] The checkpoint turn does not continue the ticket's work, and is bounded by a turn
      limit
- [x] No function is added to the adapter interface for this, and the checkpoint turn is
      not preceded by a sync
- [x] After a successful checkpoint turn the same ticket continues on the next iteration
      and can land
- [x] A checkpoint turn that fails to commit stops the run for a human and prints the
      adapter-correct recovery note
- [x] The no-model test mode drives the whole stall → checkpoint → continue path, and the
      failure path, without a model or a container
- [x] The test recognises a checkpoint turn from the prompt it is given, so the real prompt
      assembly is exercised rather than a side channel

## Comments

Implemented in `lib/ralph-loop.sh` (branch 4 of the per-iteration decision tree),
`lib/ralph-prompt.sh` (`ralph_checkpoint_prompt`, a function rather than top-level code —
called only when a turn actually stalled), and `lib/exec/fake.sh` (checkpoint prompts
recognised by the `CHECKPOINT TURN` sentinel phrase, with their own
`RALPH_FAKE_CHECKPOINT_BEHAVIOUR` independent of `RALPH_FAKE_BEHAVIOUR`'s turn-by-turn list).

The stall signature is tightened beyond the old dirty-tree stop's check: it now also
requires `HEAD_REF = BASE_REF`, matching `CONTEXT.md`'s definition exactly (a turn that
partially committed and left the rest dirty is a different, ambiguous case, and still just
stops).

The checkpoint turn is run via the same `exec_run` / `ralph-stream.cjs` pipeline as the main
turn, with `RALPH_CLAUDE_ARGS` extended with `--max-turns 6` for just that one call and
restored immediately after — no new adapter function, and the array push/pop uses the same
guarded `${RALPH_CLAUDE_ARGS+"${RALPH_CLAUDE_ARGS[@]}"}` expansion the other two call sites
use (a background `/code-review` pass caught an unguarded expansion here, which would raise
"unbound variable" under `set -u` on bash < 4.4 whenever `RALPH_CLAUDE_ARGS` is left at its
empty default). Success/failure is read from git state after `exec_collect`, not from the
checkpoint turn's own exit code — robust regardless of why a real turn's `claude` process
did or didn't succeed.

The same review pass also found two more real issues, both fixed:

- The continuation cap's message ("has progressed N times without landing") becomes false
  once stalls feed the same counter — a ticket can now hit the cap by stalling alone. Reworded
  to "has needed N extra turns without landing", which is true either way; the fuller
  breakdown of how many were which is ticket 04's stall counter, not added here.
- A checkpoint turn that cleans the tree without ever committing (e.g. `git checkout -- .`
  instead of `git commit`) used to fall into the same "left uncommitted changes behind"
  branch as one that genuinely failed to commit — but a tree that WAS dirty going in and
  comes back clean with HEAD unmoved can only mean something discarded the diff, not that
  nothing happened. Given its own branch and message ("...is gone... nothing to recover"),
  covered by `RALPH_FAKE_CHECKPOINT_BEHAVIOUR=discard` and its own smoke case.

`continuation_cap_reached()` is factored out of the pre-existing progression branch so the
salvaged-stall path could share it verbatim rather than duplicate the cap message.

Two pre-existing smoke cases changed behaviour under this ticket, since `dirty` is exactly
the loop's stall signature: "a dirty tree stops the run and is never auto-committed" and
"syncing refuses over a dirty tree rather than resetting it" now both force
`RALPH_FAKE_CHECKPOINT_BEHAVIOUR=fail` to keep exercising an unsalvageable stall rather than
the (now default) salvaged one; the salvaged path gets its own new case. Full smoke suite:
193 passed, 0 failed.
