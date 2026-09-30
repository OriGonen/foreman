# 07: File names and pattern escaping are handled by the shell, not by `basename`, `dirname` and `sed`

**What to build:** `basename "$x"` becomes `${x##*/}`, `dirname "$x"` becomes `${x%/*}` (with
the same answer when there is no slash), and the `sed` that escapes the status line for a
pattern is replaced by parameter expansion or a plain string comparison. Each of these is a
process, and each sits inside a `$(...)`, which is a second one. See `spec.md`, "Name and
string handling".

**Blocked by:** 03 (the baseline) and 05 (take the "before" after 05: about half of this
hotspot is inside the config load that 05 stops repeating).

**Status:** ready-for-agent

**Share of the baseline spawns** (532 events, before 05): **188 events (35%)**, the largest
direct share. 87 are processes (50 `basename`, 23 `dirname`, 14 `sed` in
`_ralph_status_line_re`) and 101 are the subshells around them (28 of them around that
`sed`). **100 of the 188 are inside the config load** and fall to about a seventh once 05
lands; **88 are elsewhere** (36 `basename` in `ralph-next.sh` alone, 2 per ticket per
listing) and are this ticket's real payoff. It is listed third only because 05 makes it
smaller than it looks here.

- [ ] No `basename` or `dirname` process is started anywhere `ralph status`, `dry-run` or the start of `run` reaches; the benchmark's rows for both are gone or near zero
- [ ] `basename` and `dirname` replacements give the same answer as the commands for a path with a trailing slash, with no slash at all, and for a bare `/`, where any caller can reach those cases
- [ ] The status-line escape (`_ralph_status_line_re`) is no longer a `sed` per call, and a status line holding `.`, `[`, `*`, `^`, `$` or a backslash still matches itself only
- [ ] Behaviour contract: output may change in wording or spacing, but **every existing smoke assertion passes with none edited**; which ticket is next, whether it is a human ticket, whether it has landed and which warnings are raised do not change
- [ ] The benchmark's before (taken after 05) and after are recorded here, median and spawn table
- [ ] `bash test/smoke.sh` passes in full; the closing note records `Full smoke suite: N passed in Mm Ss`
