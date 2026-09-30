# 03: Baseline measurement, then write the spawn-reduction tickets

**What to build:** The effort gets a measured starting point, and its remaining tickets
come from those measurements rather than from the one trace in `report.md`. This ticket
changes no code. It takes the baseline on the untouched suite and libraries, records it
here, confirms (or refutes) that spawn cost is the cause, and then writes the
spawn-reduction tickets in order of measured payoff. See `spec.md` in this directory,
"Measurement comes first".

**Blocked by:** 01 (suite timing), 02 (benchmark command).

**Status:** ready-for-agent

Measurements, all recorded in this ticket under a `## Baseline` heading:

- [ ] Full suite under Git Bash: total time, and the slowest cases with their times
- [ ] Benchmark under Git Bash: `ralph status` timings and the spawn breakdown by command
- [ ] Full suite and benchmark under WSL, run from a clone in the WSL filesystem (not under `/mnt/c`)
- [ ] A one-line reading of the comparison: how much of the Git Bash time is spawn cost
- [ ] Defender: the owner is asked whether one suite run may use a `TMPDIR` on a path they exclude from real-time scanning. If yes, that run's total is recorded against the normal one. If the difference is significant, the exact narrow exclusion (a dedicated fixture directory, never all of `%TEMP%`) is written here as a proposal. Nothing is applied by the agent
- [ ] Whether the slowest cases are slow because of `ralph` calls or because of fixtures, as far as the timings show

Tickets, written from the measurements:

- [ ] One ticket per library hotspot named in `spec.md` (ticket status checks, repository location, path helpers, name and string handling, config line-ending check), numbered from 05 in order of measured payoff. A hotspot the measurements show to be negligible is either dropped with a note here or folded into a neighbour
- [ ] Each written ticket states its hotspot's share of the baseline spawns, requires a before and after from the benchmark, and carries the behaviour contract from `spec.md`: output may change, but every existing assertion passes with none edited
- [ ] A statement here of whether a `parallel-cases` ticket will be needed, with the reasoning from the numbers. If it is clearly needed, it is written as the last ticket, blocked by every hotspot ticket, and opens with the shared-state audit
- [ ] Ticket 04's before number is the Git Bash suite total recorded here
