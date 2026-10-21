# 07: File names and pattern escaping are handled by the shell, not by `basename`, `dirname` and `sed`

**What to build:** `basename "$x"` becomes `${x##*/}`, `dirname "$x"` becomes `${x%/*}` (with
the same answer when there is no slash), and the `sed` that escapes the status line for a
pattern is replaced by parameter expansion or a plain string comparison. Each of these is a
process, and each sits inside a `$(...)`, which is a second one. See `spec.md`, "Name and
string handling".

**Blocked by:** 03 (the baseline) and 05 (take the "before" after 05: about half of this
hotspot is inside the config load that 05 stops repeating).

**Status:** done

**Share of the baseline spawns** (532 events, before 05): **188 events (35%)**, the largest
direct share. 87 are processes (50 `basename`, 23 `dirname`, 14 `sed` in
`_foreman_status_line_re`) and 101 are the subshells around them (28 of them around that
`sed`). **100 of the 188 are inside the config load** and fall to about a seventh once 05
lands; **88 are elsewhere** (36 `basename` in `foreman-next.sh` alone, 2 per ticket per
listing) and are this ticket's real payoff. It is listed third only because 05 makes it
smaller than it looks here.

- [x] No `basename` or `dirname` process is started anywhere `foreman status`, `dry-run` or the start of `run` reaches; the benchmark's rows for both are gone or near zero
- [x] `basename` and `dirname` replacements give the same answer as the commands for a path with a trailing slash, with no slash at all, and for a bare `/`, where any caller can reach those cases
- [x] The status-line escape (`_foreman_status_line_re`) is no longer a `sed` per call, and a status line holding `.`, `[`, `*`, `^`, `$` or a backslash still matches itself only
- [x] Behaviour contract: output may change in wording or spacing, but **every existing smoke assertion passes with none edited**; which ticket is next, whether it is a human ticket, whether it has landed and which warnings are raised do not change
- [x] The benchmark's before (taken after 05) and after are recorded here, median and spawn table
- [x] `bash test/smoke.sh` passes in full; the closing note records `Full smoke suite: N passed in Mm Ss`

## Comments

**Closing note.** Design: `basename` and `dirname` are two helpers in `lib/foreman-repo.sh`, `_foreman_basename VAR PATH` and `_foreman_dirname VAR PATH`, which set a variable instead of printing, so a caller needs neither the process nor the `$(...)` around it. They are in `foreman-repo.sh` rather than the config because `foreman-init.sh` and `foreman-doctor.sh` source that file and not the config. They answer as the commands do for a trailing slash, no slash, an empty string and a bare `/`; on Git Bash and Cygwin, where the commands also cut at a backslash, so do they (a `FOREMAN_RUN_LOG` of `C:\x\y.log` is accepted by `_foreman_path`, and the run-start `mkdir` needs its directory). The script-location line, which has to run before `foreman-repo.sh` can be sourced, is `${BASH_SOURCE[0]%/*}` with the two cases a bare `%/*` gets wrong handled in place: no slash (`bash foreman-next.sh`, answer `.`) and a file in `/` (answer `/`). It is in `bin/foreman` and every script in `lib/` that locates itself. The status-line escape is parameter expansion, run once into a variable that both patterns use, with the backslash doubled first so it does not double the others.

Checked that the behaviour contract holds, three ways. (1) The helpers against the commands over 28 awkward paths (empty, `/`, trailing slashes, `a//b`, `-x`, a space, `C:/x/y`, and eight with backslashes), on Git Bash (bash 5.2) and on WSL (bash 4.4): identical. The status-line escape against the old `sed` over ten awkward status lines (all five metacharacters, a backslash, `&`, `\`, empty), on both: identical. (2) Old (`git archive HEAD`) against new through `status` (three ways of naming a batch with a space in its name), `dry-run` and every `foreman-next.sh` mode, on a batch with a `DONE_` ticket, a second issues directory and a human ticket: output and exit codes identical. `bin/foreman` was also started from inside `bin/`, and `foreman-next.sh` from inside `lib/`, by bare name. (3) Two cases added to the smoke suite, the first green against the old code: a status line of `St.t[u]s*^$\x:` matches only itself (five near-misses, each of which one unescaped character would let through, stay undone, and the human pattern is escaped the same way); and the helper-parity table above, run against whatever `basename` and `dirname` the platform has. No existing assertion was edited.

Traced `status`, `dry-run` and `run` to its first iteration: no `basename`, `dirname` or `sed` process is started in any of them.

**Benchmark, Git Bash** (`bash test/bench.sh 7`, bash 5.2.26, 2026-10-01; before is clean HEAD `d7cb557`, after 05 and 06 landed, run back to back with the after):

| | median | runs | spawns |
|---|---|---|---|
| before | 2.00 s | 2.27, 2.01, 2.00, 2.08, 1.81, 1.81, 1.84 | 78 |
| after | **1.15 s** | 1.10, 1.15, 1.13, 1.16, 1.18, 1.15, 1.07 | **44** |

Spawn table, before, then after:

```
before                                           after
   55  (subshells, command substitutions)          36  (subshells, command substitutions)
    8  basename      5  dirname                     3  git
    3  git           2  sed                         1 each: bash, cut, find, grep, sort
    1 each: bash, cut, find, grep, sort
   78  total                                        44 total
```

34 events gone: 8 `basename`, 5 `dirname` and 2 `sed` processes, and the 19 subshells around them. That is 6% of the 532-event baseline on its own; with 05 and 06 the call is down from 532 events to 44 (92%), and the median fell 42% against this ticket's "before". The ticket's own share was 188 events at the baseline; 100 of them went with 05 and the rest are now in this ticket's 34 plus what 06 removed. What is left is `git` (3), the batch-discovery `grep`, and the one `find | sort | cut` that lists the tickets once.

Code review (standards and spec, in parallel): no hard violations. One real finding, fixed: the first helpers cut at `/` only, and Git Bash's `dirname` also cuts at a backslash, so a `C:\...` `FOREMAN_RUN_LOG` or `FOREMAN_RUN_JSONL` would have left the run-start `mkdir` with `.`; the helpers are now separator-aware and the parity table includes backslash paths. Also fixed: the trailing-separator loop, written out three times, is one `_foreman_trim_seps`; the copy-pasted comment on the location line named the wrong file in five scripts and is one line pointing at `foreman-config.sh`; two statements on one line in `foreman-loop.sh` are split.

Left alone, on purpose: `lib/exec/fake.sh` still calls `basename` and `sed` when it sends a ticket back (the test adapter, after a followup ticket's check, not at the start of anything); `foreman-human.sh`'s `sed` on the `## Sent back by` heading (06 left it, and it is asked of a human ticket only); `foreman_find_batches`' `sed`, which runs only when no batch is named; `install.sh`. `//` and a bare drive root (`C:\`) are not matched on Git Bash, where the commands treat them as UNC and drive roots and GNU treats them differently again; no path any caller holds is one. The scratch variable names the call sites use (`_jsonl_dir`, `_sent_back_by`, `init_batch_name`, `_foreman_repo_name`) follow no single convention; each is local to a few lines.

Full smoke suite: 484 passed in 11m 58s

That is the 479 assertions of 06's run plus the 5 of the two new cases, with no existing assertion edited. Run time varies with the machine (06 recorded 13m 4s; an earlier run of the code before review fixes took 13m 23s).
