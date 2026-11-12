# 11: How a run ended, as a scene

**What to build:** When a run ends, a scene replaces the live run's list, in the same window
(and the app leaves the compact view). There is one scene for each way a run can end:

- exit 0, done: a full sun, confetti, a flag on each landed stake, and the foreman giving a
  thumbs-up
- exit 10, paused (with the pause reason): the dome with the sun held halfway
- exit 20, needs a human (with the `# reason:` line): the foreman scratching his head beside a
  hand-written, leaning sign that says "problem!"
- exit 30, waiting on a human (with the human ticket): the foreman shrugging beside a different
  sign on the other side that says "need human inspection!", with the sun still coming up

Each scene offers its next steps, marked free or costs money, and a **Show iterations** button
that brings the run's list back. A failure before the run starts (exit 1) shows the CLI's own text
from `out`.

See `spec.md`, "Starting, watching and stopping a run" (End). The design is
`designs/05-run-end.html`, from `designs/source/EndTakes.dc.html` (take b, changed at sign-off
from a). The art is in `designs/source/canvas.js` (`scene`, `worker`, `sign`) and goes into
`gui/art.js`.

**Blocked by:** 10

**Status:** ready-for-agent

- [ ] The app notices that a run ended when its pid is gone, and then re-reads `status --json`
- [ ] The scene is chosen from `last_run.end` and the exit code. The app has no end-state logic
      of its own beyond that mapping
- [ ] Each scene's next steps:
  - exit 0: the report
  - exit 10: resume
  - exit 20: the reason, then open the ticket or the log. When the reason is `auth_failed`, it
    shows the login-expired state from ticket 07 instead
  - exit 30: open the human ticket
- [ ] Every scene has Show iterations, which brings back the run's list, and the compact view is
      left when the run ends
- [ ] The two signs are drawn by hand-lettered SVG text (Segoe Print, with `cursive` as the
      fallback), each leaning and not square to the floor, on opposite sides: "problem!" on the
      right for exit 20, "need human inspection!" on the left for exit 30. Exit 30 keeps the sun
- [ ] Exit 1 shows `out` as text. `out` is kept until the next run that the app starts
- [ ] A batch that was renamed to `DONE_` as the run ended is found again, and its scene says
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
