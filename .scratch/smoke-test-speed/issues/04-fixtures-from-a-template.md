# 04: Fixtures are copied from a template instead of built from scratch

**What to build:** Building a fixture repository stops being a large share of every smoke
case. The suite builds one template repository per run, with the same git identity,
line-ending settings, ignore file, attributes file and batch config that fixtures get
today. Each case's fixture is a copy of it, with the case's own variation (ticket count,
repository name) applied after the copy. Every case gets a fresh repository of its own,
and no case can tell the difference. See `spec.md` in this directory, "Smoke suite
harness".

**Blocked by:** 03 (so the baseline measures the untouched suite). By the owner's choice it
is worked last, after 05-09 (03's notes: it saves the least time). Nothing in 05-09 depends
on it.

**Status:** ready-for-agent

- [ ] The template is built once per suite run, inside the run's own work directory, and is removed with it
- [ ] A fixture made from the template has the same files, git identity, line-ending settings and single initial commit as one built from scratch
- [ ] Fixtures are independent: a case that changes its repository cannot affect another case's
- [ ] Callers of the fixture builder are unchanged
- [ ] No existing assertion is edited, and `bash test/smoke.sh` passes in full
- [ ] The ticket records the suite total before and after, and the time of one fixture build before and after; the closing note records `Full smoke suite: N passed in Mm Ss`
- [ ] `test/bench.sh` builds its fixture from the same template (or is checked against it), so the two cannot drift; its numbers still compare with the baseline's

- [ ] Last step, always: compare the suite total from this ticket's "after" run (with 05-09 and this ticket landed) with the spec's ten minutes. If it is over, write the `parallel-cases` ticket as ticket 10, blocked by this one, opening with the shared-state audit (`spec.md`, user stories 30-32); if it is at or under, say so here, and the effort is finished

**Baseline (from 03, Git Bash, HEAD `0b238c3`):** `Full smoke suite: 466 passed in 38m 41s`.
One `make_repo 3` takes 0.65-0.80 s (three builds: 804, 647, 653 ms); the suite builds 79
fixtures, about 55 s or 2% of the run. The payoff here is therefore small; see 03's notes.

**This ticket's own "before"** is the suite total of the last full run before it starts,
with 05-09 landed, not the baseline above: take it on a clean tree and record it here. The
one-fixture-build time before is comparable to the baseline's 0.65-0.80 s.
