# 04: Fixtures are copied from a template instead of built from scratch

**What to build:** Building a fixture repository stops being a large share of every smoke
case. The suite builds one template repository per run, with the same git identity,
line-ending settings, ignore file, attributes file and batch config that fixtures get
today. Each case's fixture is a copy of it, with the case's own variation (ticket count,
repository name) applied after the copy. Every case gets a fresh repository of its own,
and no case can tell the difference. See `spec.md` in this directory, "Smoke suite
harness".

**Blocked by:** 03 (so the baseline measures the untouched suite).

**Status:** ready-for-agent

- [ ] The template is built once per suite run, inside the run's own work directory, and is removed with it
- [ ] A fixture made from the template has the same files, git identity, line-ending settings and single initial commit as one built from scratch
- [ ] Fixtures are independent: a case that changes its repository cannot affect another case's
- [ ] Callers of the fixture builder are unchanged
- [ ] No existing assertion is edited, and `bash test/smoke.sh` passes in full
- [ ] The ticket records the suite total before (from 03's baseline) and after, and the time of one fixture build before and after; the closing note records `Full smoke suite: N passed in Mm Ss`
