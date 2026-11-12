# 15: Try the app on a real batch

**Status:** ready-for-human
**Handoff:** .scratch/gui/handoff/15-try-the-app-on-a-real-batch.md

**Blocked by:** 14

**What to do:**

Every screen has been checked against its design. What no agent can do is use the app for a
real run on your Windows machine, with your login, and judge whether it beats the terminal. So
you do that, and report back in the handoff file.

1. Run `git pull && bash install.sh`, and pick "CLI + desktop app". Open Foreman from the Start
   menu, then run `foreman gui` from a batch directory.
2. On a real batch with a few `ready-for-agent` tickets, set a low `FOREMAN_MAX_COST_USD` in its
   `foreman.conf`. Look at the overview, open a ticket, and do a dry run. Then start a
   2-iteration run from the app.
3. While the run is going:
   - press `+`, then `L`
   - close the app and reopen it
   - press Stop after this one
4. Start another run and use Stop now…. Then check `foreman status` in a terminal against what
   the app shows.
5. Open the report and doctor. If doctor offers a fix, press Fix what it can.
6. If the batch has a human ticket, fill in its handoff in the app.
7. Keep Task Manager open. Check that nothing of Foreman's is running once the app is closed and
   no run is in flight.

Why this is a human ticket: a real run costs money and needs your own login. Whether the app is
worth having next to the terminal is your call.

**Acceptance criteria:**

- [ ] The install, the Start-menu entry and `foreman gui` all work
- [ ] A run started from the app showed the bill first, steered with `+` / `L`, survived the app
      being closed and reopened, and stopped cleanly both ways
- [ ] Everything the app showed matched `foreman status` and `foreman-runs.log`
- [ ] Nothing of Foreman's runs once the app is closed and no run is in flight
- [ ] Everything that was wrong, unclear or slower than the terminal is written down, with the
      screen it concerns
