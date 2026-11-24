# Human pieces

Step 6 of `foreman-to-tickets`. A human ticket needs three pieces to run under Foreman: a
`Handoff:` line, a handoff file, and a followup ticket. This adds whichever of them each
human ticket is missing, and only those, so running it twice, or after the batch grows a new
human ticket, changes only what is new.

A **human ticket** here is one whose status line carries the human label (see "Label words"
in `SKILL.md`). Act on those tickets as they stand:

- Leave every ticket's status, number, split and `Blocked by:` line as it is.
- Never overwrite a handoff file that already exists: it may hold the person's answers.

## 1. Check `foreman.conf`

`<batch>/foreman.conf` may not exist yet, since this usually runs before `foreman init`. If
it has a `FOREMAN_HUMAN_WORD=` line set to a word other than the human label, or it has no
such line and the human label is not `ready-for-human`, step 5 owes the user that line. Never
edit `foreman.conf` yourself.

Done when you know whether step 5 owes the user a `foreman.conf` line.

## 2. Give each human ticket that is not done what it is missing

Not done: its file name has no `DONE_` prefix, and its status line is not `done` or
`implemented`. The three pieces:

**The `Handoff:` line**, directly under its status line:

```
**Handoff:** .scratch/<batch>/handoff/HANDOFF_<its file name>
```

The `HANDOFF_` prefix keeps the handoff file from sharing its ticket's exact file name. A
`Handoff:` line that already exists stays as it is, whatever it names.

**The handoff file**, at that path, unless it already exists:

- a title: `# Handoff — ` followed by the human ticket's own heading, with its leading `# `
  removed;
- one HTML comment, before any heading, telling the person to fill in every section, then
  set the ticket's status line to done, tick its boxes and commit, and that a secret is
  recorded by WHERE it is stored, never its value, because the file is committed and read by
  an agent (name the followup ticket from below);
- one `##` heading per acceptance criterion (checkbox line) of the human ticket, verbatim
  minus the checkbox marker, each followed by an empty placeholder HTML comment.

**A followup ticket**, when no ticket in the batch has a `Checks:` line naming this one
(ignoring a `DONE_` prefix on either side of the match). For human ticket
`15-owner-review.md` it is `15a-followup-owner-review.md`, or the next free letter if `15a-…`
already exists as a file. The suffix keeps every other ticket's number, and file-name order
puts `15a` right after `15`. Title it `# 15a: Follow up on 15 — <the human ticket's title>`,
with the agent label as its status, `**Blocked by:** 15` and `**Checks:** 15-owner-review.md`.
Its body is step 3.

Done when every not-done human ticket in the batch carries all three pieces.

## 3. Write the followup ticket's criteria

Only what an agent can observe in the repo, never an account, a vault or a device:

```
- [ ] every section of the handoff file is answered, not left as its placeholder or "TBD"
- [ ] the answers are specific (names, locations, values) and satisfy, one by one, the human
      ticket's own acceptance criteria
- [ ] anything the handoff says is in the repo (a file, a config key, a commit) is there
- [ ] the handoff file contains no secret value
```

Then its two outcomes, verbatim (substitute only the ticket numbers and the "what is
missing" specifics):

```
- **passes:** tick its boxes, set its own status line to done, commit. Nothing else — the
  loop renames the human ticket once this lands.
- **falls short:** do no dependent work; set the human ticket's status line back to the
  human label; append to the human ticket a section headed exactly
  `## Sent back by 15a-followup-owner-review.md` saying what is missing; leave its own
  status line unflipped; commit as `check: send 15 back — <what is missing>`.
```

Done when every followup ticket you wrote in step 2 carries this checklist and both outcomes.

## 4. Check your own work, then commit

For every not-done human ticket: it has a `Handoff:` line, that file exists, and some
ticket's `Checks:` line names it. Every file written or edited in this run (the tickets from
`SKILL.md` step 5 included) decodes as valid UTF-8, for example
`iconv -f UTF-8 -t UTF-8 <file> > /dev/null` exits 0. Fix any that does not by turning each
0x97 back into `—`, and check it again.

Then commit exactly the files written or edited in this run, together, in one commit:
`docs(<slug>): break the spec into tickets` after slicing, or
`docs(<slug>): add the human tickets' handoff files and followups` after topping up.

Done when every check above passes and the commit holds exactly those files.

## 5. Tell the user

Say this, without running any of it, if this run wrote or edited a file:

```
Next:  foreman init <batch>   (or: foreman order <batch>, if <batch>/foreman.conf already exists —
       the new tickets only run once order.md lists them)
Then:  foreman status <batch> should show no warnings.
```

If this run wrote or edited nothing (topping up found no human ticket missing a piece), no
`foreman init` or `foreman order` is owed. Say this instead:

```
Nothing was added — no human ticket in <batch> was missing a Handoff: line, handoff file or
followup ticket. No foreman command is needed for this run.
```

Either way, if step 1 found a `foreman.conf` line to add, append:

```
Also add to <batch>/foreman.conf:
  FOREMAN_HUMAN_WORD=<the human label>
```
