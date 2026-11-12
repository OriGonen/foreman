# 16: Record the model on each iteration, and give `status --json` per-ticket run stats

**What to build:** The ticket page of a finished ticket shows what its runs cost and took:
model, runtime, cost, iterations, turns and tokens (ticket 03, design `designs/02-ticket.html`,
take b3). This was asked for at sign-off (ticket 01, handoff for screen 02). Everything but the
model is already in `foreman-runs.jsonl`. The model is not: it is printed in the run's header
but never written to the record. This ticket closes that gap, and nothing else.

1. **The record gets a `model` field.** `lib/foreman-record.cjs` writes `model` on each line it
   appends to `foreman-runs.jsonl`, taken from the model the loop passed to `claude`
   (`FOREMAN_MODEL`). The loop passes it on the existing command line of
   `foreman-record.cjs`, as a new `--model` argument, and the record falls back to `""` when the
   argument is missing (old callers, old lines).
2. **`status --json` gets `stats` on each ticket that has run.** It is built from the jsonl by
   the same code that works out `spend`, not by the app. Each ticket that has at least one
   iteration carries:
   - `iterations`: the count
   - `cost_usd`, `duration_ms`, `turns` (`num_turns`): the sums
   - `tokens`: `{ input, output, cache_read, cache_creation }`, the sums
   - `models`: the distinct models seen, in order, ignoring empty ones (a ticket can span a
     model change; the app shows them joined with " → ")
   - `runs`: one entry per iteration, in order: `run` (the run id), `kind`, `outcome` (the same
     word `foreman report` uses), `cost_usd`, `duration_ms`, `started_at`, `finished_at`

   A ticket that has never run has no `stats` key.

The log and the JSON are additive. A reader that doesn't know `model` or `stats` is not
affected, and no command's plain output changes by a byte (`foreman report` included: it must
ignore the new field).

See `spec.md`, additive change 1 and "How data comes from the CLI".

**Blocked by:** 02, 05

**Status:** ready-for-agent

- [ ] Each new line in `foreman-runs.jsonl` has `model`, equal to the model the run was started
      with, including a run whose model comes from `foreman.conf` or the environment
- [ ] When `foreman-record.cjs` is called without `--model`, `model` is `""`, and nothing else
      about the line changes
- [ ] `status --json` gives each ticket that has run a `stats` object as above, and no `stats` to
      a ticket that has not. A test builds a fixture jsonl with a ticket that took three
      iterations (progressed, stalled with a checkpoint, landed) and a model change, and checks
      every field, including the sums
- [ ] A line with no `model` (written before this ticket) counts toward the sums and adds nothing
      to `models`
- [ ] `outcome` in `stats.runs` equals the word `foreman report --json --run <id>` gives for the
      same iteration, checked on the same fixture
- [ ] Plain `foreman status`, `foreman report`, `foreman run` output and `foreman help` print
      byte for byte what they printed before, compared against captures taken before the change
- [ ] The control files and the jsonl of a run on the fake exec differ from before only by the
      `model` field
- [ ] `test/smoke-json.sh` covers all of the above
- [ ] `test/bench.sh` shows no added process on any plain path
- [ ] `test/smoke.sh` is unchanged and the full suite passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`
