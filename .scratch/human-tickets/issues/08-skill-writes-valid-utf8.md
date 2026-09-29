# 08: The followup-tickets skill writes valid UTF-8 and checks it

**Status:** ready-for-agent

**Blocked by:** None (can start immediately)

**What to build:**

Reported by the handoff for ticket 07 (`handoff/07-try-the-followup-skill-on-a-real-batch.md`,
problem 1). The `ralph-human-followup-tickets` skill wrote its em dashes as cp1252 bytes (0x97),
which is not valid UTF-8. On the first run the skill noticed, converted them and amended its
commit; on the third run it did not, and `handoff/08-legal-review-of-terms.md` and
`issues/08a-followup-legal-review-of-terms.md` in the test batch were committed (ec22280) with raw
0x97 bytes. Nothing in `skills/ralph-human-followup-tickets/SKILL.md` says to write UTF-8 or to
verify it, so whether a run catches it is luck.

Change `SKILL.md`: step 3 says every file it writes is UTF-8, and step 5 verifies that (every
file it wrote or edited decodes as valid UTF-8; fix any that does not) before the commit.

**Acceptance criteria:**

- [ ] `SKILL.md` step 3 says the files it writes are UTF-8 (the `—` in the handoff title and the
      followup ticket title in particular)
- [ ] `SKILL.md` step 5 checks that every file it wrote or edited is valid UTF-8, and fixes it,
      before committing, with a completion criterion that says so
- [ ] Any smoke assertion that covers the skill's text is updated, and `bash test/smoke.sh`
      passes in full
