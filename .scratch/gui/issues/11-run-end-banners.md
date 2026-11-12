# 11: How a run ended, as a banner on the run

**What to build:** When a run ends, a banner appears on top of the live run screen, which stays
where it was. There is one banner for each way a run can end:

- exit 0, done
- exit 10, paused (with the pause reason)
- exit 20, needs a human (with the `# reason:` line)
- exit 30, waiting on a human (with the human ticket)

Each banner offers its one next step, marked free or costs money. A failure before the run
starts (exit 1) shows the CLI's own text from `out`.

See `spec.md`, "Starting, watching and stopping a run" (End). The design is
`designs/05-run-end.html`, from `designs/source/EndTakes.dc.html` (take a).

**Blocked by:** 10

**Status:** ready-for-agent

- [ ] The app notices that a run ended when its pid is gone, and then re-reads `status --json`
- [ ] The banner is chosen from `last_run.end` and the exit code. The app has no end-state logic
      of its own beyond that mapping
- [ ] Each banner's next step:
  - exit 0: the report
  - exit 10: resume
  - exit 20: the reason, then open the ticket or the log. When the reason is `auth_failed`, it
    shows the login-expired state from ticket 07 instead
  - exit 30: open the human ticket
- [ ] Exit 1 shows `out` as text. `out` is kept until the next run that the app starts
- [ ] A batch that was renamed to `DONE_` as the run ended is found again, and its banner says
      done
- [ ] `node --test gui/test/` covers the mapping from fixture `status --json` and footers, for
      every exit code
- [ ] By hand on Windows, bring up each end state on a throwaway batch and compare it with
      `designs/05-run-end.html` in light and dark:
  - a 1-iteration budget, for exit 10
  - a human ticket next in the order, for exit 30
  - the fake exec's red flag, for exit 20
  - a batch that finishes, for exit 0
- [ ] Nothing under `bin/` or `lib/` changes in this ticket
- [ ] `test/smoke.sh` is unchanged and passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`
