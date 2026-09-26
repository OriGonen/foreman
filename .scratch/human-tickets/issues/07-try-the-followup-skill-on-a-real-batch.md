# 07: Try the followup-tickets skill on a real batch

**Status:** ready-for-human
**Handoff:** .scratch/human-tickets/handoff/07-try-the-followup-skill-on-a-real-batch.md

**Blocked by:** 06

**What to do:**

Ticket 06 wrote the `ralph-human-followup-tickets` skill, but an agent cannot run it end to end:
the skill is invoked by a person in Claude Code, and the ticket's agent runs inside the
sandbox. So you try it, and report back in the handoff file.

1. `bash install.sh`, and check the skill is under `~/.claude/skills/`.
2. In a throwaway git repo (not ralph), make a batch of about four tickets in `to-tickets`'
   layout (`**What to build:**`, `**Blocked by:**`, `**Status:**`, then checkboxes), one or two
   of them `**Status:** ready-for-human` — or run `to-tickets` for real and mark them there.
3. Run `/ralph-human-followup-tickets` on it. Read what it wrote: the `Handoff:` lines, the
   handoff files, the followup tickets, the commit, the closing message.
4. Run it again. It should change nothing and commit nothing.
5. `ralph init` the batch, add one more human ticket, run the skill a third time. It should add
   that ticket's pieces only, and tell you to run `ralph order`. Run it, then `ralph status`.

Why this is a human ticket: the skill is interactive and runs in the user's own Claude Code,
and judging whether its output is right is a judgment call.

**Acceptance criteria:**

- [ ] The skill installs, and Claude Code lists it
- [ ] The first run added a `Handoff:` line, a handoff file and a followup ticket for every human
      ticket, and nothing else
- [ ] The second run changed nothing
- [ ] The third run, after `ralph init`, added only the new ticket's pieces and pointed at
      `ralph order`; after ordering, `ralph status` showed no warnings
- [ ] Everything the skill got wrong or unclear is written down, with the file it concerns
