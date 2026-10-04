# 08a: Follow up on 08 — End-to-end check on this machine

**Status:** ready-for-agent

**Blocked by:** 08

**Checks:** 08-end-to-end-check-on-this-machine.md

**What to build:**

Verify the handoff file `.scratch/credentials-setup/handoff/08-end-to-end-check-on-this-machine.md`
against ticket 08's acceptance criteria.

**Acceptance criteria:**

- [ ] every section of the handoff file is answered, not left as its placeholder or "TBD"
- [ ] the answers are specific (names, locations, values) and satisfy, one by one, the human
      ticket's own acceptance criteria
- [ ] anything the handoff says is in the repo (a file, a config key, a commit) is there
- [ ] the handoff file contains no secret value

**Outcomes:**

- **passes:** tick its boxes, set its own status line to done, commit. Nothing else — the
  loop renames the human ticket once this lands.
- **falls short:** do no dependent work; set the human ticket's status line back to the
  human label; append to the human ticket a section headed exactly
  `## Sent back by 08a-followup-end-to-end-check-on-this-machine.md` saying what is missing; leave its own
  status line unflipped; commit as `check: send 08 back — <what is missing>`.
