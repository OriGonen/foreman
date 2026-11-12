# 04: Dry run, as JSON and as a screen

**What to build:** `foreman dry-run --json`, and a Dry run screen that reads it. The left side of
the screen shows:

- what would run: the ticket, and how far the budget reaches before a human ticket;
- the settings that `dry-run` prints.

The right side shows the exact prompt, with line numbers.

Mark the screen as free. See `spec.md`, additive change 2. The design is
`designs/06-dry-run.html`, from `designs/source/DryRunTakes.dc.html` (take a).

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] `foreman dry-run --json` prints one JSON object with:
  - `foreman_json: 1`
  - `command: "dry-run"`
  - what would run
  - the settings
  - the prompt
- [ ] Nothing is sent and no sandbox starts. A test asserts that the fake exec is never called
- [ ] Plain `foreman dry-run` and `foreman help` output is byte for byte unchanged, compared
      against a capture taken before the change
- [ ] `test/smoke-json.sh` covers `dry-run --json`, and checks that its facts match the plain
      output
- [ ] `test/bench.sh` shows that plain `foreman dry-run` starts no new process
- [ ] The overview's Dry run action opens the screen and is marked free. The prompt is shown as
      text in a `<pre>`, with line numbers
- [ ] By hand on Windows:
  - compare the screen with `designs/06-dry-run.html`, in light and in dark
  - check that the prompt matches plain `foreman dry-run` for the same batch
- [ ] `test/smoke.sh` is unchanged and the full suite passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`
