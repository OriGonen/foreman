# Report: why `test/smoke.sh` takes over an hour, and how to fix it

Status: findings and recommendations only. Nothing here has been implemented.
Measured on Windows 11 with Git Bash (MSYS2), 2026-09-30.

## Summary

The smoke suite now runs for over an hour. It used to take about 30-40 minutes.
The time is not spent in the tests' logic. It is spent creating processes.

- On this machine every process spawn costs 0.15-0.25s, against about 1ms on Linux.
- A single `ralph status` call on a 3-ticket repo takes about 30s. It does no work
  beyond reading a few files.
- The suite makes about 125 `run_ralph` calls and about 80 `make_repo` calls, so the
  per-call cost multiplies into an hour.
- Two things made it worse over time: the suite gained cases, and each `ralph` call
  got more expensive as features were added.

## Measurements

| Measurement | Result |
|---|---|
| `bash -c true` | 0.14s |
| `git --version` | 0.25s |
| `echo a \| grep a` | 0.19s |
| `git rev-parse HEAD`, 20 in a loop | 5.3s (about 0.26s each) |
| `make_repo 3` (fixture: init, config, commit) | 2.5s |
| `ralph status batch` on a 3-ticket repo | 28-30s |
| `bash test/smoke.sh "status and dry-run"` (1 case, 11 assertions) | 68s |

`ralph status` time was split roughly 9s user, 14s sys, 30s wall. The high `sys`
share points at process creation and file access, not computation.

### Where one `ralph status` call spends its spawns

A trace of one call (`SHELLOPTS=xtrace`) showed about 1,900 executed shell lines.
The external commands and subshells in it:

| Command | Count | Note |
|---|---|---|
| `grep` | 52 | per-ticket `grep -q` for the done word and human word on the status line, 6-12 times per ticket |
| `basename` | 46 | could be `${f##*/}` |
| `sed` | 12 (+6) | escaping a path for a pattern; trimming whitespace |
| `git rev-parse --show-toplevel` | 12 | same answer every time |
| `git rev-parse --show-prefix` | 6 | same answer every time |
| `grep -qU $'\r'` on `ralph.conf` | 6 | same file checked repeatedly |
| `_ralph_path` calls | 36 | helper that likely spawns inside `$(...)` |
| `cd` | 50 | cheap, but each often sits inside a `$(...)` subshell |

`$(...)` command substitutions are forks too, so the real spawn count is higher than
the external-command count. About 150 spawns at 0.2s each accounts for the 30s.

The same ticket file is checked for `implemented|done` 10-12 times, and for
`ready-for-human` 4-6 times, in one status call. The result is not cached between
checks.

## Why it got slower (30-40 min, now over 60)

Both factors grew together. From git history:

| Commit | `smoke.sh` lines | cases | `ralph-loop.sh` lines | all `lib/*.sh` lines |
|---|---|---|---|---|
| `67d2dae` (early Sep) | 601 | 36 | 665 | 2,613 |
| `6bfd498` | 954 | 49 | 1,037 | 3,150 |
| `f7738bd` | 1,193 | 64 | 1,148 | 3,342 |
| `0f44416` | 1,444 | 77 | 1,252 | 3,599 |
| `HEAD` | 1,668 | 87 | 1,252 | 3,681 |

- **More cases.** The suite went from 36 to 87 cases (2.4x). Each ticket adds cases and
  none are ever removed, so every ticket re-runs all earlier ones.
- **More work per call.** Each new feature (human tickets, followup tickets, ordering,
  status warnings) added per-ticket checks that run on every call, including the
  `ready-for-human` greps and the extra path handling. That raises the cost of every
  one of the 125 calls, not just the new cases.

The two effects multiply, which is why the run time grew faster than either number.
The suite will keep getting slower with every ticket unless this is addressed.

Other contributing factors, not measured here:
- Antivirus (Defender) scanning each new process and each fixture file in `%TEMP%`.
- 41+ fixture repos are created per run, each with `git init`, `config` x3, `add`,
  `commit`.
- Stale fixture directories from earlier aborted runs sit in `/tmp`
  (9 `ralph-smoke-*` directories, some from 2026-09-07). They are harmless but
  suggest runs are being interrupted or killed, which loses the whole run.

## Recommendations

Ordered by payoff per effort. Options 1 and 2 together are the recommended plan.

### 1. Reduce process spawns in the `ralph` libraries (highest payoff)

This speeds up the tests and real use on Windows. Specific changes:

- Replace `basename "$f"` with `${f##*/}` (46 spawns per status call).
- Read each ticket file once and derive every status check from that single read,
  with a `while read` loop or by capturing the file into a variable and matching with
  `[[ ... =~ ... ]]`. This replaces the repeated `grep -q` per ticket.
- Cache `git rev-parse --show-toplevel` and `--show-prefix` in variables on first use.
- Check `ralph.conf` for CR characters once per call, not 6 times.
- Avoid `$(_ralph_path ...)`-style helpers that spawn; have them set a variable instead
  (`_ralph_path_var out "$path"`).
- Replace the `sed` path-escaping with bash parameter expansion, or avoid the
  pattern altogether by comparing strings.

Expected effect: per-call cost drops from about 30s to a few seconds. This is an
estimate; it should be re-measured after the change.

Risk: behaviour must not change. The existing smoke cases are the safety net, so
this should be done as its own ticket with the full suite run before and after.

### 2. Run cases in parallel

Each case builds its own fixture repo under `$WORK`, so cases are independent.

- Run each `if case_is ...` block as a background job with `wait`.
- Buffer each case's output and print it in order when it finishes, so the log stays
  readable.
- The `passed` and `failed` counters are shell variables and would be lost across
  background subshells. Write each case's counts to a file under `$WORK` and sum them
  at the end.
- Cap concurrency (for example 4-8 jobs) to avoid thrashing.

Expected effect: 4-8x on a multi-core machine. It stacks with option 1.

Risk: any case that shares state (a fixed path, a fixed port, the real `$HOME`, a
shared `RALPH_KEEP_FIXTURES` directory) will become flaky. The install cases that
set `INSTALL_HOME` / `INSTALL_CONFIG` / `INSTALL_BIN` need checking first.

### 3. Run the suite where spawns are cheap

Run under WSL2 or in a Linux container. Spawns there cost about 1ms, so the suite
should drop from over an hour to a couple of minutes with no code changes. This is the
cheapest thing to try first and gives a baseline for how much of the time is
Windows-specific. Caveat: WSL must run the repo from its own filesystem
(`~/ralph`), not from `/mnt/c`, or file access is slow again.

### 4. Split into a fast tier and a full tier

- A fast tier that runs on every ticket, for example the cases related to the
  files the ticket touched, using the existing `bash test/smoke.sh <substring>` filter.
- The full suite runs before merge, on a schedule, or in CI.
- For a ticket like the current one (a wording change in `SKILL.md`, no assertion
  covers the skill text), the install and drift cases are enough.

This lowers the everyday cost immediately but does not fix the underlying slowness.

### 5. Reduce the cost of fixtures

- Build one template repo once, then copy it (`cp -r`) per case instead of running
  `git init`, `config` x3, `add` and `commit` each time. That is about 8 spawns per
  fixture saved, roughly 2s each on this machine.
- Set the git identity through environment variables
  (`GIT_AUTHOR_NAME`, `GIT_COMMITTER_NAME` and so on) instead of three `git config`
  calls.
- Put `$WORK` on a path excluded from Defender scanning, or on a RAM disk.

### 6. Housekeeping

- Add a timing line per case (start and end epoch, printed at the end) so the slowest
  cases are visible without profiling. Bash's `SECONDS` is enough.
- Clean up the stale `/tmp/ralph-smoke-*` directories, and make the `EXIT` trap robust
  to being killed.
- Print progress as cases run, so a long run does not look hung. During this
  investigation there was no way to tell a slow run from a stuck one.

## Suggested order

1. Try WSL (option 3) to confirm the diagnosis. If the suite drops to minutes there,
   the slowness is spawn cost, as measured here.
2. Add per-case timing (option 6) to find which cases dominate.
3. Do the spawn-reduction ticket (option 1) with a before and after measurement.
4. Parallelise (option 2) once the shared-state audit is done.
5. Add the fast tier (option 4) as a convention in the ticket workflow.

## Open questions

- Is this suite also run in CI on Linux? If so the hour is a local-Windows problem
  and option 3 or 4 matters most. If not, option 1 is worth more.
- Is Defender real-time scanning on `%TEMP%`? That would explain the large `sys` share.
  This was not verified.
- Which cases dominate? Only one case (`status and dry-run`, 68s for 11 assertions) was
  timed. The per-case distribution is unknown until timing is added.
