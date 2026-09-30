# 03: Baseline measurement, then write the spawn-reduction tickets

**What to build:** The effort gets a measured starting point, and its remaining tickets
come from those measurements rather than from the one trace in `report.md`. This ticket
changes no code. It takes the baseline on the untouched suite and libraries, records it
here, confirms (or refutes) that spawn cost is the cause, and then writes the
spawn-reduction tickets in order of measured payoff. See `spec.md` in this directory,
"Measurement comes first".

**Blocked by:** 01 (suite timing), 02 (benchmark command).

**Status:** done

Measurements, all recorded in this ticket under a `## Baseline` heading:

- [x] Full suite under Git Bash: total time, and the slowest cases with their times
- [x] Benchmark under Git Bash: `ralph status` timings and the spawn breakdown by command
- [x] Full suite and benchmark under WSL, run from a clone in the WSL filesystem (not under `/mnt/c`)
- [x] A one-line reading of the comparison: how much of the Git Bash time is spawn cost
- [x] Defender: the owner is asked whether one suite run may use a `TMPDIR` on a path they exclude from real-time scanning. If yes, that run's total is recorded against the normal one. If the difference is significant, the exact narrow exclusion (a dedicated fixture directory, never all of `%TEMP%`) is written here as a proposal. Nothing is applied by the agent
- [x] Whether the slowest cases are slow because of `ralph` calls or because of fixtures, as far as the timings show

Tickets, written from the measurements:

- [x] One ticket per library hotspot named in `spec.md` (ticket status checks, repository location, path helpers, name and string handling, config line-ending check), numbered from 05 in order of measured payoff. A hotspot the measurements show to be negligible is either dropped with a note here or folded into a neighbour
- [x] Each written ticket states its hotspot's share of the baseline spawns, requires a before and after from the benchmark, and carries the behaviour contract from `spec.md`: output may change, but every existing assertion passes with none edited
- [x] A statement here of whether a `parallel-cases` ticket will be needed, with the reasoning from the numbers. If it is clearly needed, it is written as the last ticket, blocked by every hotspot ticket, and opens with the shared-state audit
- [x] Ticket 04's before number is the Git Bash suite total recorded here

## Baseline

Taken 2026-09-30 on Windows 11, at HEAD `0b238c3` (clean tree), bash 5.2.26 under Git Bash,
WSL Ubuntu-22.04 (bash 5.1.16, 8 cores, node v24.19.0). Nothing else was run on the machine
during a timed run.

### Full suite, Git Bash

```
Full smoke suite: 466 passed in 38m 41s        (0 failed; per-case times sum to 2317 s)
```

The ten slowest cases:

| Time | Case |
|---|---|
| 127.6 s | a human ticket is renamed only once its followup ticket has landed |
| 102.2 s | a marker that does not match the dirty tree is never trusted |
| 85.4 s | the start-of-run sweep renames a finished ticket and leaves a dirty tree alone |
| 81.1 s | resuming picks up at the first ticket that has not landed |
| 77.6 s | the human word is configurable and can be switched off |
| 73.1 s | a marker is removed once the tree is clean, and a salvaged stall leaves none |
| 68.9 s | a followup ticket that sends its human ticket back ends the run at exit 30 |
| 65.3 s | a rerun whose rescue fails stops for a human and keeps the marker |
| 62.3 s | Checks: resolves whichever side carries the done prefix |
| 61.1 s | --unlimited runs the batch to completion |

All 87 cases: 24 under 10 s, 34 between 10 and 30 s, 19 between 30 and 60 s, 10 at 60 s or more.
The ten slowest are 11% of the cases and 35% of the time.

### Benchmark, Git Bash (`bash test/bench.sh 5`)

```
run 1: 13.41 s   run 2: 13.10 s   run 3: 13.27 s   run 4: 14.82 s   run 5: 15.43 s
median: 13.41 s
```

Spawns of one `ralph status batch` (533 events; identical under WSL):

```
  320  (subshells and command substitutions)
   56  grep        26  sed        21  git
   50  basename    23  dirname     7  bash
    6 each: cut, find, head, sort, tr
```

The spec's target for this number is 3 s or less.

### Where those spawns come from

The benchmark counts by command; to size the hotspots they had to be counted by the code that
starts them. One `status` call was traced with
`SHELLOPTS=xtrace BASH_XTRACEFD=9 PS4='+ ${BASHPID} ${BASH_SUBSHELL} ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main} '`
and every spawn event (each external command, each subshell) was put in one bucket by the
function that ran it. 532 events classified (the benchmark's 533, less one it counts
differently).

| Hotspot | Events | Share | Of which inside the config load |
|---|---|---|---|
| Name and string handling (`basename`, `dirname`, the status-line `sed`, and the subshells around them) | 188 | 35% | 100 |
| Ticket status checks (the done/human `grep`s, `ralph_ticket_field` pipelines) | 107 | 20% | 0 |
| Repository location (`git rev-parse` and the subshells around it) | 56 | 11% | 56 |
| Path helpers (`$(_ralph_path ...)`) | 42 | 8% | 42 |
| Config line-ending check (`grep -qU $'\r'`) | 7 | 1% | 7 |
| Everything else (the ticket-listing pipelines in `ralph-next.sh`, the 7 `bash` launches, the exec adapter) | 132 | 25% | 64 |

**What the trace found that the spec did not list.** `ralph status` runs `bash ralph-next.sh`
five times (`next_sh`) and once more through `_ralph_batch_tickets`, and each launch
re-sources `ralph-config.sh` from nothing. With the main script, that is **7 config loads in
one call, and 269 of the 532 events (50%) are the loads themselves**, about 38 per load. Six of the
seven are avoidable: about 230 events, 43%. The repository-location, path-helper and CRLF
hotspots are entirely inside that load; they are big only because it runs seven times.

### WSL (run from a clone at `~/ralph-wsl`, in the WSL filesystem)

```
Benchmark (Ubuntu-22.04, bash 5.1):  run 1-5: 0.50 0.50 0.58 0.45 0.43 s   median 0.50 s
Spawn table: identical to Git Bash, 533 events
Full smoke suite: 466 passed in 1m 56s        (0 failed; slowest case 5.0 s)
```

To run the suite there: `bin/ralph` is mode 100644 in the git index, so it is not executable in
a Linux clone, and the suite calls it directly. `chmod +x bin/ralph` in the clone (not in
this repository) was the only change. WSL had no `node`, which the suite's `run` cases need;
with the owner's permission node v24.19.0 (linux-x64 tarball from nodejs.org, matching the
Windows install) was unpacked into WSL `/tmp` and deleted afterwards. A backgrounded WSL
process is killed when the launching `wsl.exe` exits, so the suite ran with `wsl.exe`
held open.

### Reading

**Confirmed: about 95% of the Git Bash time is spawn cost.** The same code, issuing the same
533 spawns, takes 13.41 s per `status` under Git Bash and 0.50 s under WSL (27 times), and the
suite 38m 41s against 1m 56s (20 times). What is left under WSL, about two minutes, is the
floor for this suite's own work.

### Defender

The owner was asked whether one suite run may use a `TMPDIR` on a path they exclude from
real-time scanning, and declined. No run was made and nothing is proposed, because nothing
was measured. Nothing was changed on the machine. If the spawn-reduction tickets leave the
suite over its target, this is the question to ask again.

### Fixtures or `ralph` calls

**`ralph` calls, as far as the timings show.** One `make_repo 3` takes 0.65-0.80 s on this
machine now (three builds on an idle machine: 804, 647, 653 ms; `report.md` saw 2.5 s). The suite
builds 79 fixtures, so fixtures are about 55 s of 2,317, or **2%**. Even the slowest case has
at most three fixtures, under 3 s of its 127 s. The slow cases are the ones that start
`ralph run` several times or run it to completion over 2-3 tickets, and they are the same
cases that lead the WSL list (3-5 s there). One consequence for ticket 04 is under "Notes".

## Hotspot tickets, in order of measured payoff

| Ticket | Hotspot | Direct share of the baseline spawns |
|---|---|---|
| 05 | **Config and ticket list loaded once per command** (not in the spec's list; found by the trace) | about 230 events, 43%, avoidable |
| 06 | Ticket status checks | 107 events, 20% |
| 07 | Name and string handling | 188 events, 35%, but 100 of them fall with 05 |
| 08 | Repository location | 56 events, 11%, all in the config load, so about a seventh is left after 05 |
| 09 | Path helpers | 42 events, 8%, all in the config load, so about a seventh is left after 05 |

Ticket 07 has the largest direct share after 05 but is numbered behind 06 because 05 cuts
about half of it, so its payoff after 05 (88 events) is slightly below 06's (107). The order
is by payoff as it will be when each ticket is worked, and every later ticket takes its
"before" after the earlier ones have landed.

- **05 is added to the spec's five** because it is the largest payoff by a wide margin and the other hotspots cannot be judged without it. "Once per command, remembered" cannot be met inside one process if each question starts a new process.
- **08 and 09 open with a re-measurement** and close with a note, changing nothing, if 05 has taken them under 3% of the new total (expected: about 8 and 6 events, 2-3% of a total of about 300).
- **Dropped, with a note: the config line-ending check.** 7 events, 1% of the baseline, and all of them in the config load, so after 05 it is 1 event. It is not worth a ticket; if 05 lands as a single load it is already "once per command".
- **The spec's sixth bucket, "everything else" (25%),** has no ticket of its own. Most of it is the `ralph-next.sh` listing pipelines run six times over (`find`, `sort`, `cut`), which 05 removes by listing once. What remains after 05 will show in its after-table; a residual worth more than about 5% of the new total is a new ticket then.

### Is a `parallel-cases` ticket needed?

**Not clearly, so none is written; it is decided by ticket 04's last step** (04 is worked
last, by the owner's choice, so the final suite total is taken there). The effort's
target is 10 minutes against a baseline of 38m 41s, a factor of 3.9. The suite is 2,317 s of
which fixtures are about 55 s; the rest is `ralph` calls.

- If the `status` target (13.4 s to 3 s, 4.5 times) carries over to the whole suite, it comes to about 8.6 minutes, with ticket 04's fixtures at 10 s or so.
- If the gain is 3 times, it is about 12.8 minutes.

The benchmark times `status` only, and most of the suite's time is `ralph run`, which repeats
the same config load per iteration but has not been measured, so the two cases above cannot be
told apart yet. Both are close enough to ten minutes that a ticket written now would either be
needless or arrive without evidence. Parallelism also carries the flakiness risk the spec
wants taken only when needed (user story 30). Ticket 04's last step compares the suite total
from the final full run with ten minutes and, if over, writes `parallel-cases` as ticket 10,
blocked by 04, opening with the shared-state audit.

## Notes

- **Ticket 04's before number** is the Git Bash suite total above: **38m 41s** (466 passed). It is written into ticket 04 as the baseline; since 04 is now worked last, its own "before" is the suite total taken just before it starts. The time of one fixture build before is 0.65-0.80 s.
- **Ticket 04 is worth less than the spec assumed.** Fixtures are about 2% of the suite, not a large share; 04 will save perhaps 45 s of 38 minutes. It still earns its place for the clarity of the harness, and nothing above depends on it, but it is the lowest-payoff ticket and the owner chose to work it last, after 05-09.
- **`report.md` overstated some of its numbers for this machine today**: `make_repo 3` 0.7 s (not 2.5 s), `ralph status` 13.4 s (not 28-30 s). `report.md`'s figures came from a busier moment; the ones here are from an idle machine, same session, and are the ones to compare against.
- **The baseline run was interrupted by a crash of the desktop app** part-way through (the agent session died; the suite's own bash processes did not). The suite completed, its log is whole, and no other work ran on the machine. The figure is a single run.
- The trace script used for the classification is a scratch tool, not committed: it needs only the `PS4` above and a count by `file:function` of the first line each process ran. The benchmark's `BY_CMD` table is the repeatable measure; ticket 05's closing note should record its own before and after by the same method.

## Comments

**Closing note.** This ticket changes no code: it adds tickets 05-09, this record, and the
before number in ticket 04.

Full smoke suite: 466 passed in 38m 41s (measured, untouched HEAD `0b238c3`)
