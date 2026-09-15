# 07: Rerunning a batch salvages its own stalled work

**Status:** ready-for-agent

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

- [ ] A run that ends with an unsalvaged stall records a marker naming the ticket, the base
      ref and the sandbox
- [ ] A rerun whose marker matches the dirty tree it finds checkpoints the work before
      syncing, then continues the batch normally
- [ ] A rerun with no marker, or a marker that does not match, refuses to sync and prints
      the recovery note
- [ ] A marker naming a different sandbox is never trusted
- [ ] The marker is removed once the tree is clean or a checkpoint succeeds
- [ ] Deleting the marker by hand is safe and only costs the automatic rescue
- [ ] Nothing is committed under a ticket when the loop cannot prove the work is its own
