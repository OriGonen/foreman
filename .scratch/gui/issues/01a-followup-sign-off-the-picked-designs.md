# 01a: Follow up on 01 — Sign off the picked designs

**Status:** done

**Blocked by:** 01

**Checks:** 01-sign-off-the-picked-designs.md

**What to build:**

In ticket 01 the user reviewed the picked designs. Their answers are in
`.scratch/gui/handoff/01-sign-off-the-picked-designs.md`. Read that handoff and ticket 01, and
decide whether the handoff is complete. You are not judging the designs.

When the handoff asks for another take or a change, apply it:

- in `designs/source/*.dc.html` and `gui.css`, keeping the `designs/source/` pattern;
- in the affected pick page, regenerated so it still holds only the picked take or takes,
  inlined;
- in `spec.md`, in the picks table and "Answers recorded";
- in the ticket for each affected screen.

If a correction changes the scope, for example a new screen or a new CLI change, write it up as
a new ticket in `.scratch/gui/issues/`. Number it after the last ticket and give it
`**Status:** ready-for-agent`. Change no code under `bin/`, `lib/`, `test/` or `gui/`.

**If the handoff falls short:** do no other work. Set ticket 01's status line back to
`**Status:** ready-for-human`. Append a section to ticket 01, headed exactly
`## Sent back by 01a-followup-sign-off-the-picked-designs.md`, that says what is missing. Leave
this ticket's status line as it is. Commit with the message
`check: send 01 back — <what is missing>`.

**If it passes:** apply the changes, tick this ticket's boxes, set its status line to done, and
commit.

**Acceptance criteria:**

- [x] Every section of the handoff is answered. No section is left as its placeholder, empty,
      or "TBD"
- [x] For every screen where the handoff asks for another take or a change, the pick page, the
      `spec.md` picks table and the design pointer in that screen's ticket all match the new
      choice
- [x] Every correction to "Answers recorded" is made in `spec.md` and in the tickets it affects
- [x] The handoff contains no secret value
- [x] Nothing under `bin/`, `lib/` or `test/` changed (`git status`)
