# 10: foreman next --all as the stake row

**What to build:** `foreman next --all` at a terminal shows the 9b design: a stake per
ticket with the next one tall, the ✓ / ▶ list with tags, and a "6 driven · 1 yours · 3 to
go" line. `--count` gets its one-line form. Bare `foreman next` and `--list` print bare
paths on every stream, because scripts read them. See `spec.md`, "Per command". The
design is `designs/09b-next.ans`, from `designs/source/NextTakes.dc.html` (panel 9b).

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] The stake row wraps or narrows for batches wider than the terminal, or falls back to plain
- [ ] Bare `next`, `--list` and `--unordered` are unchanged on every stream, a terminal included
- [ ] Smoke: forced-show `--all` and `--count`; bare `next` under `FOREMAN_SHOW=always` still prints bare paths
- [ ] `test/bench.sh next`: the plain path adds no process
- [ ] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
