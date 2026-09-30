# 09: Path helpers set a variable instead of printing a path

**What to build:** `_ralph_path` returns a path by printing it, so each of its six callers
is a command substitution, which forks. Make it set a named variable for the caller instead,
and change the callers to match; what path it computes does not change. See `spec.md`, "Path
helpers". This is the last of the spawn-reduction tickets. The question the spec left for
the end of the library work, whether the suite still needs parallel cases, is settled by
ticket 04, which is worked after it.

**Blocked by:** 03 (the baseline), 05, 06, 07 and 08, so that it is worked last of the
spawn-reduction tickets. **This ticket opens with a re-measurement and may close having
changed nothing.**

**Status:** ready-for-agent

**Share of the baseline spawns** (532 events, before 05): **42 events (8%)**, all of them the
six `$(_ralph_path ...)` substitutions in `ralph-config.sh`, repeated by each of the 7 loads.
05 is expected to take them to about 6, about 2% of the new total (about 300 events).

- [ ] First step, before any change: run the benchmark on the tree with 05 landed and record here how many events the `_ralph_path` substitutions still account for
- [ ] If that is under 3% of the benchmark's total, close this ticket with that number and a note, and change no code. Otherwise carry on below
- [ ] `_ralph_path` no longer runs in a command substitution at any of its call sites; the resolved paths (absolute as given, repo-relative if something is there, batch-relative otherwise) are unchanged for all three spellings
- [ ] Behaviour contract: output may change in wording or spacing, but **every existing smoke assertion passes with none edited**; which ticket is next, whether it is a human ticket, whether it has landed and which warnings are raised do not change
- [ ] The benchmark's before and after are recorded here, median and spawn table
- [ ] `bash test/smoke.sh` passes in full (unless closed unchanged); the closing note records `Full smoke suite: N passed in Mm Ss`
