# 04: foreman status as the sunrise dome

**What to build:** `foreman status` at a terminal shows the 4a design. The dome has risen
in proportion to the tickets done. Beside it are the batch, done of total, the spend and
the percentage. Below are the ✓ / ▶ list with HUMAN and CHECK tags and followups, then the
human-ticket note with its handoff path. `foreman-loop.sh --status` passes the facts it
already computes to the renderer instead of printing them, and plain output is unchanged.
See `spec.md`, "Per command". The design is `designs/04a-status.ans`, from
`designs/source/StatusTakes.dc.html` (panel 4a).

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] The dome's height follows done / total, from empty to a full sun at the end
- [ ] Every fact in today's plain status is in the show: next, human tickets remaining, the run-until note, the human warnings
- [ ] The spend comes from the batch's run log, and is left out when there is none
- [ ] Plain status (piped, in CI, narrow, no colour) is byte for byte today's
- [ ] Smoke: the forced show of a fixture batch with none, some and all done, with a human ticket next, and with a followup
- [ ] `test/bench.sh status`: the plain path adds no process
- [ ] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
