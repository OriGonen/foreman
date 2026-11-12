# 08: The control directory in the batch, `foreman keys`, `foreman stop`, and `# reason:`

**What to build:** These are the CLI changes that let something other than the run's own
terminal steer a run. Each one is additive:

- The control directory moves to `<batch>/.foreman-run/`, but only when `**/.foreman-run/` is
  ignored. It gains three new files: `pid`, `run` and `feed`.
- `foreman doctor`, `doctor --fix` and `foreman init` learn the ignore line, but only when the
  app is installed.
- `foreman keys <batch> <+|-|L>...` sends keys to the run.
- `foreman stop [<batch>]` stops the run. `--now` is ticket 09.
- After `# stopped: needs a human`, the run log gets a `# reason: …` line.

See `spec.md`, additive changes 5–9, and "Starting, watching and stopping a run". These changes
feed the live run's bar, designed in `designs/04-live-run.html`
(`designs/source/LiveRunTakes.dc.html`, take a).

**Blocked by:** 02

**Status:** ready-for-agent

**The control directory**

- [ ] When `git check-ignore` says `**/.foreman-run/` is ignored, the control directory is
      `<batch>/.foreman-run/`.
- [ ] Otherwise it is today's `mktemp -d`, and nothing else changes.
- [ ] Today's files (`budget`, `live`, `iteration`, `screen`, `activity`, `foot`, `spent`) keep
      their names and contents.
- [ ] `pid` holds the loop's MSYS pid and its Windows pid (`/proc/$$/winpid`).
- [ ] `run` holds the run id and its start time.
- [ ] `feed` holds the tool-call lines that `--live` shows. It is written only while live is on,
      and it is truncated at each iteration.
- [ ] On exit, the loop removes the directory, all of it except `out`. This happens before any
      `DONE_` rename, and on every exit path: 0, 1, 10, 20, 30 and INT.

**The ignore line**

- [ ] "The app is installed" means `gui/node_modules/electron` exists. That one check lives in
      one place in `lib/`.
- [ ] When the app is installed:
  - `foreman doctor` warns when the line is missing.
  - `doctor --fix` appends `**/.foreman-run/` to `.gitignore`.
  - `foreman init` writes it.
- [ ] When the app is not installed, the output of all three is byte for byte unchanged. Test
      this against a capture.

**`foreman keys`**

- [ ] `foreman keys <batch> +` raises the budget by one. A test checks this against a running
      loop on the fake exec.
- [ ] `-` and `L` do exactly what the keys do in the run's terminal, through
      `lib/foreman-keys.sh --apply`.
- [ ] It exits non-zero with a one-line message when there is no run in flight, or when the
      run's control directory is not in the batch.

**`foreman stop`**

- [ ] `foreman stop [<batch>]` sets the budget to the iteration in flight.
- [ ] The run finishes that iteration and ends with exit 10, "budget reached".
- [ ] A test checks this against the fake exec.

**`# reason:`**

- [ ] After `# stopped: needs a human` in `foreman-runs.log`, the loop writes `# reason: <the
      line the terminal printed>`.
- [ ] A test covers a red flag and an `auth_failed` stop.

**Everywhere**

- [ ] `foreman help` is byte for byte unchanged. Plain `run` output is unchanged; the golden
      run captures still match.
- [ ] `test/smoke-json.sh` covers every box above.
- [ ] `test/bench.sh` shows no added process on a plain run.
- [ ] `status --json` (ticket 02) fills in `run` (in flight, id, iteration, budget, live,
      control directory), and also `last_run.reason`.
- [ ] By hand on Windows, in Git Bash:
  1. Start `foreman run <batch> 3` in one terminal.
  2. From another, run `foreman keys <batch> +`. The first terminal's status bar shows 4.
  3. Run `foreman stop <batch>`. The run pauses after the current iteration.
- [ ] `test/smoke.sh` is unchanged and the full suite passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`.
