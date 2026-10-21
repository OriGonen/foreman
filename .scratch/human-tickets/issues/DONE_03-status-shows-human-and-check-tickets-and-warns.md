# 03: Status shows human and check tickets, and warns about missing pieces

**Status:** done

**Blocked by:** 02

**What to build:**

`foreman status` should make it unmissable which tickets are for a person, and where the next
stop for a person is.

- Every remaining human ticket is marked `[HUMAN]` and every remaining check ticket
  `[CHECKS <name>]` in the "Remaining, in order" list.
- The progress line adds `· human tickets remaining: N` when there are any.
- When a human ticket remains but is not next: "The loop will run N ticket(s), then stop at
  <ticket> for a human."
- When the next ticket is human: the `Next:` line says so, and the human-ticket note from
  ticket 01 follows the list.
- `foreman dry-run`'s "Would run, in this order" list uses the same marked listing.

It also warns about a batch whose human tickets are missing their pieces. Warnings print last,
never change an exit code, and never stop a run:

1. a not-done human ticket with no ticket that `Checks:` it;
2. a not-done human ticket whose `Handoff:` line is missing or names a file that does not exist;
3. a not-done check ticket that is not immediately after the ticket it checks in the order —
   keyed on `Checks:` and order only, not on the checked ticket's status, since a human ticket
   set to `done` no longer matches the human pattern;
4. a `Checks:` line that names no ticket in the batch.

With the human word switched off, 1–2 are skipped and 3–4 still apply. A batch with no human
or check tickets prints exactly what `foreman status` prints today.

The warnings are one function in the human-ticket module, so ticket 04 can print the same ones
after ordering.

Full design: `.scratch/human-tickets/plan.md` — "Warnings" and the `status` mode part of the
`foreman-loop.sh` section.

**Acceptance criteria:**

- [x] With a human ticket third and its check ticket fourth, `status` marks them `[HUMAN]` and
      `[CHECKS 03-….md]`, shows `human tickets remaining: 1`, says it will run 2 tickets then
      stop at the human ticket, and prints no warning
- [x] With the human ticket next, the `Next:` line marks it and the note follows, naming the
      handoff file
- [x] Each of the four warnings appears in its own case, and `status` still exits 0
- [x] `dry-run` shows the same markings and warnings
- [x] The existing status case asserts no `[HUMAN]`, no `human tickets remaining` and no
      `warning:` — its output is unchanged
- [x] New smoke cases cover the above, and `bash test/smoke.sh` passes in full
