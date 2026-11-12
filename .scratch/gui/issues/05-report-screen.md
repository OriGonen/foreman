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

**Status:** ready-for-agent

- [ ] `foreman report --json` prints `foreman_json: 1`, `command: "report"`, the totals and one
      row per run. `--run <id>` adds that run's iterations, each with its outcome word.
      `--by-ticket` groups the rows by ticket. The numbers are the ones plain `report` prints
- [ ] The output of plain `foreman report` and of `foreman help` is byte for byte unchanged
      against a capture taken before the change
- [ ] `test/smoke-json.sh` covers `report --json`, `--run` and `--by-ticket` on a fixture
      jsonl, and its totals match the plain output
- [ ] The app has no outcome logic of its own: every outcome word comes from `report --json`
- [ ] The rail's Report entry, marked free, opens the screen. Expanding a run fetches
      `--run <id>` only when asked
- [ ] By hand on Windows: compare the screen with `designs/07-report.html` in light and dark,
      and check that its totals match plain `foreman report`
- [ ] `test/smoke.sh` is unchanged and the full suite passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`
