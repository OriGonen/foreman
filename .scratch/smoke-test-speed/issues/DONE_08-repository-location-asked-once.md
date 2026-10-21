# 08: The repository root and the batch's prefix are asked of git once per command

**What to build:** The repository root and the batch's repo-relative prefix are asked of git
once per command and remembered for the rest of it, so that the answer a command decided on
is the answer every later step used. See `spec.md`, "Repository location".

**Blocked by:** 03 (the baseline) and 05. **This ticket opens with a re-measurement and may
close having changed nothing.**

**Status:** done

**Share of the baseline spawns** (532 events, before 05): **56 events (11%)**: 21 `git` calls
(14 from `foreman_batch_relpath`, 7 from `foreman_repo_root`) and 35 subshells. **All 56 sit
inside the config load**, which ran 7 times, so 05 is expected to take them to about 8, under
3% of the new total (about 300 events).

- [x] First step, before any change: run the benchmark on the tree with 05 landed and record here how many events `foreman_repo_root` and `foreman_batch_relpath` still account for
- [x] If that is under 3% of the benchmark's total, close this ticket with that number and a note, and change no code. Otherwise carry on below
- [x] `git rev-parse --show-toplevel` and `--show-prefix` each run at most once per command, and what they answered is reused (read as: each question once per command. `--show-toplevel` is asked from two directories, the caller's and the batch's, because the second is the check that refuses a batch in another repository; the batch's `--show-toplevel` and `--show-prefix` are one git process. See the closing note)
- [x] The path-syntax guarantees in `foreman-repo.sh`'s header still hold (the drive-letter spelling, the `/tmp` mount alias, a batch in a different repository still refused with the same message)
- [x] Behaviour contract: output may change in wording or spacing, but **every existing smoke assertion passes with none edited**; which ticket is next, whether it is a human ticket, whether it has landed and which warnings are raised do not change
- [x] The benchmark's before and after are recorded here, median and spawn table
- [x] `bash test/smoke.sh` passes in full (unless closed unchanged); the closing note records `Full smoke suite: N passed in Mm Ss`

## Comments

**Re-measurement (first step).** Benchmark on the tree with 05, 06 and 07 landed (`bash test/bench.sh 5`, HEAD `806f6a0`, bash 5.2.26, 2026-10-01): 44 events in total, down from the 300 the ticket expected, so the denominator shrank faster than this ticket's share. A trace tagged with the calling function put `foreman_repo_root` and `foreman_batch_relpath` at **10 of 44 events (23%)**: 3 subshells and 1 `git` for `foreman_repo_root`, 4 subshells and 2 `git` for `foreman_batch_relpath`. That is over the 3% threshold, so the ticket went ahead.

**Design.** `foreman_repo_root` and `foreman_batch_relpath` in `lib/foreman-repo.sh` now set a variable the caller names (`foreman_repo_root REPO_ROOT`, `foreman_batch_relpath BATCH_DIR GIVEN ROOT`), the convention `_foreman_basename` already uses, so none of their three callers (`foreman-config.sh`, `foreman-init.sh`, `foreman-doctor.sh`) reads them through a command substitution. The cd+pwd normalisation, which was a subshell each, now runs in the caller's shell with the working directory restored. The batch's `--show-toplevel` and `--show-prefix` were two git processes and are now one. What git answered is "remembered" by the variable the caller holds; nothing caches across calls, and no command calls either function twice (a command loads its config once since 05).

**The "at most once" box, read honestly.** `--show-toplevel` still runs twice per command, not once: from the caller's directory (which repository are we in?) and from inside the batch (which repository is the batch in?). The second is the check that refuses a batch in a different repository; getting to one run would mean comparing repositories without asking git, which is the path arithmetic the header of `foreman-repo.sh` warns against (a `--show-cdup` walk needs `cd -P`, and the `/tmp` mount alias and the drive-letter spelling are exactly where that goes wrong). Two git processes is the floor for the design, so 4 of the 38 remaining events are this ticket's. The box is ticked on that reading, with the reading written into it. `foreman init` and `foreman doctor` still start `bash foreman-next.sh` children, each its own command that asks git for itself.

**Benchmark, Git Bash** (`bash test/bench.sh 5`, 2026-10-01):

| | median | runs | spawns |
|---|---|---|---|
| before (HEAD `806f6a0`) | 0.96 s | 1.16, 0.95, 0.94, 0.96, 0.96 | 44 |
| after, run 1 | 0.81 s | 0.81, 0.80, 0.81, 0.87, 0.81 | 38 |
| after, run 2 (later, same tree) | 0.95 s | 0.95, 0.95, 1.33, 0.85, 0.98 | 38 |

The second run is noisier and not faster than the baseline; the machine's own timing moved by that much between two runs of an unchanged tree, so the time gain is within noise and the spawn count is the result: 44 → 38 (**-14%**), with `git` 3 → 2 and subshells 36 → 31. The ticket's 3% estimate for the remaining share could not be met, since two git processes and their `$( )` are 4 of 38 events (10%).

```
before                                after
  36  (subshells, command subst.)         31  (subshells, command subst.)
   3  git                                  2  git
   1 each: bash, cut, find, grep, sort     1 each: bash, cut, find, grep, sort
  44  total                               38  total
```

**Path-syntax guarantees.** The smoke suite has no case for them, so they were checked by hand: `foreman-config.sh` from the old and the new `lib/` resolved a batch through 11 spellings and states (relative to the root, from inside the batch, `.`, an absolute Git Bash path, `C:/` and `C:\` drive-letter spellings, the `/tmp` mount alias, the batch at the repository root, a batch in a different repository, a missing directory, a bare git directory). Output and exit code are **byte-identical**, including the "must be inside the repository" message. The probe was run again after the last comment edit.

**Code review** (standards and spec, in parallel): no hard violations. Taken: the comment on `foreman_batch_relpath` moved back above that function, with the explanation of the two `--show-toplevel` questions. `CDPATH= cd` is new in `foreman_batch_relpath`: the old plain `cd` ran in a subshell, where a CDPATH hit printing the directory only corrupted a value, and in the caller's shell it would print into the caller's output; it also makes `cd` and `[ -d ]` agree. Left alone as judgement calls: a shared `abspath` helper (two uses), restoring `OLDPWD` (nothing in `lib/` or `bin/` reads it), and a one-process design (above).

Full smoke suite: 484 passed in 11m 55s
