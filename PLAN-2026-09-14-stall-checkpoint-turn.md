# Plan (not implemented) — salvage a stalled turn with a checkpoint turn

Supersedes `PLAN-2026-09-12-resume-on-dirty-stop.md`, which proposed resuming the agent's
own session instead. That option was rejected; the reasoning is in
`docs/adr/0001-checkpoint-turn-over-session-resume.md` and is not repeated here.
Vocabulary used throughout is defined in `CONTEXT.md`.

Written in response to a live run (`.scratch/emergent-crowd-motion`, `pixel-diffusion`,
2026-09-12) that hit the dirty-tree stop after one iteration ran out of turn budget
mid-ticket with nothing committed. Nothing here is implemented; this is a handoff, in the
same spirit as `IMPLEMENTATION-PLAN-2026-09-08.md`.

---

## The gap

`ralph-loop.sh` already distinguishes two endings for a turn that did not land its ticket:

1. **Progressed** (`:557-572`) — the agent committed a WIP checkpoint of its own accord
   before the turn ended. Not a failure; the same ticket gets the next iteration, capped
   by `RALPH_MAX_CONTINUATIONS`.
2. **Stalled** (`:517-535`, branch 4) — the turn ran out of room *before* it reached its
   own checkpoint step. Nothing is committed, so there is nothing safe to build on, and
   the loop stops with `EXIT_NEEDS_HUMAN`.

Case 2 is the gap. The work exists, it is often sound, and the only thing missing is the
commit the turn never got to. A **checkpoint turn** supplies exactly that and nothing
else: a short agent turn that reads the uncommitted diff, commits it as `wip:`, and writes
the `Remaining:` list — converting the stall into case 1, which already works.

The loop still never auto-commits. An agent commits; the checkpoint turn is an agent.

---

## Commit 1 — the dirty-tree stop tells the truth, and rerunning cannot destroy the work

Independent of everything below and worth shipping first: today's recovery advice is
wrong under the default adapter, and following it destroys the work the stop exists to
protect.

### The bug (confirmed, reproduced 2026-09-12 against `365609e`)

Under `RALPH_EXEC=sandbox` (the default), the stop prints `exec_show_dirty`'s
adapter-correct text (`lib/exec/sandbox.sh:111-116`):

```
 M pixel-transport.html
 M src/core.js
 M tests/verify_js_node.js

They are in the sandbox's clone, not in this repo, and rerunning would reset
the clone over them. Inspect with: sbx exec ralph-pixel-diffusion git diff
```

— and then, immediately after, the unconditional follow-up at `ralph-loop.sh:525-532`:

```
git add -A && git commit -m 'wip: ... — remaining: <what is left>'
ralph run .scratch/emergent-crowd-motion
```

Run as printed from the host shell, `git add -A` finds nothing — the host tree is clean,
the changes are in the clone — so the commit is a silent no-op, and the following
`ralph run` calls `exec_sync_down`, which hard-resets the clone and destroys the work.
Both blocks are printed by the same stop, in the same voice, one after the other, and
contradict each other.

**Root cause:** the follow-up block was written against `local` mode's model of the world,
where the dirty tree *is* the host repo and `git add -A && git commit` is exactly right.
`exec_show_dirty` is already adapter-specific; this text is not.

### The change

- New adapter function **`exec_dirty_recovery_note BASE`**, alongside the existing
  `exec_recovery_note` (which covers a different case: work committed but stranded).
  `_common.sh` keeps today's `git add -A && git commit` text for `local`, `fake` and
  `sandbox-mount`; both sbx adapters print the bundle transport that `_sbx_sync_up`
  already uses internally — commit inside the sandbox, bundle, `sbx cp`, `git fetch`,
  `git merge --ff-only`.
- `ralph-loop.sh:525-532` calls the adapter instead of hardcoding one mode's text.
- **`exec_sync_down` refuses over a dirty tree** rather than resetting it, and says why.

The two halves are one change: the stop tells the truth, *and* a user who ignores the text
still cannot lose the tree by rerunning.

---

## Commit 2 — stalls and the checkpoint turn

### The new branch

A stall is: `agent_status == 0`, `is_error != 1`, ticket unflipped, `HEAD == BASE_REF`,
tree dirty. It goes **below the permission-denied branch** (`:503`), which must keep
winning — a denied `git commit` dirties the tree as a *consequence*, and letting the stall
branch win would report the symptom and never name the cause.

### Running it

```
exec_run "$CHECKPOINT_PROMPT" "$TICKET_FILE"     # with exec_sync_down NOT called
```

**No new adapter function.** `exec_run` and `exec_sync_down` are already separate calls in
the seam, so "run the agent without syncing first" needs no per-adapter agreement — and
three of the four adapters have a no-op `exec_sync_down` anyway (`_common.sh`). Only
`sandbox.sh` actually resets anything.

The turn is kept narrow by its prompt plus a low `--max-turns`. Not by `--allowed-tools`:
see the ADR.

### The prompt

Assembled inline in `ralph-prompt.sh` (no second template — it has four variable parts).
It instructs the turn to read the diff since `BASE_REF`, commit it as
`wip: <ticket> — remaining: …`, append a `progress.txt` entry ending in a `Remaining:`
list, and **not** to continue the ticket's work. The `progress.txt` entry is load-bearing,
not decorative: it is what the next iteration reads through the existing
`RALPH_CONTINUATION` notice.

### Accounting

| | |
|---|---|
| `ITERATIONS_RUN` | **not** incremented — the user did not ask for this turn |
| `RUN_COST` | **incremented** — it is money |
| `ATTEMPTS_ON_CURRENT` | **reset**, same as a progression: a stall is not an unproductive attempt |
| `STALLS_ON_CURRENT` | new counter, **display and telemetry only** |
| `RALPH_MAX_CONTINUATIONS` | the **single** budget, fed by stalls and progressions alike |
| `ralph-runs.jsonl` | its own row, distinguished by a new `kind: "checkpoint"` field |

No `RALPH_MAX_STALLS`. Two caps would mean a ticket could burn five continuations *and*
three stalls with no single number bounding it.

The cap message at `:562-570` currently reads "*has progressed N times without landing*",
which becomes false once stalls feed the counter. Reword to "needed N extra turns without
landing", with a `(N progressed, M stalled)` breakdown. The advice at the end — it is a
size problem, split the ticket — is right either way.

### Budgets

The budget checks run *before* an iteration (`:373-386`), but a stall is discovered
*after* one. A stalled turn that pushed `RUN_COST` past `RALPH_MAX_COST_USD` still gets
its checkpoint turn: a budget limits how much work to commission, not whether to keep work
already paid for. The overshoot is one short turn bounded by `--max-turns`, and the
alternative is a stop whose printed instructions ask the user to do by hand precisely what
the skipped turn would have done. The pause message should say so, so the final figure
exceeding the budget is not a mystery.

### The next iteration's notice

`RALPH_CONTINUATION` already fires (a stall feeds the same counter), but its text —
"*a previous iteration did part of the work and committed it*" — overstates how
well-understood the handoff is. After a stall the `Remaining:` list was reconstructed from
the diff by a turn that never saw the reasoning. The stall variant should say both:

- the handoff was reconstructed from the diff, so it describes what is *there*, not what
  was planned;
- the previous turn ran out of room — the same signal `RALPH_CONTEXT_RETRY` carries at
  `ralph-prompt.sh:203`, prompting the same correct response: work smaller, commit sooner.

### Tests

`fake.sh` detects the checkpoint prompt by a sentinel phrase, so the test exercises the
real prompt-assembly path rather than a side channel. `RALPH_FAKE_BEHAVIOUR=dirty` then
drives the whole stall → checkpoint → continue path end to end. A second behaviour covers
a checkpoint turn that **fails to commit**, because that is the branch which falls through
to the stop — and an untested stop is how the commit-1 bug survived this long.

Smoke assertions: the stall is recognised; `ITERATIONS_RUN` did not increment; a
`kind: "checkpoint"` row exists in the jsonl; the shared cap counts it; and the failure
path prints the adapter-correct recovery note.

---

## Commit 3 — start-of-run salvage

What makes "*just rerun it*" a true instruction. Today it cannot be: `exec_sync_down` runs
unconditionally at the top of **every** iteration, including the first of a fresh run
(`:400`), so a rerun resets the clone before anything notices it is dirty.

The hazard that the in-run case does not have: at run start, nobody knows who left the
tree dirty. The sandbox is **per-repository, not per-batch**
(`RALPH_SANDBOX="ralph-$(basename "$REPO_ROOT")"`, `ralph-config.sh:242`), so a dirty
clone may be another batch's stall or a human's own `sbx exec` session. Committing that
blind, under whatever ticket this run happened to pick first, is exactly the unreviewed
commit the loop has always refused.

**The marker.** `.ralph-stall` in the batch directory — disposable, same class as
`.ralph-iter.bundle` (`ralph-config.sh:235`) — holding the ticket path, the base ref, and
the sandbox name. Written when a stall's checkpoint turn fails or the run ends stalled;
checked before the first `exec_sync_down` of a run; deleted the moment a checkpoint turn
succeeds or the tree comes back clean.

- Marker present and matching → checkpoint turn before the first sync-down, then proceed.
- Marker missing or mismatched → refuse to sync down, print `exec_dirty_recovery_note`.

The sandbox name in the marker is what stops one repository's marker being trusted against
another's clone. Absence of the marker is always safe: it means "refuse and print the
note", which is commit 1's behaviour.

This is the one place the toolkit's "holds no state" rule bends. It bends the same way
`.ralph-iter.bundle` already does — a disposable file in the batch directory, never a
registry, and safe to delete at any time.

---

## Open items

None blocking. The three spikes the superseded plan called load-bearing — does
`--print --resume` work, does compaction apply to it, does the sandbox filesystem persist
across `sbx` invocations — are all deferred along with session resume; nothing in commits
1-3 depends on any of them.

For the record, since the superseded plan treated the first of those as unknown: the CLI
docs confirm `claude -p "<prompt>" --resume <session_id>` is supported, that the prompt is
appended as a new user turn, that `--fork-session` exists and mints a new session id, and
that without it the JSON payload's `session_id` equals the resumed id — which would make
`ralph-record.cjs:233` log the same id for every resumed turn. Compaction under `--print`
remains undocumented either way, which is the one that mattered.

One optional hardening check: whether `--disallowed-tools` still bites under
`--permission-mode bypassPermissions`. If it does, the checkpoint turn can be constrained
by enforcement as well as by prompt. If it does not, nothing changes — that is the
assumption the design already makes.
