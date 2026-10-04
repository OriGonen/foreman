# 02a: Follow up on 02 — Find out how `sbx secret` handles a `claude setup-token` token

**Status:** ready-for-agent

**Blocked by:** 02

**Checks:** 02-find-out-how-sbx-secret-takes-a-setup-token.md

**What to build:**

Verify the handoff file `.scratch/credentials-setup/handoff/02-find-out-how-sbx-secret-takes-a-setup-token.md`
against ticket 02's acceptance criteria, before ticket 03 builds on its answers.

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
  `## Sent back by 02a-followup-find-out-how-sbx-secret-takes-a-setup-token.md` saying what is missing; leave its own
  status line unflipped; commit as `check: send 02 back — <what is missing>`.
