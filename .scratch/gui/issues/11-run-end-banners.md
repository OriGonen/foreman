# 11: How a run ended, as a scene

**What to build:** When a run ends, a scene replaces the live run's list, in the same window
(and the app leaves the compact view). Every scene is the terminal's sunrise from
`lib/foreman-draw.cjs`, as a silhouette:

- one big sun in flat bands sits on a low horizon, with its glint on the ground below
- the foreman stands in front of it as one flat dark shape, with no face, no colour and no detail.
  He is the terminal's own figure: the 18 × 25 half-block sprite from `foreman help`, drawn in
  square cells
- there is no confetti

The sun is the same in every scene, apart from its height. The foreman's pose and what stands
beside him say how the run ended:

- exit 0, done: the sun fully risen, the foreman with one arm raised, and a small flag on a
  stake along the horizon for each landed ticket
- exit 10, paused (with the pause reason): the sun held halfway, the foreman with a hand held up
- exit 20, needs a human (with the `# reason:` line): the sun a little lower than halfway, the foreman scratching his
  head beside a hand-lettered, leaning sign on his right that says "problem!"
- exit 30, waiting on a human (with the human ticket): the foreman shrugging beside a different
  sign on his left that says "need human inspection!". The sun is drawn exactly as in exit 10:
  same height, same bands, same colours

Each scene offers its next steps, marked free or costs money, and a **Show iterations** button
that brings the run's list back. A failure before the run starts (exit 1) shows the CLI's own text
from `out`.

See `spec.md`, "Starting, watching and stopping a run" (End). The design is
`designs/05-run-end.html`, from `designs/source/EndTakes.dc.html` (take b1, picked at the second
sign-off). The art is in `designs/source/canvas.js`: `endScene`, with `endSun`, `endGround`,
`figPixel` (the sprite and its four arm poses, `PX_BODY` and `PX_ARMS`), `endFigure` and
`endSign`. It goes into `gui/art.js`. The colours are the `--sun-*`, `--glow`, `--glint`,
`--night`, `--sil` and `--letter` tokens in `designs/source/gui.css`, in both themes.

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
- [ ] The scenes are flat silhouettes as in the design: the banded sun, the low horizon, and the
      pixel foreman (the terminal's sprite in square cells, `shape-rendering: crispEdges`) in one
      dark colour. No confetti, no face, no gradient on the figure
- [ ] Exit 30's sun is the same as exit 10's: same height, bands and colours
- [ ] The two signs are dark boards with hand-lettered SVG text in the sun's colour (Segoe Print,
      with `cursive` as the fallback), each leaning and not square to the floor, on opposite
      sides: "problem!" on the right for exit 20, "need human inspection!" on the left for exit 30
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
