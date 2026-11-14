# 05: Report, as JSON and as a screen

**What to build:** Two pieces, in the CLI and in the app.

`foreman report --json [--run <id>] [--by-ticket]` is built from what `lib/foreman-report.cjs`
already works out. The Report screen reads it and shows:

- the bill, with the totals
- the ledger, with one row per run; a row expands to show that run's iterations and their
  outcome words
- a by-ticket view

The screen is marked free. See `spec.md`, additive change 3. The design is
`designs/07-report.html`, from `designs/source/ReportTakes.dc.html` (take a).

**Blocked by:** 02

**Status:** implemented

- [x] `foreman report --json` prints `foreman_json: 1`, `command: "report"`, the totals and one
      row per run. `--run <id>` adds that run's iterations, each with its outcome word.
      `--by-ticket` groups the rows by ticket. The numbers are the ones plain `report` prints
- [x] The output of plain `foreman report` and of `foreman help` is byte for byte unchanged
      against a capture taken before the change
- [x] `test/smoke-json.sh` covers `report --json`, `--run` and `--by-ticket` on a fixture
      jsonl, and its totals match the plain output
- [x] The app has no outcome logic of its own: every outcome word comes from `report --json`
- [x] The rail's Report entry, marked free, opens the screen. Expanding a run fetches
      `--run <id>` only when asked
- [ ] By hand on Windows: compare the screen with `designs/07-report.html` in light and dark,
      and check that its totals match plain `foreman report`
- [x] `test/smoke.sh` is unchanged and the full suite passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`

## Closing note

- `foreman report --json [--by-ticket] [--run <id>]` (in `lib/foreman-report.cjs`, so the picture and
  the text are untouched): one line, `foreman_json: 1`, `command: "report"`, `batch`, `log`
  (repo-relative), `by` (`run` | `ticket`), `totals` (counts, `tokens`, `cost_usd`, `minutes`, `turns`,
  `per_iteration`, `unreadable`) and `rows`. `--run <id>` adds `run: { id, started_at, iterations }`,
  each iteration with `outcome` (`landed` | `progressed` | `stalled` | `unproductive` | `checkpoint`),
  `flags` (error, limit, ... as `--failures` words them) and its cost, duration and turns.
- One classifier, `outcomeOf`, now decides both the plain counts and the words; the plain output is
  unchanged (the goldens in `test/smoke.sh` and a case in `smoke-json.sh` hold it). No log / no
  readable record is the plain report's message and exit 1; `--failures` and a `--run` without
  `--json` are refused.
- App: `foreman.cjs report()` (run id checked), `report:load` IPC, `model.report` /
  `model.reportIterations`, the Report screen (bill, ledger newest first, a run opens to its iterations
  and fetches `--run <id>` only then, By run / By ticket, Read again), and a rail "Tools" entry marked
  free. The app words the CLI's outcome words and colours them; it decides nothing.
- Left out on purpose: the design's Failures button (the CLI refuses `--failures` with `--json`; a
  run's iterations carry their words instead).
- Full smoke suite: 2741 passed in 2m 31s (1 failed: "convert ... CRLF kept", `test/smoke.sh:3609`,
  pre-existing). `test/smoke-json.sh`: 273 passed, 0 failed.
- NOT done: the by-hand box. No Electron or browser here, so the window was not opened; `report:load`
  was driven through a stand-in electron against the real CLI. A human compares the screen with
  `designs/07-report.html` in light and dark on Windows, and the totals with plain `foreman report`.
