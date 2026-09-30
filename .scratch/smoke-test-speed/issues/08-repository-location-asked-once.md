# 08: The repository root and the batch's prefix are asked of git once per command

**What to build:** The repository root and the batch's repo-relative prefix are asked of git
once per command and remembered for the rest of it, so that the answer a command decided on
is the answer every later step used. See `spec.md`, "Repository location".

**Blocked by:** 03 (the baseline) and 05. **This ticket opens with a re-measurement and may
close having changed nothing.**

**Status:** ready-for-agent

**Share of the baseline spawns** (532 events, before 05): **56 events (11%)**: 21 `git` calls
(14 from `ralph_batch_relpath`, 7 from `ralph_repo_root`) and 35 subshells. **All 56 sit
inside the config load**, which ran 7 times, so 05 is expected to take them to about 8, under
2% of the new total.

- [ ] First step, before any change: run the benchmark on the tree with 05 landed and record here how many events `ralph_repo_root` and `ralph_batch_relpath` still account for
- [ ] If that is under 3% of the benchmark's total, close this ticket with that number and a note, and change no code. Otherwise carry on below
- [ ] `git rev-parse --show-toplevel` and `--show-prefix` each run at most once per command, and what they answered is reused
- [ ] The path-syntax guarantees in `ralph-repo.sh`'s header still hold (the drive-letter spelling, the `/tmp` mount alias, a batch in a different repository still refused with the same message)
- [ ] Behaviour contract: output may change in wording or spacing, but **every existing smoke assertion passes with none edited**; which ticket is next, whether it is a human ticket, whether it has landed and which warnings are raised do not change
- [ ] The benchmark's before and after are recorded here, median and spawn table
- [ ] `bash test/smoke.sh` passes in full (unless closed unchanged); the closing note records `Full smoke suite: N passed in Mm Ss`
