---
status: accepted
---

# The stall marker is written before every turn, and a start-of-run rescue reviews before it commits

A run that stopped part-way through a turn — a usage limit, Ctrl-C, a closed terminal —
used to leave its work uncommitted in the agent's tree with nothing to vouch for it, so the
next run refused to sync over it and stopped for a human. The stall marker could only vouch
for a stall the checkpoint turn had failed to salvage, because that was the only place it was
written. The commonest stop of all, a usage limit hit mid-ticket, always ended in a refusal.

Two changes close that gap:

- **The marker is written before every agent turn** (and every checkpoint turn), and removed
  once the turn's result has been dealt with. A run that dies or pauses mid-turn therefore
  leaves it behind with no extra bookkeeping in the stop paths — including the ones the loop
  never gets to run, like a killed terminal. The match rules are unchanged: same sandbox, same
  HEAD, same ticket. A pause on a limit or Ctrl-C rewrites it against HEAD as it is then, since
  the turn may have committed part of its work before it stopped.
- **The rescue at the start of a run is a review turn, not the stall's blind checkpoint turn.**
  The mid-run checkpoint turn is told not to judge what it commits: it runs moments after the
  turn that wrote the diff, in the same run. Work found at the start of a run has had nobody
  look at it, and may have been cut off mid-file. The review turn reads the diff against the
  ticket and commits it as `wip:` — listing truncated files, stubs and TODOs in `Remaining:` —
  unless it finds a clear red flag: changes outside the ticket, secrets, mass deletion or
  garbage. On a red flag it commits nothing and ends its reply with a sentinel line; the run
  stops for a human with the reasons, the tree untouched and the marker removed, so a rerun
  does not pay for the same refusal again.

`ralph run --adopt-dirty` sends a dirty tree no marker vouches for through the same review
turn, on the operator's word that it is the next ticket's work.

## Considered options

**Running the batch's check command in the review turn** was rejected. Interrupted work is
expected to fail it, so the result says little and costs money; the next iteration runs the
checks anyway, against work it can then finish.

**Discarding work the reviewer rejects** was rejected. Nothing the loop does destroys work;
a refusal stops for a human exactly as the old refusal to sync did, only with a reason.

**A file as the rejection signal** was rejected for a line in the reply: on the clone sandbox
a file the reviewer writes stays in the clone, and bringing it back would need new transport.

## Consequences

- The loop still never commits on its own. The review turn is an agent, and it can say no.
- The marker is only written where `.gitignore` ignores it. With it present during every
  turn, an unignored marker would be swept into the ticket's commit by `git add -A` in the
  modes where the agent works in this tree. Without the ignore line a run behaves as before.
- The review turn, like the start-of-run rescue before it, runs before the budget checks and
  spends no iteration: what it keeps was paid for by the earlier run. It is recorded as its
  own `kind=checkpoint` row.
- A review turn that itself hits the usage limit pauses the run (exit 10) and rewrites the
  marker, so the next run tries the review again.
