# 10: Smoke cases run in parallel

**What to build:** Run the smoke suite's cases concurrently, so the full suite finishes in
ten minutes or less under Git Bash. Per-case output is buffered and printed in case order
and whole, so the log reads the same as a serial run; each case's pass and fail counts are
written to a file under the run's work directory and summed at the end; concurrency is
capped. Pass and fail counts, the exit status, the case-name filter, `RALPH_KEEP_FIXTURES`
and the cleanup traps keep meaning what they mean today. See `spec.md` in this directory,
"Smoke suite harness", and user stories 30-32.

**Why this ticket exists:** ticket 04's last step compared the suite total with the spec's
ten minutes. After 05-09 and 04 the full suite is **484 passed in 12m 42s**, over by 2m 42s
(a 21% cut is needed). The library work and the template have landed; what is left is
`ralph` calls inside cases, which only running cases side by side will overlap.

**Blocked by:** 04.

**Status:** done

- [x] First step, before any change: the shared-state audit (user stories 30-32). List every piece of state two cases could both touch, and say for each how it is made safe or why it already is. At least: fixed paths under `$WORK` (log files such as `$WORK/ctx-prompts.txt`, and the install cases' `$WORK/<name>-home`, `-config`, `-bin`), the real home directory and `~/.claude`, the install targets, `RALPH_KEEP_FIXTURES`, the fake adapter's per-PID call counter in `$TMPDIR`, the template (read-only after the build), environment variables a case exports (`RALPH_FAKE_BEHAVIOUR` and the like), and anything a case does to the working directory or the repository `ralph` itself lives in
- [x] The audit's result is recorded here before the harness changes, with any case that cannot run alongside another named
- [x] Output is printed in case order, each case's lines whole, with the `[position/total] name` and elapsed-seconds lines as today
- [x] Pass and fail counts are per-case files under the run's work directory, summed at the end; the `N passed, M failed` line, the `N passed in Mm Ss` line, the slowest-cases list and the exit status mean exactly what they do today
- [x] Concurrency is capped, and the cap can be set (for example `RALPH_SMOKE_JOBS`); a cap of 1 gives the serial run
- [x] The case-name filter, `RALPH_KEEP_FIXTURES=1`, and the `INT`/`TERM`/`HUP` cleanup keep working; an interrupted parallel run leaves no fixture directory and no stray case process behind
- [x] No existing assertion is edited
- [x] The suite passes in full **several times in a row, in parallel** (spec, "Testing Decisions"), each with a fresh `TMPDIR`; the ticket records every run's total, and the closing note records `Full smoke suite: N passed in Mm Ss`
- [x] The last run's total is compared with ten minutes and the result stated here. If it is still over, say by how much and what the slowest cases are (the 04 run's slowest are `ralph run` cases of 18-34 s, which bound what parallelism can save)

**Evidence to start from (ticket 04's "after" run, 2026-10-01):** 91 cases, 484 assertions,
12m 42s serial. The ten slowest cases are 18-34 s each; the machine's core count and how Git
Bash process creation scales across cores are not yet measured, and the cap should be chosen
from that measurement rather than guessed.

## Comments

### Shared-state audit (2026-10-01, done before any harness change)

Method: the whole of `test/smoke.sh` read; `bin/`, `lib/`, `lib/exec/` and `install.sh` grepped for
`HOME`, `TMPDIR`, `/tmp`, `mktemp`, `$$`, `--global`, `sleep`, and for writes under `$RALPH_HOME`; every
path a case builds under `$WORK` extracted mechanically (130 occurrences of `make_repo`, `stalled_repo`,
`checked_repo`, `make_ralph_checkout`, `run_install` and literal `$WORK/...` names, grouped by case).

| State | Verdict | How it is made safe, or why it already is |
|---|---|---|
| Fixed paths under `$WORK`: repositories, `ctx-prompts.txt` and the other prompt logs, `<name>-checkout`, install `-home`/`-config`/`-bin`, `doctor-skill-*` | **already safe** | No name appears in two cases (checked mechanically). A name used twice inside one case (`run_install ... install-update`, twice) is the case's own re-run. The one loop (`rerun-mismatch-$field-*`) is inside one case. |
| `$WORK/claude-stub/claude` | **a real race** | `make_claude_stub` rewrites the same file (`cat >` truncates it) for four cases (`ralph order` x3, `ralph order warns`); a case could exec the stub while another's `cat` has it empty. Fixed: the stub directory is per case (`$WORK/claude-stub-<case number>`). |
| The real home directory and `~/.claude` | **already safe** | Cases that run `install.sh` go through `run_install`, or set `HOME` and `CLAUDE_CONFIG_DIR` themselves (`doctor-skill`), to per-case directories. The cases that run `ralph doctor` under the real home only read `~/.claude/skills`; nothing in `bin/` or `lib/` writes under `$HOME`. |
| Install targets (`--to`) | **already safe** | Always `$WORK/<name>-bin`, per case. |
| `RALPH_KEEP_FIXTURES` | **safe by construction** | Read only by the suite's own cleanup, which only the orchestrating process runs; a case's process never removes the work directory. |
| Fake adapter's call counter, `$TMPDIR/ralph-fake-$$.calls` | **safe, with a standing hazard removed** | Keyed on the loop's PID, and live processes have distinct PIDs, so two cases running at once cannot collide. The hazard (tickets 04 and 06) is a *recycled* PID finding an old counter in a long-used `$TMPDIR`. Fixed for good: each case runs with its own `TMPDIR` under `$WORK/.tmp/<case number>`, which starts empty and goes with the work directory. `mktemp` inside `ralph` (config LF check, verdict and payload files) lands there too. |
| The template | **safe** | Built once, before any case starts; read-only afterwards (`cp -R` out of it). |
| Variables a case exports | **safe** | `smoke.sh` has no `export`. `VAR=x run_ralph ...` assignments before a function call are scoped to that call. Each case now also runs in its own process, so nothing can leak to the next one; a case that relied on a leak would fail, and none did. |
| The working directory | **safe** | Every `cd` is inside a `$(...)` subshell; no case changes the main shell's directory. |
| The repository `ralph` lives in | **safe** | Read only: `source lib/...`, `git -C $RALPH_HOME rev-parse`, `cp -r` into a per-case checkout. Nothing in `bin/` or `lib/` writes under `$RALPH_HOME`. `rev-parse` takes no index lock. |
| Counters and scratch variables (`passed`, `failed`, `OUT`, `ST`, `CASE`) | **safe** | Per process, so per case. The counts become per-case files and are summed. |
| Git configuration | **safe** | Fixtures carry their own identity; no case runs `git config --global`. |
| Timing | **safe** | No case sleeps, polls or asserts on time, so load from parallel cases cannot change a verdict (it only makes cases slower). |

**Cases that cannot run alongside another: none.** The only change the audit asks of the cases' own
code is the per-case claude-stub directory; no assertion is touched.

**Measured, for the cap:** this machine has 8 logical cores. Process-creation throughput under Git
Bash (a scratch loop of `git --version; bash -c true`, 80 spawns per worker): 1 worker 20 spawns/s,
2 workers 27, 4 workers 46, 6 workers 53, 8 workers 64, 12 workers 50. It scales about 3.2x, not 8x,
and falls off past the core count, so the default cap is the core count and not more.

### What was built

`test/smoke.sh` is now a runner and a case process in one file. The runner (a person's `bash test/smoke.sh`) builds the template, reads the case names off the file's `if case_is "..."; then` lines (refusing duplicates, which a case process could not tell apart), and starts the file again once per selected case with `_SMOKE_CASE`, `_SMOKE_WORK` and `_SMOKE_IDX` set, at most `RALPH_SMOKE_JOBS` at a time (default: `NUMBER_OF_PROCESSORS`, else `nproc`, else 4; `wait -n` where bash has it, one at a time where it does not). A case process skips every `case_is` that is not its own, runs its case, writes `passed failed ms` to `$WORK/.results/N.counts` and leaves at the next `case_is`. Its stdout and stderr are one buffer file, `$WORK/.out/N`. The runner prints each case's `[n/total] name` header when the cases before it have been printed, then its buffer, whole, then sums the counts; the `.rc` file the runner writes when the process ends marks it over, and a case that ends with no counts file (it died, `exit`ed, or its name was not found) is one failure. The slowest-cases list, the two totals and the exit status are the code they were, fed from the files. Each case process has its own `TMPDIR` (`$WORK/.tmp/N`). Interrupts: the runner starts each case process in its own process group (`set -m`), so `INT`/`TERM`/`HUP` kill each group with everything it started, and removal of `$WORK` is retried (Windows keeps a directory busy while a process that had it as its working directory is dying), with a `KILL` after three tries.

**Differences from a serial run, stated:** a case's lines appear when it has finished, not as it runs (its header appears as soon as it is the next to be printed, so a hung case is named); a `FAIL` line, which a serial run sends to stderr, arrives with the rest of its case's output on stdout. The counts, the `N passed, M failed` and `N passed in Mm Ss` lines and the exit status are as before. `RALPH_SMOKE_JOBS=1` runs one case at a time through the same code, so there is one path, not a serial one and a parallel one.

**No assertion is edited.** The one change inside cases' own code is `make_claude_stub`, which now makes `$WORK/claude-stub-<case number>` instead of the shared `$WORK/claude-stub`.

### Checks of the harness

- Filter: `bash test/smoke.sh "human ticket at the head"` (1 case, 10 assertions), `install` (23 assertions) at `RALPH_SMOKE_JOBS` 1, 2 and 8: the same 23 passed each time. A filter that matches nothing: `0 passed, 0 failed`, exit 0, as before.
- Failures and deaths (a scratch copy of the suite with a deliberately failing assertion and a case that `exit 7`s, deleted afterwards): the failing case showed its `FAIL` line, the counts were `13 passed, 1 failed`, exit 1; the dying case reported `the case ended (exit status 7) without finishing`, one failure, exit 1.
- `RALPH_SMOKE_JOBS=abc`: a usage message, exit 2, no directory made. `RALPH_KEEP_FIXTURES=1`: the work directory is kept, with every case's directories in it.
- Interrupts: the full suite started, `TERM` sent to the runner after 25-30 s: exit 143, no `ralph-smoke-*` directory left, no stray `bash`, `git` or `node` process a few seconds later. The same with `HUP` (exit 129). (The first version removed the directory while case processes were still dying and left it behind with "Device or resource busy"; the retry in `cleanup` is the fix.) `INT` shares the handler; a `kill -INT` from a script cannot be tested, because a background process of a non-interactive shell ignores it.

### Runs (Git Bash, 8 logical cores, `RALPH_SMOKE_JOBS` unset = 8, each with a fresh `TMPDIR`, nothing else running)

Before the last edit (the final drain loop of the runner was bounded by the number of running cases; nothing else changed):

| run | result |
|---|---|
| 1 | 484 passed, 0 failed, 5m 50s |
| 2 | 484 passed, 0 failed, 6m 8s |
| 3 | 484 passed, 0 failed, 7m 55s |

On the final code:

| run | result |
|---|---|
| 1 | 484 passed, 0 failed, 5m 57s |
| 2 | 484 passed, 0 failed, 5m 32s |
| 3 | 484 passed, 0 failed, 5m 30s |

Every run exited 0, printed no `FAIL`, and left nothing in its `TMPDIR`. Against ticket 04's serial **12m 42s** the suite takes 5m 30s-5m 57s on the final code (7m 55s once, for the third run before the last edit, which was slower for a reason not found; it also passed), about 2.2x faster: the 3.2x process-creation scaling measured above, less the parts that do not overlap (the template build, the 18-34 s cases that are long by themselves).

### The last run against ten minutes

**Under.** The last run took 5m 30s, 4m 30s under the spec's ten minutes; the slowest of the six runs took 7m 55s, still 2m 5s under. The slowest cases of the last run were `a marker is removed once the tree is clean, and a salvaged stall leaves none` (111.9 s), `a marker that does not match the dirty tree is never trusted` (101.5 s), `a rerun whose rescue fails stops for a human and keeps the marker` (83.9 s), and `a human ticket is renamed only once its followup ticket has landed` (80.8 s). Those figures are a case's wall time with seven others running, not its serial time (18-34 s in 04's run), so they overstate the cases; they are the order in which the cases queue behind the machine. The spec's goal, the full suite in ten minutes or less under Git Bash, is met, and the `smoke-test-speed` effort is finished.

Full smoke suite: 484 passed in 5m 30s
