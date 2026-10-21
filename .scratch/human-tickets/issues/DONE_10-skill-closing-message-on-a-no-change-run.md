# 10: The skill's closing message is shorter when a run changed nothing

**Status:** done

**Blocked by:** None (can start immediately)

**What to build:**

Reported by the handoff for ticket 07 (problem 3, minor). When the `foreman-human-followup-tickets`
skill changes nothing (the second run in the trial), step 6 of `SKILL.md` still prints the
`Next:  foreman init <batch>` / `Then:  foreman status <batch> should show no warnings.` message, as
if there were more to do. That is what step 6 says ("the same way every time"), but it read as
noise: nothing was added, so no `foreman init` or `foreman order` is owed.

Change step 6 so that when nothing was written, the closing message says nothing was added and
that no foreman command is needed for this run; the `Next:` / `Then:` block is for a run that
wrote something. Keep the `foreman.conf` line owed by step 2, if any, in both cases.

**Acceptance criteria:**

- [x] `SKILL.md` step 6 gives a distinct, shorter closing message for a run that wrote nothing,
      with no `Next:` / `Then:` block
- [x] A run that wrote something keeps the existing `Next:` / `Then:` message unchanged
- [x] The `foreman.conf` line from step 2 is still appended in both cases
- [x] Any smoke assertion that covers the skill's text is updated, and `bash test/smoke.sh`
      passes in full

**Note:** the full `bash test/smoke.sh` run ended `495 passed, 0 failed` (6m 57s). No smoke assertion covers the skill text, so none changed. Step 6 now has a separate "Nothing was added" message for a run where step 3 wrote or edited nothing; the `foreman.conf` line is appended in both cases.
