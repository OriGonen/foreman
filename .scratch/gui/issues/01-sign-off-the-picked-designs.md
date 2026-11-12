# 01: Sign off the picked designs

**Status:** ready-for-human
**Handoff:** .scratch/gui/handoff/01-sign-off-the-picked-designs.md

**Blocked by:** None — can start immediately

**What to do:**

Each screen of the app was drawn two or three ways ("takes"), and one take was picked for each
screen. The picks are in the table in `spec.md`, "The picks". Each app ticket builds the pick for
its screen, so nothing gets built until you agree with them.

1. Open each pick page in a browser, from `designs/01-overview.html` through
   `designs/10-install-wizard.html`. Each page shows the picked take in dark and light.
2. If you're unsure about a pick, open its canvas in `designs/source/` (linked from the top of
   each pick page) to see the other takes.
3. For each screen, write in the handoff whether you agree with the pick. If you don't, say
   which take you want instead, or what to change.
4. Read the "Answers recorded" table in `spec.md`. Write down anything that isn't what you meant.

Why this is a human ticket: picking a design is a matter of taste, and it is the person who will
use the app who should decide.

**Acceptance criteria:**

- [ ] Each of the ten screens has a verdict: agree, another take, or a change
- [ ] Each change you ask for names the screen and says what should be different
- [ ] "Answers recorded" in `spec.md` is either confirmed or has each correction written down
