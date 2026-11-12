# 15a: Follow up on 15 — Try the app on a real batch

**Status:** ready-for-agent

**Blocked by:** 15

**Checks:** 15-try-the-app-on-a-real-batch.md

**What to build:**

In ticket 15 the user tried the app on a real run. Their report is in
`.scratch/gui/handoff/15-try-the-app-on-a-real-batch.md`. Read that handoff and ticket 15, and
decide whether the handoff is complete. You are not judging whether the app is good.

You can only check what is in this repo: `foreman-runs.log`, `foreman-runs.jsonl` and the
status lines of the batch the user names. The user's machine and their login are out of reach,
so judge the rest as written.

A problem the handoff reports with the app is not a reason to send ticket 15 back. It means the
handoff did its job. Write each reported problem as a new ticket in `.scratch/gui/issues/`,
numbered after the last ticket there, with `**Status:** ready-for-agent` and acceptance criteria
taken from the report. Point each one at the design of the screen it concerns.

**If the handoff falls short:** do no other work. Set ticket 15's status line back to
`**Status:** ready-for-human`. Append to ticket 15 a section headed exactly
`## Sent back by 15a-followup-try-the-app-on-a-real-batch.md` saying what is missing. Leave this
ticket's status line unflipped. Commit as `check: send 15 back — <what is missing>`.

**If it passes:** tick this ticket's boxes, set its status line to done, and commit, together
with any new tickets.

**Acceptance criteria:**

- [ ] Every section of the handoff is answered. No section is left as its placeholder, empty,
      or "TBD"
- [ ] The answers are specific (which batch, which run id, what the app showed against what
      `foreman status` printed) and speak to each of ticket 15's criteria in turn
- [ ] Where the handoff names a run id, it appears in the repo's run log
- [ ] The handoff contains no secret value
- [ ] Every problem the handoff reports is a new `ready-for-agent` ticket in this batch, or the
      handoff reports none
