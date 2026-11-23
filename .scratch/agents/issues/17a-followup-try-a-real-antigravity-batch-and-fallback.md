# 17a: Follow up on 17 — Try a real Antigravity batch and a real fallback

**Status:** ready-for-agent

**Blocked by:** 17

**Checks:** 17-try-a-real-antigravity-batch-and-fallback.md

**What to build:**

Verify the handoff file `.scratch/agents/handoff/17-try-a-real-antigravity-batch-and-fallback.md`
against ticket 17's acceptance criteria. Each problem the handoff lists that this spec
should have prevented is a bug: write it up as a new numbered ticket in this directory,
blocked by nothing, and mention it in the closing note.

**Acceptance criteria:**

- [ ] every section of the handoff file is answered, not left as its placeholder or "TBD"
- [ ] the answers are specific (names, locations, values) and satisfy, one by one, the human
      ticket's own acceptance criteria
- [ ] anything the handoff says is in the repo (a file, a config key, a commit) is there
- [ ] the handoff file contains no secret value
- [ ] each problem listed is either a new ticket or explained in the closing note as not a bug

**Outcomes:**

- **passes:** tick its boxes, set its own status line to done, commit. Nothing else — the
  loop renames the human ticket once this lands.
- **falls short:** do no dependent work; set the human ticket's status line back to the
  human label; append to the human ticket a section headed exactly
  `## Sent back by 17a-followup-try-a-real-antigravity-batch-and-fallback.md` saying what is
  missing; leave its own status line unflipped; commit as `check: send 17 back — <what is missing>`.
