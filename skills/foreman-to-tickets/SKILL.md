---
name: foreman-to-tickets
description: Break a spec into a foreman batch of tracer-bullet tickets, with its human tickets marked and each given a handoff file and a followup ticket. Given a batch that already has tickets, add only the human pieces it is missing.
disable-model-invocation: true
argument-hint: "[spec path | batch dir]"
---

# foreman-to-tickets

Turns a spec, or the plan in the current conversation, into a **batch**: one file per
**tracer-bullet** ticket under `.scratch/<slug>/issues/`, each naming the tickets that
**block** it. Every **human ticket** is marked and gets a handoff file and a followup ticket,
so `foreman init` can take the batch as it stands. `foreman`'s glossary (`CONTEXT.md`) defines
batch, human ticket, handoff file and followup ticket. Read it if those terms are unfamiliar.

Adapted from Matt Pocock's `to-tickets` (MIT).

## Which way in

- **Slicing**: the argument is a spec path, or there is no argument and the plan is in the
  conversation. Start at step 1.
- **Topping up**: the argument is a batch directory, or the spec's batch already has tickets
  in `issues/`. Tell the user you are topping up an existing batch, then go straight to
  step 6. Existing tickets keep their numbers, because `order.md` and other tickets'
  `Blocked by:` lines name them.

## Label words

The human and agent labels are the right-hand column of `docs/agents/triage-labels.md` for
`ready-for-human` and `ready-for-agent`, when that file exists. Otherwise they are those two
strings, literally. A ticket's status line carries exactly one of them.

## Writing files

Every file this skill writes or edits is UTF-8. Write each `—` as that UTF-8 character, never
as the Windows-1252 byte 0x97, which is not valid UTF-8.

## Steps

### 1. Gather context

A spec path: read the whole spec. The batch is the directory it sits in. No argument: work
from the conversation, and ask the user for the batch's slug.

Done when you have the source and the batch directory `.scratch/<slug>/`.

### 2. Explore the codebase

Unless you already have, explore the code the work touches. Ticket titles and bodies use the
`CONTEXT.md` vocabulary and respect the ADRs in `docs/adr/` that touch the area. Look for
prefactoring that makes the work easier: make the change easy, then make the easy change.

### 3. Draft the slices

Break the work into **tracer-bullet** tickets:

- Each slice cuts a narrow but COMPLETE path through every layer it touches: vertical, never
  one layer on its own.
- A finished slice is demoable or verifiable on its own.
- Each slice fits a single fresh context window.
- Prefactoring comes first.

Give each ticket its blocking edges: the tickets that must finish before it can start.

**Wide refactors are the exception.** A wide refactor is one mechanical change (rename a
column, retype a shared symbol) whose blast radius breaks call sites across the codebase at
once, so no vertical slice can land green. Sequence it as expand–contract instead. Expand:
add the new form beside the old. Migrate: move call sites over in batches sized by blast
radius, each its own ticket blocked by the expand, green because the old form still exists.
Contract: delete the old form in a ticket blocked by every migrate batch.

**Human tickets.** The loop stops at every human ticket and runs nothing after it until a
person finishes it. So decide, for each slice, whether it is one:

- A slice is human when it needs something only a person has: an account or a secret, a
  physical device or this machine, a judgement or sign-off, or a try-out by hand. Every other
  slice is an agent's.
- A slice that mixes the two splits in two: a small human ticket, and an agent ticket for
  the rest.
- Human asks one person can do in one sitting merge into one human ticket, so the run stops
  once instead of twice, as long as its criteria still fit one handoff file.
- A human ticket's criteria are answers a person writes down, because each becomes a heading
  of its handoff file: "Where the token is stored (vault and item name)", not "Token
  created".
- Each human ticket `NN` gets a followup ticket `NNa` that checks the person's answers. A
  ticket that uses those answers is blocked by `NNa`, not `NN`, so it never builds on an
  answer nobody has checked.
- When the call is unclear, make the slice an agent's and flag it in step 4. Adding a stop is
  the user's choice.

Done when every slice has a title, its blockers, what it delivers, and a human-or-agent call.

### 4. Quiz the user

Show the breakdown as a numbered list in dependency order (blockers first). Each human ticket
carries `[HUMAN]` and its followup on an indented line under it:

```
3. Pick the hosting plan  [HUMAN]
   Blocked by: 2
   Delivers: the owner's choice of plan, and where its credentials live
   3a. Follow up on 3
4. Deploy to the chosen plan
   Blocked by: 3a
   Delivers: ...
```

Ask the user:

- Does the granularity feel right (too coarse, too fine)?
- Is each blocking edge real: does each ticket depend only on tickets that genuinely gate
  it?
- Should any tickets merge or split?
- Is each human call right? Name every slice you flagged as unclear in step 3.

Iterate until the user approves the list.

Done when the user has approved this exact list.

### 5. Write the tickets

One file per ticket at `.scratch/<slug>/issues/<NN>-<slug>.md`, numbered from `01` in the
approved order. Followup tickets get no file here; step 6 writes them. Use this template:

```
# <NN>: <Ticket title>

**Status:** <the agent label, or the human label for a human ticket>

**Blocked by:** <the numbers that gate it, e.g. `02, 03a`, or "None (can start immediately)">

**What to build:**

<the end-to-end behaviour this ticket makes work, from the user's point of view, not a
layer-by-layer implementation list>

- [ ] Acceptance criterion 1
- [ ] Acceptance criterion 2
```

Name behaviour, not files: file paths and code snippets go stale fast. The exception is a
prototype's snippet that encodes a decision more precisely than prose can (a state machine,
a schema, a type shape): inline its decision-rich part and note that it came from a
prototype.

Commit nothing yet: step 6 commits the whole batch in one commit.

Done when every ticket on the approved list is a file.

### 6. Add the human pieces

Read [`human-pieces.md`](human-pieces.md), beside this file, and follow it to the end. It
gives each human ticket its handoff file and followup ticket, commits, and tells the user
what to run next.
