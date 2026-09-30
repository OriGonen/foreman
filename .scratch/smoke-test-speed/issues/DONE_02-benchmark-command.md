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

**Status:** done

- [x] One command, living beside the smoke suite, needs no setup and leaves no fixture behind (including when interrupted)
- [x] It reports each timed `ralph status` run and the median; the number of runs has a sensible default and can be overridden
- [x] It reports one call's spawns broken down by command, sorted by count, with a total
- [x] Its fixture matches the smoke suite's 3-ticket fixture closely enough that its numbers compare with `report.md`
- [x] It runs under WSL as well as Git Bash, verified by running it in both
- [x] Its first Git Bash numbers are checked against a hand measurement and agree within reason; both are recorded in this ticket
- [x] The suite's documentation of its test commands mentions it
- [x] `bash test/smoke.sh` passes in full; the closing note records `Full smoke suite: N passed in Mm Ss`

## Comments

**Closing note.** New `test/bench.sh`; the README's file table and the header of `test/smoke.sh` mention it. No case body or assertion was edited.

`bash test/bench.sh [runs]` (default 5) builds a 3-ticket batch on the `fake` adapter, times `ralph status batch` (each run and the median), then traces one call with `SHELLOPTS=xtrace` and `BASH_XTRACEFD` and counts its spawns by command. Builtins and `ralph`'s own functions are not spawns. Subshells and command substitutions are one row. The fixture is a copy of `make_repo 3` and is removed on exit, `INT`, `TERM` and `HUP` (each checked by hand: no `ralph-bench-*` directory left).

**First numbers, Git Bash** (Windows 11, bash 5.2.26, 2026-09-30, machine noisy: 11-17 s between runs):

```
run 1: 12.15 s   run 2: 11.65 s   run 3: 12.76 s   run 4: 17.55 s   run 5: 17.28 s
median: 12.76 s
```

Hand measurement, `time bash bin/ralph status batch` in an identical fixture: 11.8, 11.1, 13.1 s before the benchmark and 13.5, 13.3, 15.9 s after. They agree with the benchmark's runs within the machine's own spread. (`report.md` saw 28-30 s on a busier moment; compare like with like, same session.)

**Spawns of one call** (identical under Git Bash, WSL Ubuntu-22.04 and WSL Ubuntu-18.04): 533 in all: 320 subshells/command substitutions, 56 `grep`, 50 `basename`, 26 `sed`, 23 `dirname`, 21 `git`, 7 `bash`, 6 each of `cut`, `find`, `head`, `sort`, `tr`. This total is not comparable to `report.md`'s "about 150": it counts every event, and an external command inside a subshell counts in both rows. Compare the benchmark with itself, before and after.

**WSL**, from a clone in the WSL filesystem (`/tmp`), 3 runs each: Ubuntu-22.04 (bash 5.1) median 0.36 s; Ubuntu-18.04 (bash 4.4) median 0.38 s. Both trace to the same spawn table.

For ticket 03 and 04:
- `bin/ralph` is mode 100644 in the git index, so it is not executable in a Linux clone: `test/smoke.sh` calls it directly and would fail under WSL until that is fixed. `bench.sh` runs `bash bin/ralph` and is unaffected.
- `bench.sh` copies `make_repo`'s recipe, with a comment to keep them in step. Nothing enforces it, so ticket 04, which rewrites `make_repo`, should point `bench.sh` at the new template too, or the two will drift.
- Known limits: no warm-up run (the first run includes cold-cache cost and is shown); a subshell that runs no traced command is not seen, so the spawn count is a floor.

The code review (standards and spec) found nothing blocking; its two actionable points are the drift note and the total's comparability, both above.

Full smoke suite: 466 passed in 30m 11s
