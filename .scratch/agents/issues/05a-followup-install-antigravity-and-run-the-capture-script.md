# 05a: Follow up on 05 — Install Antigravity and run the capture script

**Status:** ready-for-agent

**Blocked by:** 05

**Checks:** 05-install-antigravity-and-run-the-capture-script.md

**What to build:**

Verify the handoff file `.scratch/agents/handoff/05-install-antigravity-and-run-the-capture-script.md`
and the committed captures against ticket 05's acceptance criteria, before ticket 06 builds
on them.

**Acceptance criteria:**

- [ ] every section of the handoff file is answered, not left as its placeholder or "TBD"
- [ ] the answers are specific (names, locations, values) and satisfy, one by one, the human
      ticket's own acceptance criteria
- [ ] both captures (signed in and key) are in the repo, each with every probe ticket 04 defines
- [ ] neither the handoff file nor any capture contains an API key's value or an e-mail address

**Outcomes:**

- **passes:** tick its boxes, set its own status line to done, commit. Nothing else — the
  loop renames the human ticket once this lands.
- **falls short:** do no dependent work; set the human ticket's status line back to the
  human label; append to the human ticket a section headed exactly
  `## Sent back by 05a-followup-install-antigravity-and-run-the-capture-script.md` saying what
  is missing; leave its own status line unflipped; commit as `check: send 05 back — <what is missing>`.
