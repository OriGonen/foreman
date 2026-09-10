# Implementation plan — bug report items 9, 7 and 8

Handoff document. Everything here was settled in a design session on 2026-09-08; the
decisions are made, and the alternatives that were considered and rejected are recorded so
they don't get re-litigated. Where something is genuinely unverified it says so.

Source of the issues: `BUG-REPORT-2026-09-07.md` (untracked, lives in the primary checkout
`C:\Projects\ralph`, not in this worktree). Read items 7, 8 and 9 there for the original
observations — this document does not repeat the evidence in full.

Line references are as of commit `c127f2b`. They will drift; treat them as signposts, not
addresses.

---

## Working agreement

- Branch `worktree-fix-4-bugs`, which already carries the fixes for report items 1–6 and is
  unmerged. Keep going on it; one PR at the end covering everything.
- **Three commits, one per issue, in the order below.** They are dependency-ordered, not
  arbitrary.
- Every fix gets a smoke case **verified to fail before the fix** — temporarily revert the
  change, run only the new case, confirm the failure reproduces the reported symptom, then
  restore. This is the standard items 1–6 were held to; the fail-first run for item 6
  reproduced the misreported exit 20 exactly, which is how we knew the case was real.
- The full suite must pass afterwards. It stood at **100 passed, 0 failed** when this plan
  was written (`bash test/smoke.sh`).
- Document every new knob in `README.md`. There is precedent (commit 5712409 documents
  `RALPH_ORDERING_MODEL`).
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01MicaSNfd9gbtTBnvykLWtm
  ```

---

## What these three issues share

Items 5, 6, 7 and 9 all end at the same place: `ralph-loop.sh`'s dirty-tree stop (branch 3,
`:445`), exit 20, "left uncommitted changes behind". Four distinct root causes, one
symptom, and in three of them the terminal never names the real cause. Items 5 and 6 are
already fixed. This plan covers the remaining two of that family (9 and 7) plus the
visibility feature (8) that would have let a human see any of them happening live.

The structural root of all of it: `claude --print --output-format json` is **one turn**. It
prints a single JSON object and exits. There is no second turn, ever, for any batch — no
`ralph.conf` and no ticket can opt out.

---

## Verified facts

Established by reading the code and the CLI during the design session. Trust these; they
were checked, not assumed.

1. **`--print` denies anything that would prompt.** `claude --help` on
   `--permission-prompts`: default `host`, and with `none` "anything that would prompt is
   denied automatically; the permission mode still decides everything else". Ralph invokes
   plain `claude --print` with no SDK host and no `--permission-prompt-tool`, so a tool call
   needing approval is denied outright — it does not hang, and there is nobody to ask.
2. **`acceptEdits` covers Edit/Write but not Bash.** Bash then falls through to the
   project/user settings allowlist.
3. **The pixel-diffusion evidence.** `.claude/settings.local.json` there holds ~28 *exact*
   commands accumulated from earlier interactive sessions — including `python src/build.py`
   and `node tests/verify_js_node.js`, which is precisely why verification passed while
   committing failed. **There is not one `git` entry.** It also contains `Bash(node -)`,
   `Bash(node -e ' *)` and `Bash(python -)`, i.e. arbitrary code execution is already
   allowed, so a narrow git allowlist adds no containment that isn't already gone.
4. **The report's "three iterations in a row" is wrong.** `ralph-runs.jsonl` reads
   chronologically 03 ✗, **04 ✓ (committed, landed, $2.75)**, 06 ✗, 07 ✗. And ticket 03's
   reply says "even reading an unrelated file hit the same wall" — `Read` is not Bash, so
   the static cause doesn't explain that one. Something intermittent sits on top. The
   static cause is real and worth fixing regardless; do not chase the intermittency as part
   of this work.
5. **Valid `--permission-mode` values:** `acceptEdits`, `auto`, `bypassPermissions`,
   `manual`, `dontAsk`, `plan`.
6. **`--output-format` choices:** `text`, `json`, `stream-json`. The help does *not* say
   `--verbose` is required alongside `stream-json` (an older constraint). Verify at runtime.
7. **`--autocompact` defaults to `auto`**, so a turn that overruns its context compacts
   rather than dying. That is why `context_exhausted` in the recorder only fires when
   compaction *fails*. Leave this flag alone — it is the backstop.
8. **`ralph-config.sh:270` sources `ralph-exec.sh`**, but only to get `ralph_exec_load` etc.
   The adapter itself is loaded later, by `ralph-loop.sh:149`. `ralph_exec_required_tool`
   (`ralph-exec.sh:75-77`) is the existing pattern for asking an adapter a question without
   disturbing the caller: it subshell-loads the adapter and echoes the answer.
9. **`ralph-prompt.sh` uses a `_ralph_fill` helper** for template slots (added by the item-1
   fix), and already has a conditional block at `:174` keyed on `RALPH_CONTEXT_RETRY`.
10. **`ralph-report.cjs:137-138`** counts any iteration without a flipped status as
    `unproductive`, and `:206` lists it in the problem section as `not-landed`.

---

# Part 1 — item 9: permissions (do this first)

**Why first:** Part 2 rests on the agent running `git commit` itself. In a batch configured
like the one in the report, it cannot. Fixing 7 before 9 would produce smoke cases that pass
under `fake` and fail the first time they meet a real repo.

## Root cause

`RALPH_PERMISSION_MODE` defaults to `acceptEdits` (`ralph-config.sh:250`), which auto-accepts
Edit/Write but leaves Bash to the settings allowlist. Under `--print` there is no approver,
so a non-allowlisted Bash call — `git add`, `git commit` — is denied permanently for that
iteration. The failure lands *after* the ticket's work is done and billed ($0.29–$2.75 per
occurrence in the report), and surfaces as a generic dirty-tree stop.

## Changes

1. **Per-mode permission default.** Add `exec_default_permission_mode` to the adapter
   interface documented in `ralph-exec.sh:15-25`. Sandbox adapters return
   `bypassPermissions`; `local` and `fake` return `acceptEdits`. Consult it **only when the
   user has not set `RALPH_PERMISSION_MODE`** — an explicit value in `ralph.conf` or the
   environment always wins. Use the `ralph_exec_required_tool` subshell pattern (fact 8) so
   the seam rule in `ralph-exec.sh` holds: nothing outside `lib/exec/` asks which mode is in
   force. Note the default currently lives at `ralph-config.sh:250`, which runs *before*
   `ralph-exec.sh` is sourced at `:270` — resolve the ordering.

   *Rationale:* inside a sandbox the container is the boundary, so the permission gate buys
   nothing and costs a paid iteration every time it fires. `local` keeps its gate: "no
   isolation" and "no permission check at all" are different things on a machine with real
   repos on it, and silently removing the last check is not a default to choose for someone.

2. **`ralph.conf.template:54`** — replace the commented
   `#RALPH_CLAUDE_ARGS=(--allowed-tools Bash Read Edit)` with an uncommented, git-scoped
   default: `RALPH_CLAUDE_ARGS=(--allowed-tools "Bash(git add:*)" "Bash(git commit:*)")`,
   with a comment saying why (ralph's own prompt requires the agent to commit; under
   `--print` nobody can approve it). Anyone wanting more sets `bypassPermissions` knowingly.

3. **`permission_denied` as a first-class signal** in `ralph-record.cjs`. Same shape as the
   item-6 fix: match "requires approval" / "permission denied" in the reply, gated the same
   way the other signals are (`haystack` is only populated when the run did not clearly
   succeed — see `:98-99` — so a ticket that legitimately implements permission handling
   cannot false-trigger). Add it to the record, to the human log block, and as a verdict key.

4. **A loop branch above the dirty-tree stop.** In `ralph-loop.sh`, between the limit branch
   (`:422`) and the dirty branch (`:445`): if `permission_denied` is set, stop with a message
   naming the real cause and the exact `ralph.conf` line to add, plus "rerun after that".
   Exit 20. Ordering matters — the dirty stop currently wins and hides this, exactly as it
   hid item 6.

5. **A `ralph doctor` check.** Flag a `local`-mode batch whose permission mode and
   `RALPH_CLAUDE_ARGS` cannot commit, using the existing `ok()`/`bad()`/`note()` helpers
   (`ralph-doctor.sh:57-59`). This is the piece that catches it at $0 instead of after three
   tickets.

6. **`ralph dry-run` reports the effective permission mode** alongside its existing
   Exec/Model/Budgets lines (`ralph-loop.sh:221-242`). This is also the test seam for change
   1 — see Testing.

## Tests (all through `test/smoke.sh`)

- A `permission-denied` behaviour in `fake.sh` whose payload carries "requires approval".
  Assert: exit 20, output names permissions and the `ralph.conf` fix, and does **not**
  report only "left uncommitted changes".
  *Fail-first check:* without change 4 this must stop as a plain dirty-tree stop.
- `ralph dry-run` on a local-mode batch reports `acceptEdits`; on a sandbox-mode batch
  reports `bypassPermissions`; and an explicit `RALPH_PERMISSION_MODE` in the batch's conf
  overrides both.
- `ralph doctor` flags a local batch with no git allowlist.

---

# Part 2 — item 7: tickets that need more than one turn

## Root cause

A ticket whose work exceeds one turn's output budget ends with the deliverable half-written,
`exit 0`, `subtype success`, no error anywhere — and nothing committed or flipped. The CLI
has no concept of "the ticket is done"; ralph defines that, and the turn simply ended. The
next iteration then starts cold and redoes the work from scratch.

## The design in one line

The **agent** commits its partial work as a WIP checkpoint and hands off; the loop stops
treating that as a failure. The loop never auto-commits.

## Changes

### Prompt (`lib/prompt.template.md`)

1. **A behavioural trigger.** Before starting a substantial piece of work — a large file, a
   long-running command — the agent asks whether it can both finish that *and* land the
   ticket in what remains of the turn. If not, checkpoint what it already has first.

   *Why this and not a threshold alone:* the model can partly perceive context pressure, but
   the per-turn **output budget** — the thing that actually cut the reported iteration short
   at 37,408 output tokens — is invisible to it. A threshold instruction alone leaves item
   7's own reproduction case unfixed.

2. **A context budget**, via a new `__CONTEXT_BUDGET__` slot filled from
   **`RALPH_CONTEXT_BUDGET_TOKENS`** (default `200000`) in `ralph.conf`. The agent is
   expected to complete a ticket well inside that; past it with substantial work remaining,
   it wraps up and hands off. The number lives in config, never as a literal in the shared
   template — it is model- and version-specific and would age badly there. Add the slot with
   `_ralph_fill` (fact 9).

3. **A fallback procedure, last in step 5**, framed as failure rather than option: *you have
   not finished the ticket; do not leave the work uncommitted.* Commit as
   `wip: <ticket> — <what remains>`, **leave the Status line unflipped**, and write a
   `Remaining:` list in `progress.txt`.

   *Placement and framing matter.* Step 5 already says (from the item-5 fix) that everything
   happens in this turn. Models take offered exits, and a chunk-first framing ("commit in
   coherent chunks as you go") would quietly undo that. Keep the turn's goal unchanged and
   put this last, low-salience, as the procedure for a failure the agent has already noticed.

4. **A continuation notice.** When `RALPH_CONTINUATION=1`, one sentence at the top of the
   prompt: you are continuing this ticket, the work so far is committed, read the last
   progress entry before doing anything. Mirror the existing `RALPH_CONTEXT_RETRY` block at
   `ralph-prompt.sh:174`.

### Loop (`lib/ralph-loop.sh`)

5. **"Progressed" stops being a failure.** HEAD moved + status unflipped + no error signal =
   the ticket made progress. Continue onto the same ticket instead of falling through to the
   exit-20 stop at `:485-497`.

6. **Attempt accounting changes meaning.** Reset `ATTEMPTS_ON_CURRENT` whenever an iteration
   progressed — the counter then counts *unproductive* attempts, which is what it was for. A
   ticket that moved HEAD did not fail, and burning its retry budget for making progress is
   backwards.

7. **A continuation cap.** Count *consecutive* continuations on one ticket; at
   **`RALPH_MAX_CONTINUATIONS`** (default 5) stop with exit 20 and a specific message: this
   ticket has progressed N times without landing, it is mis-sized, split it. Mirror the
   phrasing style of the context-exhaustion advice at `:486-490`. Exit 20, not 10 — five
   chunks means a decision only a human can make. Reset the counter when the ticket changes.

8. **`TICKET_BASE_REF`.** Track the HEAD from when the current ticket was *first* attempted,
   and pass **that** as the prompt's `__BASE_REF__` on continuations, so the landing
   iteration reviews the ticket's whole diff rather than only its last chunk.
   **`exec_sync_down` and `exec_collect` must keep using the per-iteration `BASE_REF`**
   (`:353`, `:362`, `:384`) — a continuation that synced down to the ticket's original base
   would reset the sandbox clone over its own committed chunk. Only the review base changes.

   Without this, chunking silently produces unreviewed code, which is worse than the bug
   being fixed.

9. **A live line** beside the existing `✓ landed` (`:459`): `⋯ progressed · <sha>`.

10. **The dirty-tree stop gets better text only.** Recognise the partial-turn signature
    (exit 0, no error, unflipped, untracked files) and print a paste-able
    `git add -A && git commit -m 'wip: …'` plus "rerun to continue". **No new behaviour, no
    auto-commit.** This is the backstop for an agent that doesn't follow change 3 — prompt
    fixes are never 100%.

### Telemetry

11. **`ralph-record.cjs` derives `progressed`** from fields it already stores
    (`committed && !status_flipped && !is_error`). No new inputs, and **no migration** —
    historical log lines re-read correctly because the underlying fields are already there.

12. **`ralph-report.cjs` gains the third outcome.** Count `progressed` separately at
    `:137-138`, and exclude it from the problem list at `:206`. Without this the report
    contradicts the feature: a ticket that legitimately chunks across three iterations would
    read as two failures plus a landing.

## Tests

- A `partial-turn` behaviour in `fake.sh`: writes a file, makes a `wip:` commit, does not
  flip the status, exits 0. Assert the run continues to a second iteration on the **same**
  ticket rather than stopping, and that the terminal shows `⋯ progressed`.
  *Fail-first:* today this must stop at exit 20 ("still not implemented after 1 attempt").
- The continuation cap: the same behaviour repeating hits `RALPH_MAX_CONTINUATIONS` and
  stops with the mis-sized-ticket message, exit 20.
- Attempt accounting: a progressed iteration does not consume `TICKET_ATTEMPTS`.
- Review base: assert via `ralph dry-run` or the prompt log (`RALPH_FAKE_PROMPT_LOG`) that a
  continuation's `__BASE_REF__` is the ticket's first base, not the previous WIP commit.
- The continuation notice appears in the prompt when continuing, and not otherwise.
- Prompt assertions for the new template text, in the style of the item-5 assertions in the
  case "the prompt carries the ticket, the order file and the progress tail".
- `ralph report` counts a chunked ticket as progressed + landed, with nothing in the problem
  list.

---

# Part 3 — item 8: live progress visibility

## What's missing

Once `exec_run` is invoked the terminal is silent until it returns — 7 minutes, 45 minutes,
however long. No way to tell whether the iteration is alive, how long it has been running,
or what it is doing, without tailing a log in a second shell.

## Changes

1. **One flag: `ralph run --live`**, or `RALPH_STREAM=1` in `ralph.conf`, environment
   winning. **Default off**, so the default path stays byte-identical to today. Both halves
   — the wall-clock counter and the activity line — sit behind it. Name it `--live`, not
   `--verbose`: this is a different rendering of the same run, not more logging. The loop's
   arg parser rejects unknown `-*` (`:79`), so it must be a real flag.

2. **One pipeline in the loop, always.** Replace `result=$(exec_run …)` (`:377`) with:

   ```sh
   exec_run "$RALPH_PROMPT" "$TICKET_FILE" | node "$RALPH_TOOL_DIR/ralph-stream.cjs" > "$PAYLOAD_FILE"
   agent_status=${PIPESTATUS[0]}    # the agent's own status, not the filter's
   result=$(cat "$PAYLOAD_FILE")    # everything downstream is untouched
   ```

   `${PIPESTATUS[0]}` is load-bearing: `set -o pipefail` is already on (`:55`), so a plain
   `$?` would conflate the filter's status with the agent's. Everything after this line —
   the recorder call, the verdict, the branch order — stays exactly as it is.

3. **Adapters interpolate one variable** for `json` vs `stream-json` (`local.sh:19`,
   `_sbx.sh:87`). One `exec_run` per adapter; do **not** grow a second code path per mode.

4. **`lib/ralph-stream.cjs`**, new:
   - Emits the final result object on **stdout**, so the recorder's contract is unchanged.
     In plain mode it is a pass-through — copy stdin to stdout, draw nothing.
   - Draws to **stderr only**. In-place `\r` line on a TTY (`03:12 · Edit lib/foo.js`), one
     plain line per event when stderr is not a TTY. Clear the line before any other write
     and on exit, so a dying run leaves no stale text.
   - **Significant events only:** file writes/edits and shell commands. Skip reads, greps and
     globs — they are the majority of the traffic and say nothing about progress. Writes and
     commands are exactly the two signals that would have caught items 5 and 7 while they
     were happening.
   - **Privacy rule:** a `tool_use` event carries the *full* input — a `Write` carries the
     entire file body. Render tool name plus the first path/command argument, truncated to
     ~80 chars. Never print the input object. No full-transcript dump, and no raw stream
     persisted to disk either.
   - Sandbox modes prepend a banner and ANSI codes to stdout; today `ralph-record.cjs:51-59`
     strips those once at the end. In stream mode that has to happen per line. Reuse the
     `stripAnsi` logic rather than writing a second copy.

5. **`ralph dry-run` reports live/stream state** alongside the permission mode from Part 1.

## Tests

- A stream-shaped behaviour in `fake.sh` emitting several tool-use events then a final
  result object.
- With `--live`: the activity line appears on stderr for writes and shell commands, and does
  **not** appear for reads.
- Privacy: a stream event carrying a large `Write` body — assert the body never appears in
  the output.
- **Equivalence:** the same run with and without `--live` produces an identical verdict and
  identical recorded usage figures. This is the assertion that protects the payload path.
- Truncation of a long path/command.

---

## Testing discipline

**One seam.** `test/smoke.sh` drives the real `ralph` CLI end-to-end against a fixture repo
with `lib/exec/fake.sh` standing in for the agent, and all 26 existing cases work that way.
Everything above fits through it. Extending `fake.sh` is not a new seam — it *is* the
existing test double.

Two decisions are not reachable through `fake` (which never invokes `claude`): the sandbox
permission default, and adapters choosing `stream-json`. That is why `ralph dry-run` grows
two lines reporting the effective permission mode and live state — it keeps the seam count at
one, and it is independently useful: `dry-run` is already where this repo answers "what would
actually happen".

Helpers to use: `case_is` (gates each case and accepts a filter argument, so
`bash test/smoke.sh "session limit"` runs one case), `make_repo N <name>` (builds **and
commits** a fixture — post-creation `ralph.conf` edits need their own commit or the
dirty-tree preflight trips), `run_ralph`, `assert_eq`, `assert_contains`, `assert_missing`,
`done_count`, and `RALPH_FAKE_PROMPT_LOG` for prompt assertions.

`RALPH_FAKE_BEHAVIOUR` is a `:`-separated list; the Nth entry drives call N and the last
repeats. Existing behaviours: land, noop, dirty, error, transient, limit, session-limit,
crash, context, context-json.

---

## Verify at implementation time

- Whether `stream-json` needs `--verbose` alongside `--print` (the help doesn't say so; an
  older CLI required it).
- The `ralph-config.sh` ordering for the permission-mode hook (fact 8).
- That `sbx run claude -- …` passes the new flags through — its own help gives
  `sbx run claude -- --continue` as an example, so it should, but confirm with `stream-json`
  specifically, since sandbox mode also injects a banner.

---

## Explicitly out of scope

- **`claude --resume <session_id>`.** `session_id` is captured (`ralph-record.cjs:207`) and
  read by nothing. Leave it that way. A resumed session inherits exactly the context that
  just ran out, so a fresh iteration with a WIP commit and a `Remaining:` list is the better
  draw — and a deliberately written handoff is a better summary than an automatic one.
- **The loop auto-committing.** Rejected: branch 3's own comment states the principle
  ("Never auto-commit: that would be committing work no one reviewed"), and an earlier
  stash-based draft of this idea was implemented and then reverted at the user's explicit
  instruction. Under this plan the *author* commits its own work; the machinery never does.
- **Squashing WIP commits.** They stay in history. Rewriting history the agent didn't fully
  author, in a tree the loop is watching, with a sandbox bundle in the middle, is a lot of
  new ways to lose work in exchange for tidiness — and `wip: profile script — remaining: run
  at N=96` is arguably better history than a squashed commit that hides the three passes.
- **A per-iteration `--max-budget-usd` cap.** Rejected: a hard cap cuts the turn dead at an
  arbitrary point with the tree dirty — it manufactures item 7 on purpose, and cuts *without*
  letting the agent checkpoint. `RALPH_MAX_COST_USD` already stops between iterations, at a
  clean tree, with a resume command. There is no output-token cap flag in the CLI anyway.
- **Pinning `--autocompact`.** Leave it at `auto`. Pinning it to the smart-zone number would
  replace the deliberate handoff with the lossy summary the handoff exists to avoid.
- **The intermittency in fact 4.** Real, unexplained, not part of this work.
- Report items 1–6, already fixed on this branch.
