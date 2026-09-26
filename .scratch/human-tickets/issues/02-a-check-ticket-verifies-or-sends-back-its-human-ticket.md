# 02: A check ticket verifies, or sends back, its human ticket

**Status:** ready-for-agent

**Blocked by:** 01

**What to build:**

Every human ticket is immediately followed in the order by a **check ticket**: an ordinary
agent ticket with a `**Checks:** <human ticket's file name>` line, which verifies the human's
handoff file before any agent work builds on it. The check tickets themselves are written at
planning time; this ticket makes the loop understand them.

**Sending back.** A check ticket that finds the handoff inadequate sets the human ticket's
status back to `ready-for-human`, appends a `## Sent back by <check ticket file name>` section
saying what is missing, leaves its own status unflipped, and commits. The loop sees that turn as
it would any unflipped commit, then its next pick is the human ticket again, so the gate from
ticket 01 stops the run with exit 30. Make that legible: the run prints
`↩ sent back to a human by <check ticket>`, and the human-ticket note — on this run and on
every rerun while the ticket is waiting — says it was sent back and points at the section.

**Renaming.** The loop, not an agent, renames finished tickets `DONE_`. Two changes:

- A ticket is not renamed while a not-done ticket still `Checks:` it (with a one-line note
  saying what it waits for). Otherwise a human ticket renamed `DONE_` and then sent back would
  be a `DONE_` file waiting on a human. When a check ticket lands, the loop renames the ticket
  it checks too.
- At the start of every `ralph run`, before picking a ticket, the loop renames any ticket that
  is done, fully ticked and not yet prefixed — this is how a human-finished ticket gets its
  prefix. Skipped entirely on a dirty tree: a rename commit would move HEAD and break the stall
  marker's match, losing the automatic rescue of stalled work. Never in `status` or `dry-run`.

`Checks:` resolves by file name against the batch's tickets, ignoring the `DONE_` prefix on
either side.

Full design: `.scratch/human-tickets/plan.md` — "The ticket formats" (resolution, sending
back), and the `ralph-human.sh` and `ralph-loop.sh` sections (rename rule, after a check
ticket lands, start-of-run rename sweep, in-loop gate).

**Acceptance criteria:**

- [ ] The fake adapter has a `send-back` behaviour that sends back the ticket the current
      ticket `Checks:`, documented in its header
- [ ] A check ticket that sends back its human ticket ends the run with exit 30; the output
      has the `↩ sent back` line; the human ticket is `ready-for-human`, unprefixed, and
      carries the `## Sent back by` section; nothing after the check ticket ran
- [ ] A plain rerun after a send-back prints the "sent back" paragraph in the note again
- [ ] A human ticket set to `done` is not renamed while its check ticket is unfinished, and
      the run says what it waits for
- [ ] When the check ticket lands, both it and its human ticket are `DONE_`-prefixed
- [ ] The start-of-run sweep renames a done, fully ticked, unprefixed ticket, and makes no
      commit on a dirty tree (`RALPH_ALLOW_DIRTY=1` plus an uncommitted file)
- [ ] `Checks:` resolves whether either side carries the `DONE_` prefix
- [ ] New smoke cases cover the above, and `bash test/smoke.sh` passes in full
