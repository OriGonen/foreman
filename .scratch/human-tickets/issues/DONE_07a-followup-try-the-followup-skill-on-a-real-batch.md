# 07a: Follow up on 07 — Try the followup-tickets skill on a real batch

**Status:** done

**Blocked by:** 07

**Checks:** 07-try-the-followup-skill-on-a-real-batch.md

**What to build:**

Ticket 07 had the user try the `foreman-human-followup-tickets` skill on a throwaway batch and
report in `.scratch/human-tickets/handoff/07-try-the-followup-skill-on-a-real-batch.md`. Read
that handoff and ticket 07, and judge whether the handoff is complete — not whether the skill
is. You can only verify what is in this repo: the throwaway repo, and anything the user did in
their own Claude Code, are out of reach, so judge the answers as written.

A problem the handoff reports with the skill is not a reason to send ticket 07 back: it means
the handoff did its job. Write each reported problem as a new ticket in
`.scratch/human-tickets/issues/`, numbered after the last ticket there, `**Status:**
ready-for-agent`, with acceptance criteria taken from the report.

**If the handoff falls short:** do no other work. Set ticket 07's status line back to
`**Status:** ready-for-human`; append to ticket 07 a section headed exactly
`## Sent back by 07a-followup-try-the-followup-skill-on-a-real-batch.md` saying what is
missing; leave this ticket's status line unflipped; commit as
`check: send 07 back — <what is missing>`.

**If it passes:** tick this ticket's boxes, set its status line to done, and commit, together
with any new tickets.

**Acceptance criteria:**

- [x] Every section of the handoff is answered: no section is left as its placeholder, empty,
      or "TBD"
- [x] The answers are specific (which files, what the skill wrote, what `foreman status` printed)
      and speak to each of ticket 07's criteria in turn
- [x] The handoff contains no secret value
- [x] Every problem the handoff reports is a new `ready-for-agent` ticket in this batch, or the
      handoff reports none
