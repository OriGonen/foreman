# 09: Path helpers set a variable instead of printing a path

**What to build:** `_foreman_path` returns a path by printing it, so each of its six callers
is a command substitution, which forks. Make it set a named variable for the caller instead,
and change the callers to match; what path it computes does not change. See `spec.md`, "Path
helpers". This is the last of the spawn-reduction tickets. The question the spec left for
the end of the library work, whether the suite still needs parallel cases, is settled by
ticket 04, which is worked after it.

**Blocked by:** 03 (the baseline), 05, 06, 07 and 08, so that it is worked last of the
spawn-reduction tickets. **This ticket opens with a re-measurement and may close having
changed nothing.**

**Status:** done

**Share of the baseline spawns** (532 events, before 05): **42 events (8%)**, all of them the
six `$(_foreman_path ...)` substitutions in `foreman-config.sh`, repeated by each of the 7 loads.
05 is expected to take them to about 6, about 2% of the new total (about 300 events).

- [x] First step, before any change: run the benchmark on the tree with 05 landed and record here how many events the `_foreman_path` substitutions still account for
- [x] If that is under 3% of the benchmark's total, close this ticket with that number and a note, and change no code. Otherwise carry on below
- [x] `_foreman_path` no longer runs in a command substitution at any of its call sites; the resolved paths (absolute as given, repo-relative if something is there, batch-relative otherwise) are unchanged for all three spellings
- [x] Behaviour contract: output may change in wording or spacing, but **every existing smoke assertion passes with none edited**; which ticket is next, whether it is a human ticket, whether it has landed and which warnings are raised do not change
- [x] The benchmark's before and after are recorded here, median and spawn table
- [x] `bash test/smoke.sh` passes in full (unless closed unchanged); the closing note records `Full smoke suite: N passed in Mm Ss`

## Comments

**Re-measurement (first step).** Benchmark on the tree with 05 to 08 landed (`bash test/bench.sh 5`, HEAD `fafac38`, bash 5.2.26, 2026-10-01): 38 events in total. A trace tagged with the calling function put the six `$(_foreman_path ...)` substitutions at **6 of 38 events (16%)**, all subshells: the function runs only builtins, so no external command is involved. That is over the 3% threshold, so the ticket went ahead.

**Design.** `_foreman_path` in `lib/foreman-config.sh` now sets a variable the caller names (`_foreman_path VAR GIVEN FALLBACK`), the convention `_foreman_basename` already uses, and its six callers are plain calls rather than command substitutions. Nothing else in `bin/` or `lib/` called it. Its locals are prefixed (`_rp_given`) so they cannot shadow the variable a caller names. The old function from HEAD and the new one were run side by side over 11 inputs (empty, bare name, repo-relative existing, repo-relative missing, absolute, `C:/` and `C:\` drive-letter spellings, names with spaces, `-n`, and two with glob characters) and answered identically for all of them.

**Benchmark, Git Bash** (`bash test/bench.sh 5`, 2026-10-01):

| | median | runs | spawns |
|---|---|---|---|
| before (HEAD `fafac38`) | 1.09 s | 1.20, 1.08, 1.09, 1.18, 0.93 | 38 |
| after | 0.86 s | 0.98, 0.86, 0.92, 0.80, 0.84 | 32 |

Timing on this machine moved by about this much between runs of an unchanged tree in ticket 08, so the time gain is within noise; the spawn count is the result: 38 -> 32 (**-16%**), subshells 31 -> 25, everything else unchanged.

```
before                                after
  31  (subshells, command subst.)         25  (subshells, command subst.)
   2  git                                  2  git
   1 each: bash, cut, find, grep, sort     1 each: bash, cut, find, grep, sort
  38  total                               32  total
```

**Code review** (`/code-review`, medium, on the diff): no findings.

**A failure that did not repeat.** The first full run of the suite on this change finished `480 passed, 4 failed`: all four were assertions in "a rerun salvages the stalled work its own previous run left behind" (the ticket's turn is told it is continuing, and so on). That case passed on its own (18 passed, 0 failed), and a second full run on the same tree passed in full. The cause of the one failing run was not found, and the same case was not run on the tree without this change, so it is not shown to be unrelated to it; it is recorded here rather than dropped.

Full smoke suite: 484 passed in 12m 32s
