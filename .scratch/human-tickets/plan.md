# Plan — human tickets, check tickets and handoff files

## The gap

foreman knows two kinds of ticket: done, and not done. A ticket whose status line reads
`**Status:** ready-for-human` is "not done", so the loop hands it to an agent like any other.
The agent then either fails it (exit 20 after `FOREMAN_TICKET_ATTEMPTS` wasted turns — the
right place to stop, reached the expensive way) or, worse, fakes the human's part and flips
it. `foreman order` weighs dependencies, but has no idea that one kind of ticket stops the
loop dead, so it has no reason to push that ticket late. And nothing checks what the human
did before agent work builds on it.

## What this adds

1. **Human tickets** — marked on their own status line, `**Status:** ready-for-human`
   (`FOREMAN_HUMAN_WORD`, derived `FOREMAN_HUMAN_PATTERN`; an empty word disables the feature).
2. **The gate.** Whenever the NEXT ticket in the order is a human ticket, the loop stops
   before spending anything — before the sandbox starts, before any budget check, before any
   sync — and exits **30**, naming the ticket and the handoff file to fill in. Rerunning
   without finishing it stops the same way, every time, for free. Tickets after it never run,
   even ones that do not depend on it: the order is trusted.
3. **Resume is unchanged.** The human does the work, fills in the handoff file, commits, sets
   the status line to `done`, commits, and reruns. The status lines stay the only resume state.
4. **Handoff files and check tickets** — written at planning time, read by foreman for free:
   every human ticket names a handoff file the human fills in, and is immediately followed by
   an ordinary agent ticket that `Checks:` it and sends it back if the handoff falls short.
5. **The rename is the loop's.** Finished tickets are renamed `DONE_` by the loop at no token
   cost — a human ticket only once its check ticket has passed.
6. **Visibility.** `foreman status` and `foreman dry-run` mark every human ticket, say where the
   next stop is, and warn about a human ticket that is missing its handoff file or check
   ticket.
7. **Ordering.** `foreman order` places each human ticket as late as its dependents allow, with
   its check ticket immediately after it.
8. **A planning skill** that writes human tickets, handoff templates and check tickets.

## Decisions (settled with the owner — do not revisit)

- **`Blocked by:` is not parsed by the loop.** The order is the single source of truth for
  sequencing; `foreman order`'s agent already reads each ticket in full, `Blocked by:` lines
  included.
- **Only the next ticket is checked.** The loop never looks past a human ticket to find
  runnable work behind it.
- **Human tickets are recognised by the status line inside the ticket file**, nowhere else.
- **No run-time-generated control ticket.** A generic "check the human's work" ticket has no
  concrete criteria, and generating tickets mid-run would add state and rewrite order.md.
  Check tickets are written at planning time by the skill, with criteria specific to their
  human ticket.
- **The loop never commits the human's work.** Uncommitted host work never reaches the
  sandbox clone, and the loop never commits work it cannot prove is its own. The loop only
  commits `DONE_` renames, and only on a clean tree.
- **Warnings never block.** They print; exit codes and run behaviour are unchanged.
- **The noun is "followup ticket"** (renamed from "check ticket" on 2026-09-27, after tickets
  01–04 were written; this plan still says "check ticket" below). Ticket 05 renames it in the
  code and docs. The formats keep their spelling: `**Checks:**`, `[CHECKS <name>]`,
  `## Sent back by`, `check: send <NN> back`.

---

## The ticket formats

Human ticket:

```
**Status:** ready-for-human
**Handoff:** .scratch/<batch>/handoff/<NN>-<slug>.md
```

Check ticket (immediately follows its human ticket in the order):

```
**Status:** ready-for-agent
**Blocked by:** <NN>
**Checks:** <NN>-<slug>.md
```

Resolution rules — one implementation, used everywhere:

- **`Checks:`** is a ticket file NAME. It resolves to the batch ticket (from
  `foreman-next.sh --all`) whose basename, with any `FOREMAN_DONE_PREFIX` stripped, equals it
  (also with the prefix stripped). No match → unresolved (a warning, see below).
- **`Handoff:`** is a path, resolved like an order.md entry: as given if it exists, else
  relative to the batch directory.
- Both are read with a line anchored at the start, bold optional:
  `^\(\*\*\)\?Handoff:\(\*\*\)\? *` — the value is the rest of the line, trimmed.

The handoff directory must not be scanned as tickets. It is not, by default:
`FOREMAN_ISSUES_DIRS` defaults to `issues`, and even `FOREMAN_ISSUES_DIRS=.` scans with
`-maxdepth 1`, so `handoff/` beside `issues/` is never picked up.

**Sending back.** A check ticket that finds the handoff inadequate does not do dependent
work. It sets the human ticket's status line back to `ready-for-human`, appends to the human
ticket a section headed exactly `## Sent back by <check ticket basename>` saying what is
missing, leaves its own status line unflipped, and commits as
`check: send <NN> back — <what is missing>`. The next pick is the human ticket again (it is
earlier in the order and no longer done), so the gate stops the run.

---

## Precedence

A ticket is classified in this order: **done** (matches `FOREMAN_DONE_PATTERN`) → **human**
(matches `FOREMAN_HUMAN_PATTERN`) → **agent** (anything else).

Within the loop, at the top of each iteration: **pick → human gate → stall-marker start-of-run
check → attempt/budget checks → …**. The gate comes before the budget checks on purpose: with
`foreman run batch 1` landing ticket 14, the next pick is human ticket 15, and "waiting on a
human" is the truer reason to stop — a rerun with more budget would hit the gate anyway.

---

## Changes, file by file

### `lib/foreman-config.sh`

Next to `FOREMAN_DONE_WORD` / `FOREMAN_DONE_PATTERN` (around line 147):

- `FOREMAN_HUMAN_WORD="${FOREMAN_HUMAN_WORD-ready-for-human}"` — `${VAR-default}`, so setting it
  empty in foreman.conf switches human tickets off.
- `FOREMAN_HUMAN_PATTERN`: if unset, derive it the same way the done pattern is derived:
  `^<escaped FOREMAN_STATUS_LINE> *<FOREMAN_HUMAN_WORD>`; empty when the word is empty. Factor the
  existing `sed` escaping of the status line into one helper used by both derivations.

### `lib/foreman-human.sh` (new)

Sourced by `foreman-loop.sh` and `foreman-order.sh` after `foreman-config.sh`. The one place that
knows what a human ticket, a check ticket and a handoff file are. Functions:

- `foreman_ticket_needs_human TICKET` — not done, and matches `FOREMAN_HUMAN_PATTERN`.
- `foreman_ticket_field TICKET NAME` — prints the trimmed value of a `NAME:` line, or nothing.
- `foreman_handoff_path TICKET` — the resolved `Handoff:` path, or nothing.
- `foreman_checked_ticket CHECK_TICKET` — the resolved ticket its `Checks:` names, or nothing
  (return 1 if it has a `Checks:` line that does not resolve).
- `foreman_pending_checker TICKET` — prints a NOT-done ticket whose `Checks:` resolves to
  TICKET, if any. Used by the rename rule.
- `foreman_was_sent_back TICKET` — prints the check ticket name from its LAST
  `## Sent back by …` heading, if any.
- `foreman_human_warnings` — prints the warnings below, one per line, prefixed `warning: `,
  over `foreman-next.sh --all` in order. Always returns 0.

Each function greps; none calls a model. Keep them small and flat — this is lookup, not
policy.

### Warnings (`foreman_human_warnings`)

Evaluated over the ordered ticket list:

1. `warning: <human> is a human ticket with no ticket that Checks: it` — for each NOT-done
   human ticket, when no ticket's `Checks:` resolves to it.
2. `warning: <human> has no Handoff: file` — for each NOT-done human ticket whose `Handoff:`
   line is missing, or names a file that does not exist.
3. `warning: <check> should come right after <checked> in order.md` — for each NOT-done
   check ticket whose checked ticket is not the entry immediately before it in the order.
   Keyed on `Checks:` and order only, NOT on the checked ticket's status: once the human sets
   it `done` it no longer matches the human pattern, and the warning must not change meaning.
4. `warning: <check> Checks: <name>, which is not a ticket in this batch` — unresolved.

When `FOREMAN_HUMAN_PATTERN` is empty, warnings 1–2 are skipped; 3–4 still apply.

### `lib/foreman-next.sh`

No behaviour change. Update the header comment: "next" is still the first not-done ticket,
human or not; the loop decides what a human ticket at the head of the order means.

### `lib/foreman-loop.sh`

**Header.** Add `30  waiting on a human — the next ticket is a human ticket` to EXIT CODES,
`FOREMAN_HUMAN_WORD` to OTHER KNOBS, and a sentence under RESUMING. Add
`EXIT_WAITING_ON_HUMAN=30` beside the other exit constants. Source `foreman-human.sh`.

**`human_ticket_note TICKET`** — one function, used by every place that stops at the gate. To
stderr (stdout in `status`):

```
── <ticket> is a human ticket. The loop stops here.

[↩ It was sent back by <check ticket>: read '## Sent back by <check ticket>' at the
   bottom of it.]

It is marked '<FOREMAN_STATUS_LINE> <FOREMAN_HUMAN_WORD>': no agent is given it, and no ticket
after it runs until it is done. It is your turn now:

  1. Do what the ticket asks.
  2. Fill in every section of <handoff path>.
  3. Commit your work and the handoff file.
  4. Set its status line to '<FOREMAN_STATUS_LINE> done', tick its boxes, and commit.
  5. Rerun:  <FOREMAN_INVOKE> run <batch><resume args>

Rerunning before step 4 stops here again, and costs nothing.
```

- The `↩` paragraph only when `foreman_was_sent_back` finds a heading AND the ticket is
  currently a human ticket (which it is, whenever this note prints).
- Step 2 only when the ticket has a resolvable `Handoff:`; renumber the rest otherwise.
- `<resume args>` is the same `" N"` / `" --unlimited"` the paused footer already builds —
  factor that into a helper and use it in both places.

**Rename rule.** Change `mark_ticket_done_on_disk` so it also returns early (with a note:
`   note: <ticket> waits for <checker> before it is marked done`) when
`foreman_pending_checker` finds a not-done ticket that `Checks:` it. Without this, a human
ticket renamed `DONE_` and then sent back would be a `DONE_` file waiting on a human.

**After a check ticket lands** (the existing "5. The ticket landed." branch): after
`mark_ticket_done_on_disk "$TICKET_FILE"`, if `foreman_checked_ticket "$TICKET_FILE"` resolves,
call `mark_ticket_done_on_disk` on that ticket too — the human ticket is now done and
verified.

**Start-of-run rename sweep** (`MODE=run` only), right after preflight passes and before
`next_ticket=$(next_sh)`:

- Skip entirely if `tree_is_dirty`. A dirty tree may be a stall the marker vouches for, and a
  rename commit would move HEAD and break `stall_marker_matches` (which compares the marker's
  `base_ref` against HEAD), losing the automatic rescue.
- Otherwise call `mark_ticket_done_on_disk` for each ticket in `next_sh --all`. It already
  skips not-done, already-prefixed and unticked tickets, and (with the rule above) ones still
  awaiting their check. It commits only the two paths per rename. This also tidies any ticket
  finished by hand; the issue-tracker convention asks for that rename anyway.
- Not in `status` or `dry-run`: those modes never commit.

**Pre-run gate**, after the "Nothing to do" check:

- `dry-run`: still exits 0. If `foreman_ticket_needs_human "$next_ticket"`, print the marked
  plan (below), then `Would stop before <ticket>: it is a human ticket. No prompt would be
  sent.`, and skip the prompt.
- `run`: if the next ticket is human, call `human_ticket_note` and `exit 30` — before the run
  log header is written and before `exec_prepare`, so nothing starts and nothing is recorded.

**In-loop gate**, immediately after a successful `TICKET_FILE=$(next_sh)`, before the
per-ticket counter reset, the stall-marker check and the budget checks:

```bash
if foreman_ticket_needs_human "$TICKET_FILE"; then
  # The previous iteration was this ticket's check, and it sent it back. The iteration
  # itself was reported as "progressed" (HEAD moved, check ticket unflipped); say what it was.
  if [ -n "$CURRENT_TICKET" ] &&
     [ "$(foreman_checked_ticket "$CURRENT_TICKET")" = "$TICKET_FILE" ]; then
    say "   ↩ sent back to a human by $(basename "$CURRENT_TICKET")"
  fi
  HUMAN_TICKET="$TICKET_FILE"
  FINAL_STATUS="$EXIT_WAITING_ON_HUMAN"
  break
fi
```

The check ticket's continuation counter is irrelevant here: the run ends.

**Footer.** New case for `EXIT_WAITING_ON_HUMAN`: after the usual summary, call
`human_ticket_note "$HUMAN_TICKET"` and
`log_append "# stopped: waiting on a human — $HUMAN_TICKET"`.

**`status` mode**, reworked so human tickets are unmissable:

```
Batch: .scratch/frame-lab
Tickets done: 11 / 16  ·  human tickets remaining: 1

Next: .scratch/frame-lab/issues/12-sensitivity.md

Remaining, in order:
  1  .scratch/frame-lab/issues/12-sensitivity.md
  2  .scratch/frame-lab/issues/13-property-tests.md
  3  .scratch/frame-lab/issues/14-batch-run.md
  4  .scratch/frame-lab/issues/15-owner-review.md   [HUMAN]
  5  .scratch/frame-lab/issues/16-check-owner-review.md   [CHECKS 15-owner-review.md]

The loop will run 3 ticket(s), then stop at 15-owner-review.md for a human.

warning: ...
```

- Every remaining human ticket carries `   [HUMAN]`; every remaining check ticket carries
  `   [CHECKS <name>]`. Build the list in bash rather than `nl`.
- `· human tickets remaining: N` only when N > 0.
- If the NEXT ticket is human: `Next: <path>   [HUMAN — the loop will not run until you do
  it]`, the list, then `human_ticket_note` to stdout.
- The "The loop will run N ticket(s), then stop at …" line only when a human ticket remains
  and is not next.
- `foreman_human_warnings` output last, after a blank line, only if non-empty. Exit 0 always.
- With no human or check tickets, the output is exactly what it is today.

`dry-run`'s "Would run, in this order:" uses the same marked listing — one shared function,
`print_remaining_marked` — and prints the warnings too.

### `lib/foreman-order.sh`

- Source `foreman-human.sh`. Build the human-ticket list with `foreman_ticket_needs_human`, and
  note whether any ticket has a `Checks:` line.
- Change the "weighing three things" sentence so priority is explicit: **dependencies, then
  human-ticket placement (and check-ticket adjacency), then importance, then load.**
- If there are human tickets, append:

  ```
  HUMAN TICKETS. These tickets are done by a person, not by the loop:
  - <path>
  ...
  The loop stops at the first human ticket it reaches and runs nothing after it until a
  person has finished it. So, for each human ticket:
  - it comes after every ticket it depends on;
  - every ticket that depends on it — directly, or through another ticket — comes after it;
  - it goes as LATE as those two rules allow: every ticket that does not depend on it,
    directly or transitively, goes before it, so the unattended stretch before each stop is
    as long as possible.
  In the prose above the order block, name each human ticket, the tickets that wait on it,
  and why it sits where it does.
  ```

- If any ticket has a `Checks:` line, append:

  ```
  CHECK TICKETS. A ticket with a `Checks:` line verifies the ticket it names. It goes
  IMMEDIATELY after that ticket, with nothing between them: an unrelated ticket in between
  could build on work that has not been checked yet.
  ```

- Always add: "A ticket's `Blocked by:` line, when it has one, is an explicit dependency:
  honour it exactly."
- After a successful agent call, print `foreman_human_warnings` output (if any) after the
  "review it" line. Exit status unchanged.

### `lib/foreman.conf.template`

In the Tickets section, after the done-word block:

```
# A HUMAN TICKET is one only a person can do. Mark it with this word on its status line
# ('**Status:** ready-for-human'); the loop stops before it (exit 30) and runs nothing after
# it until the person sets it to done. Give it a '**Handoff:** <file>' line naming the file
# the person fills in, and follow it with a check ticket ('**Checks:** <its file name>').
# Set empty to treat every ticket as an agent's.
#FOREMAN_HUMAN_WORD=ready-for-human
#FOREMAN_HUMAN_PATTERN='^\*\*Status:\*\* *ready-for-human'
```

### `lib/foreman-init.sh`

The prose it writes into a fresh `order.md` (line ~117) says a "ticket that must not run
until a human has done something" belongs in prose. Replace with: mark a human step as its
own ticket with `**Status:** ready-for-human`, a `**Handoff:**` file and a check ticket;
`foreman order` places them, and the loop stops there.

---

## The planning skill

Settled with the owner on 2026-09-27; the full design is ticket 06
(`issues/06-a-skill-writes-followup-tickets-and-handoff-files.md`). In short:

- **`foreman-human-followup-tickets`**, at `skills/foreman-human-followup-tickets/SKILL.md` in this
  repo (writer and reader change together), user-invoked, written following
  `writing-for-agents`.
- It runs after `to-tickets`, usually before `foreman init`, and works only from the batch on
  disk. A human ticket is one whose status line already carries the human label: the skill
  never classifies, splits, re-statuses or renumbers a ticket, and never edits another
  ticket's `Blocked by:`. So the "split mixed tickets" and "mark human tickets" steps once
  planned here are gone.
- For each not-done human ticket it adds only what is missing — the `Handoff:` line, the
  handoff file (never overwritten), and a followup ticket `<NN>a-followup-<slug>.md` — so
  re-running it is safe. Warnings 1 and 2 point at it.
- The label words come from the repo's `docs/agents/triage-labels.md` when it exists; the
  skill tells the user the `foreman.conf` line when `FOREMAN_HUMAN_WORD` differs.
- `install.sh` copies it into `~/.claude/skills/` with a marker file; `foreman doctor` warns when
  the copy is stale.
- Ticket 07 (human) and 07a (its followup ticket) have the owner try it on a real batch.

---

## Docs

- **`CONTEXT.md`**, under "The things being worked on":

  > **Human ticket**: A ticket only a person can do, marked by its status line
  > (`ready-for-human` by default). The loop never gives it to an agent; reaching it in the
  > order ends the run, and nothing after it runs until the person marks it done.
  > _Avoid_: Manual ticket, blocked ticket, HITL ticket
  >
  > **Handoff file**: The file a human ticket names on its `Handoff:` line, written as a
  > template at planning time and filled in by the person: what they did, where it is, what
  > they decided. What its followup ticket reads.
  > _Avoid_: Feedback file, report
  >
  > **Followup ticket**: An ordinary agent ticket that immediately follows a human ticket and
  > names it on a `Checks:` line. It verifies the handoff file against the human ticket's
  > criteria and, if it falls short, sends the human ticket back.
  > _Avoid_: Check ticket, control ticket, review ticket, verification ticket

  and a run ending:

  > **Waiting on a human**: The run stopped because the next ticket is a human ticket (exit
  > 30). Distinct from a stop that *needs* a human (exit 20), where something went wrong.
  > _Avoid_: Blocked, paused (that is exit 10)

- **`README.md`**:
  - "Setting up a batch": a "Human tickets" subsection — the two ticket formats, the handoff
    file, sending back, and the human → check → consume pattern with the owner-review
    example split into 15 (human) / 16 (check) / 17 (apply the tuning).
  - "Ordering": how `foreman order` places human tickets and keeps check tickets adjacent.
  - "Pausing and resuming": exit **30** — what it means, that rerunning stops again for free,
    how it differs from 10 and 20; the start-of-run rename sweep and why a human ticket is
    renamed only after its check.
  - The quick-start `foreman status` comment: "what is left, what is next, where a human is
    needed".
  - Install: the skill.

---

## Tests (`test/smoke.sh`, fake adapter)

Fixture helpers:

- `make_human_ticket REPO N [HANDOFF]` — rewrites ticket N's status to `ready-for-human`,
  adds `**Handoff:** batch/handoff/0N-ticket.md` and creates that file (unless `HANDOFF=none`),
  commits.
- `make_check_ticket REPO N M` — ticket N gets `**Checks:** 0M-ticket.md`, commits.
- A fake behaviour `send-back`: the "agent" sets the ticket named by the current ticket's
  `Checks:` back to `ready-for-human`, appends `## Sent back by <basename>`, commits, leaves
  its own status unflipped. Add it to fake.sh's behaviour list and header.

Cases:

1. **status marks human and check tickets.** 5 tickets, #3 human, #4 checks #3: `status`
   exits 0; `03-ticket.md   [HUMAN]`, `04-ticket.md   [CHECKS 03-ticket.md]`,
   `human tickets remaining: 1`, "will run 2 ticket(s), then stop at 03-ticket.md"; no
   `warning:`.
2. **status when the next ticket is human.** `Next:` carries `[HUMAN`; the note appears and
   names the handoff path.
3. **no human tickets → status unchanged.** In the existing status case, assert `[HUMAN]`,
   `human tickets remaining` and `warning:` are absent.
4. **warnings.** Each on its own and all with `status` still exiting 0: human ticket with no
   check ticket; with `HANDOFF=none`; with a `Handoff:` naming a missing file; check ticket
   not adjacent (order.md puts another ticket between); `Checks:` naming no ticket.
5. **run stops before spending anything.** #1 human: `run batch --unlimited` exits 30; no new
   commits; no `foreman-runs.jsonl` rows; `FOREMAN_FAKE_PROMPT_LOG` empty; output names the
   ticket, the handoff path and the rerun command.
6. **run stops mid-batch.** 5 tickets, #3 human, #4 checks it, `--unlimited`: exits 30;
   tickets 1–2 landed; 4–5 never prompted; the run log ends with
   `# stopped: waiting on a human`.
7. **the gate beats the iteration budget.** 2 tickets, #2 human, default budget (1): lands #1,
   exits **30**, not 10.
8. **rerunning without finishing it stops again, free.** Rerun case 6's repo: exits 30, HEAD
   unchanged, no new JSONL rows.
9. **finishing it resumes, and the rename waits for the check.** Continue case 8: set #3
   `done` (boxes ticked), commit, `run batch 1`: the start-of-run sweep does NOT rename #3
   (#4 still checks it; the "waits for" note appears); #4 lands; now #3 AND #4 are both
   `DONE_`-prefixed.
10. **a check ticket sends it back.** Like 9, but `FOREMAN_FAKE_BEHAVIOUR=send-back` for #4:
    exits 30; output has `↩ sent back to a human by 04-ticket.md` and the note's "sent back
    by" paragraph; #3 is `ready-for-human`, unprefixed, with the `## Sent back by` section;
    #5 never ran. A plain rerun prints the "sent back by" paragraph again.
11. **the sweep leaves a dirty tree alone.** A done-but-unrenamed ticket plus an uncommitted
    file and `FOREMAN_ALLOW_DIRTY=1`: no rename commit.
12. **dry-run at a human ticket.** Exits 0, says "Would stop before", no `=== prompt that
    would be sent` block.
13. **the word is configurable and can be switched off.** `FOREMAN_HUMAN_WORD=needs-owner` stops
    on that status; `FOREMAN_HUMAN_WORD=` hands a `ready-for-human` ticket to the agent.
14. **`foreman order` tells the agent.** A stub `claude` first on `PATH` writes its `-p`
    argument to a file and prints `{"total_cost_usd":0}`. With #2 human and #3 checks #2: the
    prompt has `HUMAN TICKETS` with #2's path and `CHECK TICKETS`. With neither: both
    sections absent. Warnings are printed after ordering when #2 has no check ticket.

Run the whole suite (`bash test/smoke.sh`), not just the new cases — the status rework, the
gate and the rename rule sit on paths every existing case goes through.

## Suggested commits (one ticket each, if run through foreman)

1. **Human tickets and the gate.** Config, `foreman-human.sh` (needs-human, fields, handoff
   path, sent-back), loop gate (pre-run, in-loop, footer, exit 30), `human_ticket_note`,
   dry-run stop. Tests 5–8, 12, 13.
2. **Check tickets and the rename.** `Checks:` resolution, pending-checker rename rule, rename
   after a check lands, start-of-run sweep, `send-back` fake behaviour, "↩ sent back" line.
   Tests 9–11.
3. **Status and warnings.** Marked listing for status and dry-run, `foreman_human_warnings`.
   Tests 1–4.
4. **Ordering.** `foreman order` prompt sections and warnings. Test 14.
5. **Docs.** README, CONTEXT.md, conf template, init prose, loop header.
6. **The planning skill** and its install — ticket 06; then 07/07a, trying it for real.

## Done when

- [ ] A `ready-for-human` ticket at the head of the order stops `foreman run` with exit 30
      before the sandbox starts, before budgets, and before any prompt is sent
- [ ] A run reaching one mid-batch stops there with exit 30 and runs nothing after it
- [ ] The exit-30 message names the ticket's handoff file, and says when it was sent back
- [ ] Rerunning without finishing it stops again at no cost; finishing it resumes the batch
- [ ] A check ticket that sends its human ticket back ends the run at exit 30, with the
      human ticket unprefixed and carrying a `## Sent back by` note
- [ ] A human ticket is renamed `DONE_` only once its check ticket has landed; renames never
      happen on a dirty tree
- [ ] `foreman status` and `foreman dry-run` mark human and check tickets and say where the next
      stop is
- [ ] The four warnings print from `foreman status`, `foreman dry-run` and `foreman order`, and
      never change an exit code
- [ ] `foreman order`'s prompt places human tickets as late as their dependents allow, with
      each check ticket immediately after its human ticket
- [ ] `FOREMAN_HUMAN_WORD` is configurable and empty disables human tickets
- [ ] The planning skill adds each human ticket's handoff file and followup ticket, and
      `install.sh` installs it
- [ ] README, CONTEXT.md, conf template and init prose describe all of the above
- [ ] `bash test/smoke.sh` passes in full
