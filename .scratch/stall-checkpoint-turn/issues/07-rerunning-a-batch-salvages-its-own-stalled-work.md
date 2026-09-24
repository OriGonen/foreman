# 07: Rerunning a batch salvages its own stalled work

**Status:** done

**Blocked by:** 02, 03

**What to build:**

Make "just rerun it" a true instruction.

Ticket 02 stopped a rerun from destroying uncommitted work, but a refusal is not a rescue —
the operator is still stuck. When a run ends with a stall it could not salvage, the next run
should finish the job: notice the dirty tree before syncing, checkpoint it, and carry on.

The hazard the in-run case does not have is that at the start of a run, nobody knows who
left the tree dirty. The sandbox is per-**repository**, not per-batch, so several batches
share one container and clone — and the dirty tree may be another batch's stall, or a
human's own session inside the sandbox. Committing that blind, under whatever ticket this
run happened to pick first, is exactly the unreviewed commit the loop has always refused.

So gate the rescue on a marker the loop wrote itself: a disposable file in the batch
directory recording the ticket, the base ref, and the sandbox name at the moment a stall was
left unsalvaged. Check it before the first sync of a run, using ticket 02's read-only dirty
query. Delete it as soon as the tree is clean or a checkpoint succeeds.

- Marker present and matching the dirty tree the loop finds → run a checkpoint turn before
  syncing, then proceed normally.
- Marker missing, or not matching → refuse to sync and print the recovery note, which is
  ticket 02's behaviour.

The marker's absence must always degrade to the safe path, so deleting it by hand is never
harmful. This is a deliberate, bounded exception to the toolkit's rule that it holds no
state of its own — it bends the same way the existing per-batch bundle file already does: a
disposable file in the batch directory, never a registry.

**Acceptance criteria:**

- [x] A run that ends with an unsalvaged stall records a marker naming the ticket, the base
      ref and the sandbox
- [x] A rerun whose marker matches the dirty tree it finds checkpoints the work before
      syncing, then continues the batch normally
- [x] A rerun with no marker, or a marker that does not match, refuses to sync and prints
      the recovery note
- [x] A marker naming a different sandbox is never trusted
- [x] The marker is removed once the tree is clean or a checkpoint succeeds
- [x] Deleting the marker by hand is safe and only costs the automatic rescue
- [x] Nothing is committed under a ticket when the loop cannot prove the work is its own

## Comments

The marker is `<batch>/.ralph-stall-marker`, three `key=value` lines (`ticket`, `base_ref`,
`sandbox`), written by `write_stall_marker` in `lib/ralph-loop.sh` only when a checkpoint
turn leaves the tree still dirty. A run checks it once, at the top of its first iteration —
after `exec_prepare`, before the budget checks and before the first `exec_sync_down` — using
ticket 02's `exec_tree_dirty`: clean tree → marker deleted; dirty and matching (same sandbox,
`base_ref` equal to host HEAD, same ticket as the one about to run) → checkpoint turn, then
the batch carries on with the ticket already a stall continuation, reviewed from the marker's
base; dirty and not matching → the existing refusal, now with a line saying a marker was found
but not trusted.

The inline checkpoint turn from ticket 03 moved into `run_checkpoint_turn` so both call sites
share it; it reports one of `salvaged`/`stranded`/`discarded`/`failed`.

Decisions worth knowing:

- The marker is deleted *before* the rescue's checkpoint turn and rewritten if it fails, rather
  than deleted after success. In a repo that has not ignored it, `git add -A` would otherwise
  sweep it into the wip commit. `ralph doctor` now checks for the `.gitignore` pattern too.
- The clean-tree preflight is waived when the marker matches. Without that, "just rerun it"
  was not true as typed under `local`/`sandbox-mount`, where the agent's tree is the host's and
  the preflight fails first.
- No marker is written for a checkpoint turn that discards the diff, one whose commit is
  stranded, or a dirty tree without the stall's exact signature: none of those is an
  uncommitted diff the loop can vouch for.
- The salvage at run start does not consume an iteration and does not check the continuation
  cap — it cannot loop, and the operator has just asked for this run.

Residual risk, inherent to the design the ticket asks for: a marker that outlives its stall
(tree cleaned some way that does not start a run) and is then followed by someone else's dirty
work at the same HEAD for the same ticket would match. Nothing in the marker can rule that out.

The existing "syncing refuses over a dirty tree" case now deletes the marker before its rerun,
since an unsalvaged stall now leaves one; the new cases cover the marker paths (matching,
missing, mismatched sandbox/base/ticket, failed rescue, clean tree). Full smoke suite: 283
passed, 0 failed.
