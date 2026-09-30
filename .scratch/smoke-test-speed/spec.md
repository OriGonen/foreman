# Spec — make `ralph` and its smoke suite fast under Git Bash

**Status:** ready-for-agent

Vocabulary: `CONTEXT.md`. Findings this spec is built on: `report.md` in this directory.

## Problem Statement

On Windows, `ralph` runs under Git Bash, where every process spawn costs 0.15-0.25s
(about 1ms on Linux). The `ralph` commands spawn freely: a single `ralph status` on a
3-ticket batch makes roughly 150 spawns and takes about 30s, while doing little more than
read a few files. The same ticket file is grepped for the done word 10-12 times and for the
human word 4-6 times in that one call; the repository root is asked of git 12 times, with
the same answer each time.

That cost lands twice. A person using `ralph status`, `ralph run --dry-run` or `ralph order`
on a real batch waits tens of seconds for what should be instant. And the smoke suite, which
drives `ralph` about 125 times and builds about 80 fixture repositories, now takes over an
hour — up from 30-40 minutes — because both the number of cases and the cost of each `ralph`
call have grown with every feature. Every ticket's acceptance criteria require the full
suite to pass, so every ticket pays that hour, and the suite gets slower with each ticket
that adds cases.

There is also no way to see where the time goes: the suite prints nothing while a case
runs, has no per-case timing, and cannot be told apart from a hung run. Aborted runs leave
their fixture directories behind.

## Solution

Two goals, the first leading:

1. **`ralph` itself spawns far less.** The hotspots in the libraries — repeated per-ticket
   greps, repeated git queries, path helpers that fork, `basename`/`sed` where parameter
   expansion does — are removed one mechanism at a time, each measured before and after.
   Target: `ralph status` on a 3-ticket batch in **3s or less** under Git Bash on the
   reference machine.
2. **The smoke suite is fast and legible.** It reports progress and per-case timing as it
   runs, builds its fixtures from a template instead of from scratch, and — only if still
   needed — runs cases in parallel. Target: the full suite in **10 minutes or less** under
   Git Bash on the reference machine.

A benchmark command makes both numbers reproducible, so every ticket in this effort
records a before and an after taken the same way. Git Bash stays the canonical platform:
"passes in full" means passes under Git Bash. WSL is used once, as a diagnostic, to confirm
that spawn cost is the cause.

## User Stories

1. As a ralph user on Windows, I want `ralph status` to answer in a few seconds, so that checking a batch is not a wait.
2. As a ralph user on Windows, I want `ralph run --dry-run` to be as quick as `status`, so that previewing a run costs nothing noticeable.
3. As a ralph user on Windows, I want `ralph order` to be quick, so that reordering a batch is interactive.
4. As a ralph user, I want the start of every `ralph run` to be quick, so that the loop's own overhead per iteration is small next to the turn it wraps.
5. As a ralph user, I want the speedups to change nothing about what a command decides — which ticket is next, whether it is a human ticket, whether it has landed, so that I can trust a faster `ralph` exactly as I trusted the slow one.
6. As a ralph user on Linux or macOS, I want the same changes to cost me nothing, so that a Windows fix is not a regression elsewhere.
7. As a ralph user whose batch has many tickets, I want the per-ticket cost to be small, so that `status` does not grow tens of seconds per extra ticket.
8. As a ralph user with a `ralph.conf` saved with CRLF endings, I want that still detected and reported, so that the one-time check is not lost in the speedup.
9. As a ralph user whose tickets have been renamed with the done prefix, I want them still found wherever `order.md` lists the old name, so that the speedup does not break resumption.
10. As a ralph user with a human ticket and its followup ticket in the batch, I want `status` to show and warn about them exactly as before, so that the human-ticket feature is untouched.
11. As a developer working a ticket, I want the full smoke suite to finish in ten minutes or less, so that "passes in full" is a check I run rather than a wait I dread.
12. As a developer, I want the suite to print each case as it starts and how long it took when it ends, so that a slow run is distinguishable from a hung one.
13. As a developer, I want a list of the slowest cases at the end of a run, so that I know where to look without profiling.
14. As a developer, I want the suite's total time printed at the end, so that I can record it in the ticket's closing note.
15. As a developer, I want the suite to clean up its fixtures when I interrupt it with Ctrl-C, or when it is terminated or its terminal closes, so that aborted runs stop littering the temp directory.
16. As a developer, I want the suite to keep honouring `RALPH_KEEP_FIXTURES=1`, so that I can still inspect a failing case's repository.
17. As a developer, I want the case-name filter (`bash test/smoke.sh <substring>`) to keep working, with progress and timing shown for the filtered cases, so that iterating on one area stays fast.
18. As a developer, I want the suite's pass/fail counts and exit status to mean exactly what they do today, so that nothing that reads them has to change.
19. As a developer, I want fixture repositories built by copying a template rather than by running git init, config and commit each time, so that fixtures stop being a large share of the run.
20. As a developer, I want a fixture built from the template to be indistinguishable to every case from one built from scratch — same files, same git identity, same line-ending settings, a fresh repository of its own, so that no case changes meaning.
21. As a developer, I want the suite to honour `TMPDIR`, so that its fixtures can be placed on a path excluded from antivirus scanning.
22. As a developer measuring a change, I want one command that times `ralph status` on a standard 3-ticket batch over several runs, so that before and after numbers are comparable.
23. As a developer measuring a change, I want that command to count the spawns of one `ralph status` call, broken down by command, so that I can see which hotspot a change removed.
24. As a developer measuring a change, I want the benchmark to build its own fixture and clean it up, so that it needs no setup and leaves nothing behind.
25. As a developer measuring a change, I want the benchmark to print plain numbers I can paste into a ticket, so that the ticket history records the trend.
26. As a developer, I want the benchmark to run under WSL as well as Git Bash, so that the one-off diagnostic compares like with like.
27. As a developer closing a ticket, I want the convention to be "Full smoke suite: N passed in Mm Ss", so that a slowdown shows up in ticket history without any flaky timing assertion.
28. As a developer, I want each spawn-reduction change in its own ticket, so that each one is reviewable on its own and a behaviour change is traceable to one mechanism.
29. As a developer, I want the spawn-reduction tickets ordered by the payoff the measurement found, so that the largest wins land first.
30. As a developer, I want parallel cases attempted only if the suite is still over ten minutes after the library work, so that the flakiness risk is taken only when needed.
31. As a developer, if parallel cases are attempted, I want an audit of state shared between cases (fixed paths, the real home directory, install targets, a kept-fixtures directory) to come first, so that parallelism does not introduce flaky cases.
32. As a developer, if cases run in parallel, I want their output printed in case order and whole, so that the log reads the same as a serial run.
33. As the owner of the machine, I want the cost of Defender's real-time scanning measured and reported, and any exclusion proposed to me rather than applied, so that security settings stay my decision.
34. As the owner of the machine, I want any proposed exclusion to be as narrow as a dedicated fixture directory, not all of `%TEMP%`, so that the exclusion does not weaken protection more than necessary.

## Implementation Decisions

**Behaviour contract for performance work.** A performance change may alter a command's
output (wording, spacing) but must pass every existing smoke assertion with no assertion
edited. A change that would need an assertion edited is not a performance change; it
belongs in its own ticket. What a command *decides* — ticket order, next ticket, landed or
not, human ticket or not, warnings raised — must not change.

**Where the library spawns go, and what replaces them:**

- *Ticket status checks.* Each ticket's status line is read once per command, and every
  question asked of it (is it the done word, is it the human word, which followup ticket
  does it name) is answered from that one read, with bash pattern matching rather than a
  `grep` per question. Where the same ticket is asked about repeatedly within one command,
  the answer is reused rather than recomputed.
- *Repository location.* The repository root and the batch's repo-relative prefix are
  asked of git once per command and remembered for the rest of it.
- *Path helpers.* Helpers that today return a path by printing it — and so are called
  inside a command substitution, which forks — instead set a named variable for the
  caller. Their callers change accordingly; what path they compute does not.
- *Name and string handling.* `basename` becomes `${var##*/}`; the `sed` used to escape a
  path for a pattern, or to trim whitespace, becomes parameter expansion or a plain string
  comparison.
- *Config line-ending check.* The CRLF check on `ralph.conf` runs once per command.

Each of these is one ticket. The order among them is set by the measurement ticket, not by
the list above.

**Smoke suite harness:**

- Each case prints a progress line when it starts (position, total, name) and its elapsed
  seconds when it ends. The run ends with the slowest cases and the total elapsed time.
  Timing uses bash's own clock, no extra processes.
- The cleanup trap covers `INT`, `TERM` and `HUP` as well as `EXIT`. (A hard kill cannot be
  trapped; that is accepted.)
- The suite does not clean up other runs' leftover directories at startup — it cannot know
  whether a concurrent run owns them.
- Fixtures are copied from a template repository built once per suite run. Fixture
  variation (ticket count, repository name) is applied after the copy. The template carries
  the same git identity, line-ending settings, ignore and attributes files as today.
- Parallel cases, if attempted: per-case output buffered and printed in order, per-case
  pass/fail counts written to files under the run's work directory and summed at the end,
  concurrency capped. Gated on the suite still exceeding ten minutes.

**Benchmark command:** a new script beside the smoke suite. It builds its own 3-ticket
batch on the `fake` adapter, times `ralph status` over a fixed number of runs (reporting
each and the median), traces one call to count spawns by command, prints plain text, and
removes its fixture. It asserts nothing and is not part of the suite. It runs unchanged
under Git Bash and WSL.

**Measurement comes first.** The first two tickets add the harness's timing and progress
and the benchmark; the third changes no code and takes the baseline: full suite under Git Bash, full suite under WSL
(repository cloned into the WSL filesystem, not under `/mnt/c`), the spawn breakdown of one
`ralph status`, and one suite run with `TMPDIR` on a Defender-excluded path if the owner
allows it for that one run. Its last step is to write the spawn-reduction tickets in order
of measured payoff and to state whether parallel cases are needed.

**Ticket convention.** Closing notes record "Full smoke suite: N passed in Mm Ss". This is
added to the issue-tracker conventions.

**Platform.** Git Bash is canonical. Nothing in this effort makes WSL or a Linux container
an alternative place for a ticket's "passes in full" check.

## Testing Decisions

- **Correctness has one seam: the existing smoke suite**, driving `bin/ralph` end to end
  through the `fake` adapter. The library changes are proven by every existing case passing
  with no assertion edited. No unit-level seams are added inside the libraries; the
  functions being changed are implementation, and testing them directly would pin the very
  shape this work is changing.
- A good test here asserts what a command decides and prints, never how many processes it
  took or how long. **No timing or spawn-count assertions** — they would be flaky on a loaded
  machine. Speed is tracked by the benchmark and by the time recorded in each ticket's
  closing note.
- The benchmark is a measuring instrument, not a test. It is verified by running it and
  checking that its numbers agree with a hand measurement on the first run.
- The harness changes (progress, timing, traps, template fixtures) are verified by running
  the full suite: same pass count as before, timing lines present, and — for the traps — an
  interrupted run leaving no fixture directory behind.
- Template fixtures are verified by the full suite passing unchanged: every case is a
  consumer of the fixture, so any difference that matters shows up as a failing case.
- If parallel cases are attempted, the suite must pass in full several times in a row, in
  parallel, before that ticket closes.
- Prior art: the suite's existing assertion helpers and fixture builder, the case-name
  filter, and `RALPH_KEEP_FIXTURES`.

## Out of Scope

- Changing any command's decisions or adding features. Output wording changes that need an
  assertion edited are separate tickets, requested on their own.
- Tiering the suite into fast and full runs, or relaxing "passes in full" in ticket criteria.
- Timing or spawn-count assertions.
- Running the suite in CI; there is none, and adding one is a separate decision.
- Making WSL or a Linux container a supported runner for the suite.
- Changing antivirus settings. The effort measures and proposes; the owner decides.
- Speeding up the agent's turns, the sandbox, or anything in `claude --print`.
- Removing or merging smoke cases to save time.
- Automatic cleanup of other runs' leftover fixture directories.

## Further Notes

- Measured on Windows 11, Git Bash (MSYS2), 2026-09-30: `bash -c true` 0.14s, `git
  --version` 0.25s, `make_repo 3` 2.5s, `ralph status` on 3 tickets 28-30s (9s user, 14s
  sys), one smoke case of 11 assertions 68s. See `report.md` for the full trace.
- Growth since early September: cases 36 → 87, library lines 2,613 → 3,681. The two
  multiply, which is why run time grew faster than either.
- The tickets are worked in interactive sessions, not by `ralph run`: a turn that must run
  an hour-long suite is exactly the kind of turn that stalls, and the first tickets exist
  to shorten that suite.
- Start after ticket 08 of `human-tickets` is committed, so the baseline is measured on a
  clean HEAD.
- Baseline (ticket 03, 2026-09-30): suite 38m 41s under Git Bash and 1m 56s under WSL; `ralph status` 13.4 s against 0.50 s. The trace found a hotspot the list above does not name: `status` sources the config 7 times, once per `ralph-next.sh` launch (50% of its spawns). It is ticket 05, and it shrinks the repository-location and path-helper hotspots to tickets that open with a re-measurement (08, 09). Fixtures are about 2% of the suite, not a large share; see ticket 03.
- Eight stale fixture directories from earlier aborted runs (2026-09-07 and 2026-09-27)
  were removed by hand when this spec was written.
