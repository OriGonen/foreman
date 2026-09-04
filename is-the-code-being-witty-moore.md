# Token efficiency review — ralph's agent spawns

**This is a report, not an implementation plan.** No code changes proposed as work to do; each
finding names the file and line so it can be acted on later if wanted.

## Context

Ralph spawns a model in exactly two places:

- **per iteration** — `exec_run`, in [_sbx.sh:68](lib/exec/_sbx.sh:68) (sandbox, sandbox-mount)
  and [local.sh:15](lib/exec/local.sh:15). Both are
  `claude --model … --effort … --permission-mode … --print --output-format json -p "$PROMPT"`.
  This is where essentially all the spend goes.
- **once per `ralph init`, or on demand** — [ralph-order.sh:108](lib/ralph-order.sh:108).

The architecture is already frugal in the ways that matter most, and those choices should not be
disturbed: one ticket per fresh context so nothing compounds; progress notes attached as a
bounded tail rather than whole ([ralph-prompt.sh:142](lib/ralph-prompt.sh:142)); no state file to
re-read; and full per-iteration token telemetry already recorded
([ralph-record.cjs:71](lib/ralph-record.cjs:71)) and reportable via `ralph report --by-ticket`.

What follows is waste **inside** those existing calls — the same work, for fewer tokens. Ranked
by expected saving.

---

## 1. `ralph order` reads N tickets in N round-trips

**[ralph-order.sh:101](lib/ralph-order.sh:101)** — the prompt lists ticket *paths* only, then
says "Read every ticket listed below". The agent issues one `Read` per ticket, and every one of
those turns re-sends the entire accumulated context. Cost grows roughly quadratically in ticket
count. Cache reads soften the price per token, but the turn count itself does not shrink, and
each turn is a full round-trip.

The information the model needs to order tickets is small and predictable: the title, any
`Depends on` / `Blocked by` line, and a sense of size. That fits in an excerpt.

**Cheaper for the same output:** inline a bounded excerpt per ticket — title, `**Status:**` line,
first ~30 lines or ~1.5KB whichever is smaller — and tell the agent it may `Read` a ticket in
full *only* where its excerpt was visibly truncated and the ordering turns on what was cut. One
turn instead of N.

**Two smaller ones in the same file:**
- Effort is hardcoded to `high` at [ralph-order.sh:73](lib/ralph-order.sh:73) for what is
  essentially a topological sort. The comment defends this, and on a genuinely tangled batch it
  is defensible — but it is a fixed maximum with no way to lower it, unlike the model, which
  already got its own knob (`RALPH_ORDERING_MODEL`). The asymmetry looks unintentional.
- The call fires even when the batch has ≤2 tickets, where the order is already determined.
  `${#tickets[@]}` is in hand at [ralph-order.sh:62](lib/ralph-order.sh:62); the whole model call
  is skippable there.

## 2. A retry pays full price and learns nothing

`RALPH_TICKET_ATTEMPTS` defaults to 2, so a stuck ticket already costs double by design. The
problem is that the second attempt is **blind**: `exec_sync_down` does
`git reset --hard $BASE && git clean -qfd` in the sandbox
([sandbox.sh:52](lib/exec/sandbox.sh:52)), deleting the progress notes the failed attempt wrote
unless it survived long enough to commit them. Attempt 2 then receives the byte-identical prompt
attempt 1 got, and commonly fails the same way — a full-price repeat of a known failure.

The failed attempt's own reply text is **already captured**: `record.reply` in the JSONL
([ralph-record.cjs:166](lib/ralph-record.cjs:166)). It simply never reaches the retry. A bounded
tail of it (~2KB) surfaced through the verdict file and spliced into the retry prompt as a
`<previous-attempt>` block spends a few hundred tokens to avoid repeating a whole iteration.

Related: the retry condition at [ralph-loop.sh:451](lib/ralph-loop.sh:451) fires on
`transient=1` **or** any non-zero exit. A crash that never produced JSON and would repeat
identically still buys a second full-price attempt. Requiring `parse_ok` alongside a non-zero
exit narrows that to failures where a retry plausibly differs.

## 3. Waste inside the progress excerpt that is already sent

[ralph-prompt.sh:142](lib/ralph-prompt.sh:142), `tail -c "$RALPH_PROGRESS_TAIL_BYTES"`, default
6000 bytes ≈ 1.5k tokens — re-sent on **every** iteration for the life of the batch. ~45k tokens
of repeat payload across a 30-ticket batch. The budget is right in principle; what it buys is
lossy:

- `tail -c` cuts mid-line, so the first line of every excerpt is a fragment. Paid for, unusable.
  A `sed 1d` after the tail recovers it.
- The cap is bytes, not entries. The template asks for 5–10 lines per entry
  ([prompt.template.md:53](lib/prompt.template.md:53)) but nothing enforces it, so one verbose
  agent's write-up crowds out several useful ones and keeps doing so for every remaining
  iteration. Capping at the last N entries bounds that blast radius; the byte cap does not.
- Some of what it carries is redundant with the ticket `**Status:**` lines, which the prompt
  itself names as the source of truth for what landed. What the next iteration genuinely needs
  is only the "anything the next iteration must know" part.

## 4. The prompt's layout defeats prefix caching

[ralph-prompt.sh:145](lib/ralph-prompt.sh:145) — `RALPH_PROMPT` opens with `@${TICKET_FILE}`,
which differs every iteration, so the ~1k-token invariant template body that follows can never
share a cache prefix with the previous iteration's request. Invariant-first, variable-last
(template body, then ticket reference, then progress excerpt) costs nothing to change.

Honest caveat: this only pays when consecutive iterations land inside the cache TTL, which long
tickets will not. Free, but not a large number on its own.

## 5. Prompt-template instructions that generate avoidable context

- **Step 4 is a second full pass over the diff** ([prompt.template.md:42](lib/prompt.template.md:42)).
  In-context that is merely expensive. With `RALPH_REVIEW_SKILL` pointed at a multi-agent review
  skill — `ralph.conf.template` suggests `mattpocock-skills:code-review` — it fans out
  sub-agents that *each* re-read the diff and the repo's standards. That is plausibly the single
  largest optional line item in a run, and nothing at the point of configuration says so.
- **Unbounded sibling reads**: "read the ones it names"
  ([prompt.template.md:8](lib/prompt.template.md:8)) has no depth limit, so a chain of
  cross-referencing tickets pulls in transitively. "The ones it names directly, not their
  references in turn" closes it.
- **`prompt-extra.md` is the cheapest unpulled lever.** A short repo map there — where things
  live, what not to survey — is paid once per iteration and can remove an exploration phase from
  every one of them. The README describes the file only as "anything else specific to this
  batch", which undersells what it is good for.

## 6. Fixed per-call overhead

`RALPH_CLAUDE_ARGS` exists but appears only as a commented-out example
([ralph.conf.template:54](lib/ralph.conf.template:54)). Every iteration therefore carries the
full tool schema in its system prompt, and nothing stops a ticket-implementation agent from
detouring onto the web. A documented `--disallowed-tools WebSearch WebFetch` in the conf
template trims the fixed overhead and removes a class of expensive detour — while staying opt-out
rather than silently imposed.

---

## Not a token issue, but noticed while reading

README's budget section says the cost guard is "checked *before* each iteration, so it never
overshoots". It does overshoot, by up to one whole iteration: the check at
[ralph-loop.sh:335](lib/ralph-loop.sh:335) is `RUN_COST >= MAX_COST` — "have we already reached
it" — not an estimate of what the next iteration will cost. A $25 budget with $24 spent starts an
iteration that may cost $30. The behaviour is reasonable; the sentence describing it is not.

## How to measure any of this

No new tooling needed. `ralph report <batch> --by-ticket` already prints
`average … billed tokens per iteration` ([ralph-report.cjs:170](lib/ralph-report.cjs:170)), and
`num_turns` is recorded per iteration ([ralph-record.cjs:159](lib/ralph-record.cjs:159)) — that
is the metric that should collapse for finding 1. `ralph dry-run <batch>` prints the exact
assembled prompt without spending anything, which covers findings 3 and 4 directly.
