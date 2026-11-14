# 04: Dry run, as JSON and as a screen

**What to build:** `foreman dry-run --json`, and a Dry run screen that reads it. The left side of
the screen shows:

- what would run: the ticket, and how far the budget reaches before a human ticket;
- the settings that `dry-run` prints.

The right side shows the exact prompt, with line numbers.

Mark the screen as free. See `spec.md`, additive change 2. The design is
`designs/06-dry-run.html`, from `designs/source/DryRunTakes.dc.html` (take a).

**Blocked by:** 02

**Status:** implemented

- [x] `foreman dry-run --json` prints one JSON object with:
  - `foreman_json: 1`
  - `command: "dry-run"`
  - what would run
  - the settings
  - the prompt
- [x] Nothing is sent and no sandbox starts. A test asserts that the fake exec is never called
- [x] Plain `foreman dry-run` and `foreman help` output is byte for byte unchanged, compared
      against a capture taken before the change
- [x] `test/smoke-json.sh` covers `dry-run --json`, and checks that its facts match the plain
      output
- [x] `test/bench.sh` shows that plain `foreman dry-run` starts no new process
- [x] The overview's Dry run action opens the screen and is marked free. The prompt is shown as
      text in a `<pre>`, with line numbers
- [ ] By hand on Windows:
  - compare the screen with `designs/06-dry-run.html`, in light and in dark
  - check that the prompt matches plain `foreman dry-run` for the same batch
- [ ] `test/smoke.sh` is unchanged and the full suite passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`

## Closing note

- `foreman dry-run --json` (and `dry-run <batch> --json`): one object on one line, `foreman_json: 1`,
  `command: "dry-run"`, `repo_root`, `batch`, `counts`, `would_run` (`tickets` the iteration budget
  reaches before a human ticket, `remaining` every ticket still to do with its state `run` / `stop` /
  `later`, `stops_at` the human ticket with `reached`), `settings` (exec, perms, model, effort, live,
  budgets as numbers plus the plain words, logs), `warnings` and `prompt` (`for`, `text`, `lines`;
  `null` when a human ticket is next or nothing is left). The prompt travels as one escaped line so it
  arrives byte for byte, blank lines and CRs included. `--json --all` and `run --json` are still refused.
- Nothing is sent: a smoke case sets `FOREMAN_FAKE_PROMPT_LOG`, runs `dry-run --json`, and finds neither
  the log nor the fake's call counter; the same case ends with a real `run` as a control that does reach it.
- Plain output: `foreman help` is unchanged (`test/golden/help.txt`), and plain `foreman dry-run` is byte
  for byte what the tree from before this ticket prints (`test/golden/dry-run-plain.txt`, taken before the
  change; the commit hash and temp path are placeholders).
- `test/bench.sh dry-run` is new. Plain `foreman dry-run batch` has the same spawns before and after: 116
  subshells and command substitutions, 182 in all by the script's count. A shim `node` also shows plain
  `dry-run` starts none and `--json` starts one.
- The screen follows take a: would-run and settings on the left, the prompt on the right in a `<pre>` (one text
  node, exactly the CLI's text) beside a second, unselectable `<pre>` of line numbers. The overview's Dry run
  button is enabled and marked free; so is the screen. `Start run…` is drawn, marked costs money, disabled
  until ticket 10. Back, Run again, the rail, the watcher and a late answer are handled and tested.
- `bash test/smoke-json.sh`: 191 passed. `node --test` in `gui/`: 113 passed.
- Full smoke suite: 2741 passed in 2m 10s, 1 failed: "convert ... CRLF kept" (`test/smoke.sh:3609`),
  pre-existing (it failed the same way before ticket 02), `test/smoke.sh` is not edited, so that box stays
  unchecked. `ui_color_tier` flaked once in one of three full runs (a pty row empty) and passed alone three times.
- **Not done here, and needs a person on Windows:** the by-hand check. There is no Electron or browser in
  the sandbox, so the screen has not been opened and not compared with `designs/06-dry-run.html`. What is
  checked instead: `app.js` against the fake DOM, and `main.cjs`'s `dryrun:load` driven through a stand-in
  `electron` module against the real CLI (it returns the object; refuses `../x` and an untrusted sender).
  Run `npm start -- <repo>` in `gui/`, open Dry run, compare in light and dark, and compare the prompt
  with plain `foreman dry-run` for the same batch.
- Not in the design's screen: the Copy button (the ticket does not list it, and it needs a clipboard API
  through main). The prompt is selectable text, so copying works by hand.
