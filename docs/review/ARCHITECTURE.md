# Foreman architecture review

Source: the maps under `docs/review/map/` (stitched into `MAP.md`). File:line references are in those maps; this file holds the judgments.

## The shape today

Foreman is three layers that talk through files and text:

1. **Bash** (`bin/foreman`, `lib/*.sh`, `lib/exec/*.sh`) owns control flow: dispatch, config, the run loop, git, the executor adapters.
2. **Node helpers** (`lib/*.cjs`) own parsing and presentation: the agent's stream, the run record and verdict, `--json`, the drawn scenes.
3. **The Electron app** (`gui/`) is a separate client that shells out to `foreman --json` and watches the batch directory.

The layering itself is sound. The posture "node failure costs only the picture; bash falls back to plain text" is a good rule, and the fake executor that scripts ~25 agent behaviours is the project's best asset. The problems are at the seams between the layers and inside the loop.

## Where boundaries are wrong, shallow or leaky

### 1. The run loop is five programs in one flat script
`lib/foreman-loop.sh` (2194 lines) is top-level code, not functions. It contains argument parsing, status rendering, dry-run rendering, preflight, the start sweep, and the supervising loop. About 400 lines (L641–1084) are status and dry-run presentation, each written twice (facts for node, then plain text). The supervising loop body is one 582-line block (L1508–2089) with about 35 globals and about 14 `break`s, each of which sets `FINAL_STATUS` and `NEEDS_REASON` by hand.

Consequence: the decision "given this verdict and these counters, what happens next" cannot be called, so it cannot be tested except by running a whole fake run through the 8000-line smoke suite. Terminal-state blocks have been copied instead of shared (stranded ×3, discarded ×2, limit pause ×2, salvage bump ×2), and copies drift.

### 2. The control directory is an undocumented wire protocol with four implementations
`<batch>/.foreman-run/` (`budget`, `live`, `iteration`, `pid`, `feed`, `activity`, `stop`, `out`) is read or written by the loop, `foreman-keys.sh`, `foreman-control.sh`, `foreman-stream.cjs` and the GUI (`gui/live.cjs`, `gui/runner.cjs`). Its only definition is a prose header comment in `foreman-keys.sh`. There is no liveness field, so a hard-killed run leaves a `pid` file that every reader treats as "in flight". It also only exists in the batch when gitignored; otherwise it is a private temp dir that nothing outside can reach, which silently disables `stop` and the GUI's live view.

### 3. The verdict has two authors
`foreman-record.cjs` classifies a turn (limit, context, auth, transient, permission) and writes a key=value verdict file; the loop greps it ten times, then re-derives "stalled" and "progressed" itself. "Stall" has three definitions (record.cjs, the loop, CONTEXT.md). The recorder's `stalled`/`progressed` are telemetry only; `foreman-report.cjs` defines them a third time. A single turn outcome should be decided in one place and consumed everywhere.

### 4. The executor seam leaks in both directions
The adapter contract says adapters read only `FOREMAN_*` and `REPO_ROOT`. In practice they read `BUNDLE_FILE`, `RUN_CTL_DIR`, `STALL_MARKER_FILE`, `PROGRESS_FILE`, and return results through `EXEC_DIRTY`/`EXEC_AGENT_HEAD` globals. The loop in turn hardcodes `sandbox|sandbox-mount` (L1874). `foreman-order.sh` bypasses the seam completely with a raw `claude` call, so ordering ignores the sandbox and permission settings. `exec_run` runs inside a pipeline subshell, so adapters cannot keep state and the fake needs a PID-keyed temp file.

### 5. Config loading has side effects, so a second reader was written
`foreman-config.sh` changes the caller's directory and migrates (moves, deletes) legacy `ralph-*` files every time it is sourced. Because of that, doctor reads confs as text with its own batch discovery, and the GUI has four more regex readers. The readers disagree: doctor does not prune `DONE_` batches; the GUI takes the first match where the shell takes the last, and ignores the legacy prefix. The knob list is maintained by hand in four places and the template is missing six knobs.

### 6. Presentation constants and rules are copied across the bash/node/GUI line
Minimum widths live in `bin/foreman`, init, doctor and `foreman-draw.cjs`. The palette is regex-scraped out of `foreman-ui.sh` at runtime. Outcome words, exit codes 10/20/30, feed parsing and ticket-name regexes are re-implemented in `gui/` because the GUI never requires `lib/`. `parseFacts` exists twice. `foreman-report.cjs` and `foreman-convert.cjs` are top-level scripts, so `foreman-json.cjs` can reuse one function only through a `require.main` early-return hack.

### 7. The GUI main process has a shared mutable context and no liveness
`ctx` is a global set lazily by `if (!ctx) await setup()` in twelve handlers, with the same try/trusted/describe boilerplate copied about fifteen times. Callbacks capture the global, not the context they were created for. Nothing polls whether the recorded pid is alive.

## What makes it hard to test or extend

- **No unit seam in bash.** Every loop behaviour is tested end to end. Adding a regression test means adding to an 8000-line script (see `map/05-tests.md` for timing and isolation).
- **No supervision of a hung agent.** There is no timeout anywhere; "stall" means "exited cleanly with uncommitted work". The INT trap only sets a flag that bash runs after the foreground pipeline returns. This is a missing feature more than a bug, but it is the first thing an orchestrator needs, and the flat loop makes it awkward to add.
- **Adding a knob touches four hand-kept lists**; adding an executor mode touches the loop; adding a control file touches four readers.
- **Adding a terminal state** means finding every `break` and copying a block.

## The changes with the best payoff (value ÷ risk)

| # | Change | Value | Risk | Why this rank |
|---|--------|-------|------|---------------|
| 1 | **One `finish` path for terminal states in the loop.** Replace the hand-set `FINAL_STATUS`/`NEEDS_REASON` + `break` pairs and the duplicated stranded / discarded / limit-pause / salvage blocks with small functions called from each site. | High: removes the drift that bug-hunting keeps finding; makes every later loop change smaller. | Low: mechanical, fully covered by the fake-executor smoke suite. | Cheapest way to make the core safe to change. |
| 2 | **Move status and dry-run out of `foreman-loop.sh`** into `lib/foreman-status.sh` (pure move, sourced or exec'd from the same dispatch). | Medium-high: the loop file drops ~450 lines and the run path stops sharing globals with two read-only commands. | Low: no behaviour change; goldens cover the output. | Pure extraction with strong existing tests. |
| 3 | **Shared node module for the cross-boundary formats** (`lib/foreman-facts.cjs`: `parseFacts`, outcome/progressed/stalled rules, exit-code words, EPIPE-safe write) and turn report/convert into functions with a `main`. | Medium: one definition of "stalled"; removes the `require.main` hack; fixes the pipe crashes in one place; gives the GUI something to require later. | Low: node-only, builtins-only, unit-testable. | Small, and unblocks #5. |
| 4 | **Make config reading side-effect free and single-sourced.** Split `foreman-config.sh` into "resolve and validate" (no `cd`, no migration) and "prepare repo" (cd, legacy migration, run only by commands that mutate). Doctor and `--json` then use the real reader; one batch-discovery function. | High: removes a whole class of "doctor says X, run does Y", and lets the GUI drop its regex readers in favour of `foreman --json`. | Medium: every command sources config; ordering of side effects matters. | High value but touches every entry point; do after 1–3. |
| 5 | **Give the control directory an owner.** One bash file and one node file that define the file names and read/write them, plus a liveness rule (pid + start time, verified by readers). GUI and `stop` use it. | High: fixes stale "in flight", PID reuse, and makes a watchdog possible. | Medium: four writers/readers, Windows pid semantics. | Needed before any hang timeout; riskier because it crosses all three layers. |

Deliberately not ranked: turning the loop body into a pure `decide(verdict, counters)` function. It is the right end state, but it is only safe after #1 and #3, and it should be its own piece of work.

## Decisions that belong to the owner

- **Agent hang timeout.** Needs a new config knob (config format change) and a choice of default.
- **`foreman order` going through the executor.** Changes where ordering runs (sandbox vs host), which is user-visible.
- **Control directory when not gitignored.** Today it silently falls back to a temp dir; the alternatives (refuse, warn, or write under `.git/`) are all behaviour changes.
