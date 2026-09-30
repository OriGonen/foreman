# 02: Benchmark command times `ralph status` and counts its spawns

**What to build:** A developer measuring a performance change runs one command and gets
numbers they can paste into a ticket. The command builds its own batch of 3 tickets on the
`fake` adapter, times `ralph status` on it over a fixed number of runs (showing each run
and the median), then traces one `ralph status` call and breaks its spawns down by
command: external commands by name, plus a count of command substitutions and subshells.
It prints plain text, removes its fixture when it is done, and runs unchanged under Git
Bash and under WSL. It measures; it asserts nothing, and it is not part of the smoke suite.
See `spec.md` in this directory, "Benchmark command".

**Blocked by:** None within this feature. Start once `human-tickets` ticket 08 is
committed. It can be worked in parallel with 01.

**Status:** ready-for-agent

- [ ] One command, living beside the smoke suite, needs no setup and leaves no fixture behind (including when interrupted)
- [ ] It reports each timed `ralph status` run and the median; the number of runs has a sensible default and can be overridden
- [ ] It reports one call's spawns broken down by command, sorted by count, with a total
- [ ] Its fixture matches the smoke suite's 3-ticket fixture closely enough that its numbers compare with `report.md`
- [ ] It runs under WSL as well as Git Bash, verified by running it in both
- [ ] Its first Git Bash numbers are checked against a hand measurement and agree within reason; both are recorded in this ticket
- [ ] The suite's documentation of its test commands mentions it
- [ ] `bash test/smoke.sh` passes in full; the closing note records `Full smoke suite: N passed in Mm Ss`
