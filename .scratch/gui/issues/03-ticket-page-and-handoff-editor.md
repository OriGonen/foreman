# 03: The ticket page, and filling in a handoff

**What to build:** Clicking a ticket in the overview opens its page. The page shows:

- a facts strip: status, Blocked by, Checks, Handoff and spend;
- the ticket's text and criteria, with a **Preview | Markdown** switch over them. Preview is
  the default;
- the ticket's notes from `progress.txt`;
- for a human ticket, its handoff file, open in an editor beside the ticket;
- for a ticket that is done, its run stats: model, runtime, cost, iterations, turns and
  tokens, with each iteration and its outcome.

**Save** writes only the file named on the ticket's `Handoff:` line, and only inside the repo.
**Open in editor** opens the ticket in the person's own editor (`shell.openPath`), where they
can flip the status line. The app never flips a status line itself.

See `spec.md`, "What the app reads straight from disk" and "Secrets". The design is
`designs/02-ticket.html`, from `designs/source/TicketTakes.dc.html`: take b for a human ticket
(Preview), b2 for the Markdown view, b1 for an agent ticket that has not run, and b3 for a
finished ticket with its run stats. The stats come from `status --json` (ticket 16).

**Blocked by:** 02, 16

**Status:** implemented

- [x] The ticket page shows the facts strip, the text, the criteria and this ticket's notes from
      `progress.txt`. All of it is set as text and never parsed into HTML: a `<script>` in a
      ticket shows up as plain characters
- [x] A **Preview | Markdown** switch sits over the ticket text. Preview is the default.
      Markdown shows the file's own text in the mono font, and the notes and the handoff editor
      are the same in both
- [x] Preview draws only a heading, bold, inline code, bullets, check boxes and paragraphs, from
      a pure function that returns plain nodes, and the page builds them with `createElement` and
      `textContent`. There is no `innerHTML`, no link and no image
- [x] `node --test gui/test/` covers that function: a `<script>` or `<img onerror=…>` in the
      text comes out as text nodes, `[x](javascript:alert(1))` is not a link, `- [x]` is a ticked
      box and `- [ ]` an unticked one, a line that is not Markdown comes out as itself, and a
      ticket with no heading still renders
- [x] A human ticket shows its handoff file in an editor, with the reminder from "Secrets" above
      it
- [x] A ticket that is done and has run shows Run stats instead of "What the loop knows": cost,
      runtime, model, iterations, turns, tokens in and out, and one row per iteration with its
      run, outcome, duration and cost, all from `status --json`'s `stats`. A done ticket that never
      ran shows "none yet". A done human ticket shows its handoff and no stats
- [x] A ticket that is not done shows "What the loop knows" as in b1
- [x] Save writes only the path on the `Handoff:` line
- [x] Save refuses any path that resolves outside the repo, including through `..` or a symlink,
      and shows the refusal as text
- [x] Save keeps the file's line endings, and writes LF for a new file
- [x] Changes made on disk while the page is open show up on the page. If the file changed on
      disk while the editor has unsaved changes, Save asks before it overwrites
- [x] Open in editor opens the ticket file. The app has no control that changes a status line
- [x] `node --test gui/test/` covers the handoff path check: a `..` path, an absolute path, and a
      path outside the repo
- [ ] By hand on Windows: open a human ticket and an agent ticket from this repo, and compare
      them with `designs/02-ticket.html` (b, b1, b2 and b3) in light and dark, and flip the switch
      on both. Open a done agent ticket that has run. Fill in a handoff and
      save it. `git diff` shows only that file changed
- [x] Nothing under `bin/` or `lib/` changes in this ticket
- [x] `test/smoke.sh` is unchanged and passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`
