# 03: The ticket page, and filling in a handoff

**What to build:** Clicking a ticket in the overview opens its page. The page shows:

- a facts strip: status, Blocked by, Checks, Handoff and spend;
- the ticket's text and criteria, as plain text;
- the ticket's notes from `progress.txt`;
- for a human ticket, its handoff file, open in an editor beside the ticket.

**Save** writes only the file named on the ticket's `Handoff:` line, and only inside the repo.
**Open in editor** opens the ticket in the person's own editor (`shell.openPath`), where they
can flip the status line. The app never flips a status line itself.

See `spec.md`, "What the app reads straight from disk" and "Secrets". The design is
`designs/02-ticket.html`, from `designs/source/TicketTakes.dc.html`: take b for a human ticket,
take b1 for an agent ticket.

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] The ticket page shows the facts strip, the text, the criteria and this ticket's notes from
      `progress.txt`. All of it is set as text and never parsed into HTML: a `<script>` in a
      ticket shows up as plain characters
- [ ] A human ticket shows its handoff file in an editor, with the reminder from "Secrets" above
      it
- [ ] Save writes only the path on the `Handoff:` line
- [ ] Save refuses any path that resolves outside the repo, including through `..` or a symlink,
      and shows the refusal as text
- [ ] Save keeps the file's line endings, and writes LF for a new file
- [ ] Changes made on disk while the page is open show up on the page. If the file changed on
      disk while the editor has unsaved changes, Save asks before it overwrites
- [ ] Open in editor opens the ticket file. The app has no control that changes a status line
- [ ] `node --test gui/test/` covers the handoff path check: a `..` path, an absolute path, and a
      path outside the repo
- [ ] By hand on Windows: open a human ticket and an agent ticket from this repo, and compare
      them with `designs/02-ticket.html` (b and b1) in light and dark. Fill in a handoff and
      save it. `git diff` shows only that file changed
- [ ] Nothing under `bin/` or `lib/` changes in this ticket
- [ ] `test/smoke.sh` is unchanged and passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`
