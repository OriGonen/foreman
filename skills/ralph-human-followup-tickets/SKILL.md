---
name: ralph-human-followup-tickets
description: Add the followup tickets and handoff files a batch's human tickets are missing, after to-tickets and before ralph init.
disable-model-invocation: true
---

# ralph-human-followup-tickets

Adds the pieces a batch's human tickets need to run under ralph: a `Handoff:` line, a
handoff file, and a followup ticket — for every human ticket that is missing one. Never
overwrites a handoff file, so running this twice, or running it after the batch grew a new
human ticket, changes only what is new.

## Never

- Classify a ticket, split one, change an existing ticket's status, or renumber one.
- Edit another ticket's `Blocked by:` line.
- Overwrite a handoff file that already exists — it may hold the person's answers.

A **human ticket** is one whose status line already carries the human label (step 2). This
skill never decides that a ticket is one; it only acts on tickets already marked as such.
`ralph`'s glossary (`CONTEXT.md`) defines human ticket, handoff file and followup ticket —
read it if those terms are unfamiliar.

## Steps

### 1. Find the batch

The directory holding `issues/` that `to-tickets` just wrote, or the one the user names. Ask
if it is ambiguous. Done when you have one batch directory to work in.

### 2. Read the label words

The human and agent labels are the right-hand column of `docs/agents/triage-labels.md` for
`ready-for-human` and `ready-for-agent`, when that file exists; otherwise those two strings,
literally.

Then check `<batch>/ralph.conf` (it may not exist yet — this skill usually runs before
`ralph init`) for a `RALPH_HUMAN_WORD=` line. If it sets a word different from the human
label, or the file has no such line and the human label is not `ready-for-human`, remember
this: step 6 tells the user the exact line to add. Never edit `ralph.conf` yourself.

Done when you know the human label, the agent label, and whether step 6 owes the user a
`ralph.conf` line.

### 3. For each human ticket that is not done, add what it is missing

Not done: its file name has no `DONE_` prefix, and its status line is not `done` or
`implemented`. Add whichever of these three it is missing from the ticket — and only those:

**The `Handoff:` line.** Directly under its status line:

```
**Handoff:** .scratch/<batch>/handoff/<its file name>
```

**The handoff file**, at that path, unless it already exists (never overwrite one — it may
hold the person's answers):

- a title: `# Handoff — ` followed by the human ticket's own heading, with its leading `# `
  removed;
- one HTML comment, before any heading, telling the person to fill in every section then set
  the ticket's status line to done and tick its boxes and commit, and that a secret is
  recorded by WHERE it is stored, never its value, because the file is committed and read by
  an agent (name the followup ticket from below);
- one `##` heading per acceptance criterion (checkbox line) of the human ticket, verbatim
  minus the checkbox marker, each followed by an empty placeholder HTML comment.

**A followup ticket**, when no ticket in the batch has a `Checks:` line naming this one
(ignoring a `DONE_` prefix on either side of the match). For human ticket `15-owner-review.md`
it is `15a-followup-owner-review.md` — the next free letter if `15a-…` already exists as a
file. The suffix keeps every other ticket's number, and file-name order puts `15a` right
after `15`. Title it `# 15a: Follow up on 15 — <the human ticket's title>`, status the agent
label, `**Blocked by:** 15`, `**Checks:** 15-owner-review.md` — its body is step 4.

Done when every not-done human ticket in the batch carries all three pieces.

### 4. Write the followup ticket's criteria

Only what an agent can observe in the repo — never an account, a vault, or a device:

```
- [ ] every section of the handoff file is answered, not left as its placeholder or "TBD"
- [ ] the answers are specific (names, locations, values) and satisfy, one by one, the human
      ticket's own acceptance criteria
- [ ] anything the handoff says is in the repo (a file, a config key, a commit) is there
- [ ] the handoff file contains no secret value
```

Then its two outcomes, verbatim (substitute only the ticket numbers and the "what is
missing" specifics — do not otherwise rephrase them):

```
- **passes:** tick its boxes, set its own status line to done, commit. Nothing else — the
  loop renames the human ticket once this lands.
- **falls short:** do no dependent work; set the human ticket's status line back to the
  human label; append to the human ticket a section headed exactly
  `## Sent back by 15a-followup-owner-review.md` saying what is missing; leave its own
  status line unflipped; commit as `check: send 15 back — <what is missing>`.
```

Done when every followup ticket you wrote in step 3 carries this checklist and both outcomes.

### 5. Check your own work

For every not-done human ticket: it has a `Handoff:` line, that file exists, and some
ticket's `Checks:` line names it. Then commit exactly the files you wrote or edited,
together, in one commit.

### 6. Tell the user

The same way every time, without running any of it:

```
Next:  ralph init <batch>   (or: ralph order <batch>, if <batch>/ralph.conf already exists —
       the new followup tickets only run once order.md lists them)
Then:  ralph status <batch> should show no warnings.
```

If step 2 found a `ralph.conf` line to add, append it:

```
Also add to <batch>/ralph.conf:
  RALPH_HUMAN_WORD=<the human label>
```
