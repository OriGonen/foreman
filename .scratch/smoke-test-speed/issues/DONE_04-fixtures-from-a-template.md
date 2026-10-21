# 04: Fixtures are copied from a template instead of built from scratch

**What to build:** Building a fixture repository stops being a slow part of every smoke
case. The suite builds one template repository per run, with the same git identity,
line-ending settings, ignore file, attributes file and batch config that fixtures get
today. Each case's fixture is a copy of it, with the case's own variation (ticket count,
repository name) applied after the copy. Every case gets a fresh repository of its own,
and no case can tell the difference. See `spec.md` in this directory, "Smoke suite
harness".

**The template carries no tickets and no commit.** The ticket count varies from 1 to 5
across cases, and the initial commit contains the tickets. A committed template would need
`git rm` and `commit --amend` per case, which gives back the git spawns the template saves,
and would give every fixture the same root commit. So the template is a configured
repository (identity, `core.autocrlf`, `foreman.conf`, `.gitignore`, `.gitattributes`) with
nothing staged or committed. After the copy, a fixture gets its ticket files (written with
`printf` and a redirection, not `cat`) and then one `git add` and one `git commit`.

**The builder is shared with the benchmark.** `test/bench.sh` does not source
`test/smoke.sh` and has its own copy of the fixture code ("keep the two in step"). The
template builder and the copy step move to one file both scripts source (for example
`test/fixture.sh`), and the benchmark's copy is deleted, so the two cannot drift.

**Blocked by:** 03 (so the baseline measures the untouched suite). By the owner's choice it
is worked last, after 05-09 (03's notes: it saves the least time). Nothing in 05-09 depends
on it. All of 05-09 have landed.

**Status:** done

- [x] The template is built once per suite run, inside the run's own work directory, and is removed with it
- [x] The template has no ticket files and no commit; a fixture's tickets and its single initial commit are made after the copy
- [x] A fixture made from the template has the same files, git identity, line-ending settings and a single initial commit (containing its tickets) as one built from scratch
- [x] Fixtures are independent: a case that changes its repository cannot affect another case's
- [x] Callers of the fixture builder are unchanged
- [x] No existing assertion is edited, and `bash test/smoke.sh` passes in full
- [x] The template builder and the copy step live in one file that both `test/smoke.sh` and `test/bench.sh` source; the fixture code in `test/bench.sh` is gone, and its numbers still compare with the baseline (it times `foreman status`, which the fixture does not touch)
- [x] The ticket records the time of one fixture build before and after (the primary evidence), and the suite total before and after (a check that the suite still passes in full, not evidence of the saving); the closing note records `Full smoke suite: N passed in Mm Ss`

- [x] Last step, always: compare the suite total from this ticket's "after" run (with 05-09 and this ticket landed) with the spec's ten minutes. If it is over, write the `parallel-cases` ticket as ticket 10, blocked by this one, opening with the shared-state audit (`spec.md`, user stories 30-32); if it is at or under, say so here, and the effort is finished

**Expected payoff (measured 2026-10-01 in a scratch script, nothing in the repository
touched):** a fixture built from scratch (`make_repo 3`) takes 0.74-1.1 s; a copy of a
template, with its tickets written and one `git add` and `git commit`, takes 0.29-0.43 s.
That is about 0.45 s saved per fixture, and `test/smoke.sh` has about 83 `make_repo` call
sites: about 37 s per run, 5% of a 12.5-minute suite. Most of it is the dropped `git init`,
three `git config` calls and per-ticket `cat` forks. It will not bring the suite under ten
minutes by itself: from 05-09's last run (12m 32s, 484 passed) it lands near 11m 50s, so the
last step is expected to end in writing ticket 10. (Earlier figures in this ticket, from 03
at HEAD `0b238c3`: 466 passed in 38m 41s; `make_repo 3` 0.65-0.80 s; 79 fixtures, about 55 s.
Both the suite and the fixture count have changed since.)

**This ticket's own "before"** is the suite total of the last full run before it starts,
with 05-09 landed, not the baseline above: take it on a clean tree and record it here. Run
it with a fresh, empty `TMPDIR` (`TMPDIR=$(mktemp -d)`): the fake adapter keeps a call
counter per PID in `$TMPDIR` and never removes it, so a recycled PID in a long-used `/tmp`
can fail a case (seen in ticket 06's run; ticket 09 also saw one failure that did not
repeat). Run-to-run variation of the suite on this machine is about a minute (11m 55s to
13m 4s for unchanged code), larger than this ticket's saving, which is why the per-fixture
time is the evidence and the suite total is not. Measure one fixture build the same way
before and after: `make_repo 3` three times on an idle machine, comparable with the
baseline's 0.65-0.80 s.

## Comments

**Design.** `test/fixture.sh` (sourced, not run) has two functions. `build_fixture_template DIR` makes the configured repository with no tickets and no commit: `git init`, `core.autocrlf false`, the `foreman-test` identity, `batch/foreman.conf` (the template plus `FOREMAN_EXEC=fake`), `.gitignore`, `.gitattributes`, and an empty `batch/issues`. `copy_fixture TEMPLATE DEST COUNT` does `cp -R`, writes the tickets with `printf` and a redirection in a bash `for` loop (no `cat`, no `seq`), then one `git add` and one `git commit`. `test/smoke.sh` builds the template once at start-up in `$WORK/.template` (so the run's cleanup trap removes it, and `$WORK/*` globs do not see it); `make_repo` is now a three-line wrapper with the same signature and the same printed path, so its 83 call sites are untouched. `test/bench.sh` sources the same file and its own copy of the fixture code is deleted; it builds a template and copies it once.

**Same repository as before.** A scratch script (not committed) built `make_repo 3` from HEAD's code and from the new code and compared the two: file lists, every file's bytes (`od -c`), `.git/config`, the number of hooks in `.git/hooks`, `git log` author, committer and subject, the commit count, `git show --stat`, `git status --porcelain` and the branch. The only difference was the label line. A 5-ticket fixture from the same template had five tickets and one commit; committing in one fixture left another at one commit; the template itself stayed with no commit, no tickets and nothing staged.

**One fixture build, `make_repo 3` three times on an idle machine** (the primary evidence; 2026-10-01, Git Bash, bash 5.2.26, two sets of three each):

| | runs | range |
|---|---|---|
| before (HEAD `532fe93`, from scratch) | 810, 777, 726, 759, 790, 765 ms | 0.73-0.81 s |
| after (from the template) | 426, 326, 306, 358, 311, 297 ms | 0.30-0.43 s |

That is about 0.45 s saved per fixture, as the ticket's measurement predicted. The template is built once per run and costs 0.36-0.43 s. With about 83 fixtures that is roughly 37 s of the suite, less the template's own 0.4 s.

**Suite totals** (a check that the suite still passes in full, not evidence of the saving; each on a fresh empty `TMPDIR`, nothing else running; "before" was run from a `git archive` copy of HEAD so that editing the working tree could not touch a running script):

| | result |
|---|---|
| before (HEAD `532fe93`) | 484 passed, 0 failed, 13m 1s |
| after | 484 passed, 0 failed, 12m 42s |

The 19 s difference is inside the suite's run-to-run variation (about a minute on this machine), so it is not evidence of anything; the per-fixture time above is. No assertion was edited.

**Benchmark.** `bash test/bench.sh 1` after the change: `foreman status` 0.76 s, 32 spawns in the trace, the same total as ticket 09's "after" table, and no `foreman-bench-*` directory left in `$TMPDIR`. The benchmark times `foreman status`, which the fixture does not touch, so its numbers still compare with the baseline.

**Code review** (`/code-review`, on the uncommitted diff, both axes done inline): Standards, one finding: the README's file table lists everything under `test/` and did not list `test/fixture.sh`; a row was added. Spec, no findings.

**Last step: the suite total against the spec's ten minutes.** With 05-09 and this ticket landed the full suite takes **12m 42s**, which is over ten minutes by 2m 42s. Ticket 10, `10-parallel-cases.md`, is written, blocked by this one, and opens with the shared-state audit (`spec.md`, user stories 30-32). The effort is not finished.

Full smoke suite: 484 passed in 12m 42s
