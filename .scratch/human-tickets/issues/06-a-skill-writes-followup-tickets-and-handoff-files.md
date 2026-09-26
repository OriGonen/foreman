# 06: A skill writes the followup tickets and handoff files a batch's human tickets need

**Status:** ready-for-agent

**Blocked by:** 05

**What to build:**

Tickets 01–05 taught the loop to read human tickets, handoff files and followup tickets. Nothing
writes them yet: today a person would have to hand-write a handoff template and a followup
ticket for every human ticket, in the exact formats the loop reads. Add a Claude Code skill,
`ralph-human-followup-tickets`, that does it, and have `install.sh` install it.

**Where it fits.** The user plans with Matt Pocock's skills: `to-spec`, then `to-tickets`, which
writes one ticket per file under `.scratch/<batch>/issues/`. The tickets only a person can do
already carry the human label on their status line (`**Status:** ready-for-human`) by the time
this skill runs. The user then types `/ralph-human-followup-tickets`, usually in the same
context window and usually before `ralph init`. Those skills are a third-party plugin: this
ticket changes nothing in them.

**What the skill does and does not decide.** A human ticket is a ticket whose status line
already carries the human label. The skill never classifies tickets, never splits one, never
changes a status, never renumbers, and never edits a ticket's `Blocked by:` line. It adds the
pieces a human ticket is missing, and only those, so running it again on the same batch
changes nothing, and running it on a batch that has been partly run is safe.

**The skill**, at `skills/ralph-human-followup-tickets/SKILL.md` in this repo (the formats it
writes are ralph's, so writer and reader change together). User-invoked
(`disable-model-invocation: true`), with a one-line human-facing description. Written following
the `writing-for-agents` skill: steps with completion criteria, the leading term *followup
ticket* used as the glossary defines it (ticket 05), no restated environment. Its steps:

1. **Find the batch.** The directory holding `issues/` that `to-tickets` just wrote, or the one
   the user names. Ask if it is ambiguous.
2. **Read the label words.** The human and agent labels are the right-hand column of
   `docs/agents/triage-labels.md` for `ready-for-human` and `ready-for-agent`, when that file
   exists; otherwise those canonical names. If the batch's `ralph.conf` sets a
   `RALPH_HUMAN_WORD` different from the human label (or does not set one, and the label is
   not `ready-for-human`), remember to tell the user, in step 6, the exact line to put in
   `ralph.conf`. The skill never edits `ralph.conf`.
3. **For each human ticket that is not done** (not `DONE_`-prefixed, status not done), add
   whichever of these it is missing:
   - a `**Handoff:** .scratch/<batch>/handoff/<its file name>` line, directly under its status
     line;
   - that **handoff file**, never overwriting one that exists (it may hold the person's
     answers). Its contents: a title; a comment saying to fill in every section, then set the
     ticket's status line to done; one `##` heading per acceptance criterion of the human
     ticket, each with an empty placeholder comment; and the rule that a secret is recorded by
     WHERE it is stored, never its value, because the file is committed and read by an agent;
   - a **followup ticket**, when no ticket in the batch has a `Checks:` line naming this one
     (ignoring a `DONE_` prefix on either side). For human ticket `15-owner-review.md` it is
     `15a-followup-owner-review.md` (the next free letter if `15a-…` exists), titled
     `# 15a: Follow up on 15 — <the human ticket's title>`, with the agent label as its
     status, `**Blocked by:** 15` and `**Checks:** 15-owner-review.md`. The suffix keeps every
     other ticket's number, and file-name order puts `15a` right after `15`.
4. **The followup ticket's criteria** are only what an agent can observe from the repo: every
   handoff section is answered, not left as its placeholder or a "TBD"; the answers are
   specific (names, locations, values) and satisfy the human ticket's own acceptance criteria,
   one by one; anything the handoff says is in the repo (a file, a config key, a commit) is
   there; and the handoff contains no secret value. It never tries to verify the outside world
   (an account, a vault, a device). It carries two outcomes, verbatim:
   - **passes:** tick its boxes, set its own status line to done, commit. Nothing else — the
     loop renames the human ticket once this lands.
   - **falls short:** do no dependent work; set the human ticket's status line back to the
     human label; append to the human ticket a section headed exactly
     `## Sent back by <followup ticket's file name>` saying what is missing; leave its own
     status line unflipped; commit as `check: send <NN> back — <what is missing>`.
5. **Check its own work:** every not-done human ticket has a `Handoff:` line, that file exists,
   and a followup ticket's `Checks:` names it. Then commit exactly the files it wrote or
   edited, together.
6. **Tell the user**, the same way every time, without running any of it: next is
   `ralph init <batch>`, or `ralph order <batch>` if the batch already has a `ralph.conf` (the
   new followup tickets only run once `order.md` lists them); then `ralph status <batch>`
   should show no warnings. Plus the `ralph.conf` line from step 2, if any.

**ralph's warnings point at it.** The two warnings the skill fixes gain a pointer:
`… is a human ticket with no ticket that Checks: it — run /ralph-human-followup-tickets` and
`… has no Handoff: file — run /ralph-human-followup-tickets`. The other two warnings are
ordering mistakes the skill does not fix, and stay as they are.

**Installing it.** `install.sh` also copies `skills/ralph-human-followup-tickets/` to
`${CLAUDE_CONFIG_DIR:-~/.claude}/skills/ralph-human-followup-tickets/` — a copy, not a symlink,
for the same reason the shims are forwarders — and writes a marker file into the copy naming
the checkout it came from.

- Re-running `install.sh` replaces a copy carrying the marker without `--force`: that is how a
  pulled update is installed.
- A directory of that name without the marker is someone else's: refuse, as for the shims,
  unless `--force`. Refuse before writing anything.
- `--uninstall` removes the copy only if it carries the marker.
- `--no-skill` installs only the shims. `--to` still applies only to the shims.
- A copy goes stale when the checkout is pulled, so `ralph doctor` warns (free, no exit-code
  change) when an installed copy that carries the marker differs from the checkout's
  `skills/ralph-human-followup-tickets/`, and says to re-run `install.sh`.

Update `install.sh`'s header and `--help`, and the README: the Install section (what is
installed, the flags), and the "Human tickets" subsection (run the skill after `to-tickets`;
what it adds; that it never overwrites a handoff file and is safe to re-run).

**Acceptance criteria:**

- [ ] `skills/ralph-human-followup-tickets/SKILL.md` exists, is user-invoked, and covers steps
      1–6 above: the label mapping and the `ralph.conf` line, adding only what is missing, the
      handoff file contents including the secret rule, the followup ticket's name, title,
      fields, observable-only criteria and both outcomes verbatim, the self-check, the commit,
      and the fixed closing message
- [ ] The skill says it never classifies, splits, re-statuses or renumbers a ticket, never edits
      another ticket's `Blocked by:`, and never overwrites a handoff file
- [ ] Warnings 1 and 2 end with `run /ralph-human-followup-tickets`; warnings 3 and 4 are
      unchanged; the smoke assertions for them are updated
- [ ] `bash install.sh` (smoke case with `HOME` and `CLAUDE_CONFIG_DIR` in a temp dir, `--to` a
      temp dir) installs the shims and a copy of the skill carrying the marker
- [ ] Re-running it after changing the checkout's SKILL.md replaces the copy without `--force`
- [ ] A skill directory of that name without the marker makes `install.sh` exit non-zero and
      write nothing; `--force` overwrites it
- [ ] `--uninstall` removes a marked copy and leaves an unmarked one; `--no-skill` installs no
      skill
- [ ] `ralph doctor` warns when the installed copy differs from the checkout's, and is silent
      when they match or when no copy is installed
- [ ] `install.sh`'s header and `--help` and the README's Install and "Human tickets" sections
      describe the skill and the flags
- [ ] `bash test/smoke.sh` passes in full
