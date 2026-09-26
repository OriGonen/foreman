# 05: Document human tickets, check tickets and handoff files

**Status:** ready-for-agent

**Blocked by:** 01, 02, 03, 04

**What to build:**

Tickets 01–04 built the behaviour; make sure someone reading the docs finds it, and that the
glossary names it. Describe what the code actually does now — read it, do not copy the plan.

- **The glossary** (`CONTEXT.md`) gains **Human ticket**, **Handoff file** and **Check
  ticket** under the things being worked on, and **Waiting on a human** as a way a run ends —
  distinct from a stop that *needs* a human (exit 20) and from a pause (exit 10). Each with its
  _Avoid_ list, in the file's existing style (`plan.md`'s "Docs" section has drafts).
- **The README**:
  - "Setting up a batch": a "Human tickets" subsection — the human- and check-ticket formats,
    the handoff file (including: record where a secret is stored, never its value), sending
    back, and the human → check → consume pattern, using an owner review split into a human
    ticket, its check ticket, and an agent ticket that applies the owner's feedback;
  - "Ordering": how `ralph order` places human tickets and keeps check tickets adjacent;
  - "Pausing and resuming": exit 30 — what it means, that rerunning stops again for free, how
    it differs from 10 and 20; the start-of-run rename, and why a human ticket is renamed only
    after its check ticket lands;
  - the quick-start comment on `ralph status`: what is left, what is next, where a human is
    needed.
- **The batch config template** documents `RALPH_HUMAN_WORD` and `RALPH_HUMAN_PATTERN`.
- **`ralph init`**'s generated `order.md` prose stops telling people to describe a human step
  in prose, and points at human tickets instead.

The planning skill that writes these tickets is a separate, later piece of work — do not
document it here.

**Acceptance criteria:**

- [ ] `CONTEXT.md` defines Human ticket, Handoff file, Check ticket and Waiting on a human,
      each with an _Avoid_ list
- [ ] The README covers the formats, handoff files, sending back, the pattern, ordering, exit
      30 and the rename, matching what the code does
- [ ] The config template documents both settings, and says an empty word turns the feature off
- [ ] `ralph init --no-order` on a fresh batch writes the new prose (an existing smoke case or a
      new assertion checks it)
- [ ] `bash test/smoke.sh` passes in full
