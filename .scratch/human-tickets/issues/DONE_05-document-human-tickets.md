# 05: Document human tickets, followup tickets and handoff files

**Status:** done

**Blocked by:** 01, 02, 03, 04

**What to build:**

Tickets 01–04 built the behaviour; make sure someone reading the docs finds it, and that the
glossary names it. Describe what the code actually does now — read it, do not copy the plan.

**The name is "followup ticket".** The plan and tickets 01–04 call the agent ticket that
follows a human ticket a *check ticket*. The owner renamed it **followup ticket** (one word,
everywhere) after those tickets were written, so the code they produced says "check ticket".
Rename the noun, and only the noun:

- in code comments (`foreman-human.sh`, `foreman-loop.sh`, `lib/exec/fake.sh`'s header and its
  `send-back` behaviour), smoke case names and test comments, and test helper names such as
  `make_check_ticket`;
- in `foreman order`'s prompt: the `CHECK TICKETS` section becomes `FOLLOWUP TICKETS`, and its
  smoke assertion follows;
- in everything this ticket writes.

The settled formats keep their spelling — they read as a verb ("a followup ticket `Checks:` its
human ticket"): the `**Checks:**` line, the `[CHECKS <name>]` marker in `foreman status`, the
`## Sent back by …` heading and the `check: send <NN> back — …` commit message. Shell function
and variable names (`foreman_checked_ticket`, `foreman_pending_checker`, …) may stay. Finished
ticket files and `.scratch/` keep their history.

The docs:

- **The glossary** (`CONTEXT.md`) gains **Human ticket**, **Handoff file** and **Followup
  ticket** under the things being worked on, and **Waiting on a human** as a way a run ends —
  distinct from a stop that *needs* a human (exit 20) and from a pause (exit 10). Each with its
  _Avoid_ list, in the file's existing style (`plan.md`'s "Docs" section has drafts). Followup
  ticket's _Avoid_ list includes check ticket, control ticket, review ticket and verification
  ticket.
- **The README**:
  - "Setting up a batch": a "Human tickets" subsection — the human- and followup-ticket
    formats, the handoff file (including: record where a secret is stored, never its value),
    sending back, and the human → followup → apply pattern, using an owner review split into a
    human ticket, its followup ticket, and an agent ticket that applies the owner's feedback;
  - "Ordering": how `foreman order` places human tickets and keeps followup tickets adjacent;
  - "Pausing and resuming": exit 30 — what it means, that rerunning stops again for free, how
    it differs from 10 and 20; the start-of-run rename, and why a human ticket is renamed only
    after its followup ticket lands;
  - the quick-start comment on `foreman status`: what is left, what is next, where a human is
    needed.
- **The batch config template** documents `FOREMAN_HUMAN_WORD` and `FOREMAN_HUMAN_PATTERN`.
- **`foreman init`**'s generated `order.md` prose stops telling people to describe a human step
  in prose, and points at human tickets instead.

The skill that writes followup tickets and handoff files is ticket 06 — do not document it
here.

**Acceptance criteria:**

- [x] `CONTEXT.md` defines Human ticket, Handoff file, Followup ticket and Waiting on a human,
      each with an _Avoid_ list; Followup ticket's includes check ticket
- [x] `grep -rni 'check ticket\|check-ticket\|CHECK TICKETS' lib test README.md CONTEXT.md`
      finds nothing but that _Avoid_ list
- [x] `**Checks:**`, `[CHECKS <name>]`, `## Sent back by` and `check: send <NN> back` are
      unchanged, and the smoke cases asserting them still pass
- [x] `foreman order`'s prompt has a `FOLLOWUP TICKETS` section, and the smoke case asserts it
- [x] The README covers the formats, handoff files, sending back, the pattern, ordering, exit
      30 and the rename, matching what the code does
- [x] The config template documents both settings, and says an empty word turns the feature off
- [x] `foreman init --no-order` on a fresh batch writes the new prose (an existing smoke case or a
      new assertion checks it)
- [x] `bash test/smoke.sh` passes in full
