# 04: Stalls are counted, capped and recorded

**Status:** done

**Blocked by:** 03

**What to build:**

A stall now costs a turn that the operator did not ask for, so the accounting has to stay
honest in both directions: the extra turn must not silently spend the budget the operator
set, and its cost must not silently vanish from the total.

A stall does not advance the user-facing iteration counter — that number means "iterations
of work I commissioned". It does not spend one of the ticket's attempts either, on the same
reasoning that already applies to a ticket that hands off deliberately: the attempt counter
counts unproductive tries, and a stall is not one. The checkpoint turn's cost **is** added
to the run total, because it is money.

The checkpoint turn gets its own row in the structured run log, marked as a checkpoint, so
per-iteration cost and duration figures are not distorted by a second turn folded into
them. The report gains the corresponding bucket, and a stall is not counted as a failure.

A per-ticket stall counter exists for display and telemetry only. The **budget** stays the
single existing continuation cap, fed by stalls and deliberate handoffs alike — no new
configuration setting. Two caps would let one ticket burn both with no single number
bounding it.

That shared cap's message currently says a ticket "has progressed N times without landing",
which becomes false the moment stalls feed the counter — a ticket may have stalled three
times and progressed never. Reword it to say the ticket needed some number of extra turns
without landing, with a breakdown of how many were which. The advice it ends on — this is a
size problem, split the ticket — is right either way.

**Acceptance criteria:**

- [x] A stall does not advance the user-facing iteration counter
- [x] A stall does not spend one of the ticket's attempts
- [x] The checkpoint turn's cost is included in the run's total
- [x] The checkpoint turn is recorded as its own row, distinguishable from an iteration
- [x] The report accounts for stalls as their own outcome and does not flag them as failures
- [x] Stalls and deliberate handoffs feed the same existing cap; no new configuration
      setting is introduced
- [x] The cap message is true whether the ticket stalled, progressed, or both, and breaks
      down how many were which
- [x] Reaching the cap still stops the run for a human and still advises splitting the
      ticket

## Comments

Implemented across `lib/foreman-record.cjs`, `lib/foreman-report.cjs` and `lib/foreman-loop.sh`;
the fake adapter's `dirty` behaviour also changed (below).

**`foreman-record.cjs`** gains `--kind iteration|checkpoint` (default `iteration`) and two new
recorded fields: `kind` and `stalled` (the same clean-but-uncommitted, HEAD-unmoved shape the
bash loop already checks before running a checkpoint turn — computed independently in each
place because the recorder writes the main turn's row *before* the loop knows whether a
checkpoint will salvage it).

**`foreman-report.cjs`** gains `isStalled` (mirrors the existing `isProgressed`) and
`isCheckpoint` (`r.kind === 'checkpoint'`). `add()` now branches on `isCheckpoint` first: a
checkpoint row bumps a new `checkpoints` bucket and contributes its cost/tokens/duration to
the totals, but is never counted toward `iterations` and never classified as
landed/progressed/stalled/failed — those are outcomes of an iteration the operator
commissioned, and a checkpoint turn is not one. `describe()` prints `stalled N` and
`checkpoint turns N` alongside the existing figures. `--failures` now excludes both stalled
and checkpoint rows, matching the terminal's own "not a failure" framing.

**`foreman-loop.sh`**: the checkpoint turn's output now flows through `$PAYLOAD_FILE` (was
`/dev/null`) and is recorded with `--kind checkpoint` right after `exec_collect`, before the
three-way success/discard/fail branch — so it is recorded regardless of outcome, same as the
main turn. Its cost and token counts are added to `RUN_COST`/`RUN_INPUT`/etc. immediately
after, also regardless of outcome: the money was spent either way. A new
`STALLS_ON_CURRENT` counter (display/telemetry only, per `CONTEXT.md`'s "Stall count") is
incremented alongside `CONTINUATIONS_ON_CURRENT` on a successful salvage and reset whenever
the ticket changes. `continuation_cap_reached()`'s message now reads "...has needed N extra
turns without landing (P progressed, S stalled)." — `P` is derived as
`CONTINUATIONS_ON_CURRENT - STALLS_ON_CURRENT` rather than tracked separately, since the two
counters already determine it.

`ITERATIONS_RUN` and `ATTEMPTS_ON_CURRENT` were already correct for a stall going into this
ticket (ticket 03 reset `ATTEMPTS_ON_CURRENT` to 0 on a successful salvage, and the
checkpoint turn was never counted as an iteration to begin with) — verified with new smoke
cases rather than re-derived.

**`lib/exec/fake.sh`**: the `dirty` behaviour used to overwrite `.foreman-fake-leftover` with
identical literal content every call. That is invisible to git once a checkpoint turn has
committed it once — a second `dirty` call produced no diff at all, so a ticket could never
be driven through two real stalls in one test. Changed to append call-numbered content
(same reasoning `partial-turn` already uses), needed for the new cap-breakdown case below.

Five new smoke cases: the existing continuation-cap case gained the `(3 progressed, 0
stalled)` assertion; a new stalls-only case drives the same cap down via repeated stalls and
asserts `(0 progressed, 2 stalled)`; a new case mirrors "a progressed iteration does not
consume a ticket's attempts" for the stall path; and a new case asserts the checkpoint row's
`kind`, that `iterations run:` excludes it, that its cost is in the footer total, and that
`foreman report` buckets it as `checkpoint turns 1` / `stalled 1` without it showing up under
`--failures`. Full smoke suite: 212 passed, 0 failed (was 193 before this ticket).

A `/code-review` pass found two real issues, both fixed: `foreman-report.cjs`'s header line
("N iteration(s) recorded") counted checkpoint rows as iterations, contradicting the
distinction the rest of the report now draws — it now reads "N iteration(s), M checkpoint
turn(s) recorded" once any exist. And the five-line block that pulls cost/token fields out
of a verdict file into the `RUN_*` totals was duplicated verbatim for the checkpoint turn;
factored into a shared `accumulate_usage()` helper used by both call sites.
