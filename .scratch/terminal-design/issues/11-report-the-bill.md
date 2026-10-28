# 11: foreman report as the bill and the ledger

**What to build:** `foreman report` at a terminal shows the 10a design. The mark sits
beside the total cost, with the run, iteration and model-minute counts and an outcome bar
with its legend. Below are TOTAL and BY RUN, with a cost bar per run. `--by-ticket` and
`--failures` keep their tables, under the same header. `foreman-report.cjs` draws it by
requiring `foreman-draw.cjs` as a module. See `spec.md`, "Per command". The design is
`designs/10a-report.ans`, from `designs/source/ReportTakes.dc.html` (panel 10a).

**Blocked by:** 08

**Status:** ready-for-agent

- [ ] The tier and width reach the report from the same variables the shell sets
- [ ] Cost bars scale to the largest run, and use eighth blocks for the remainder
- [ ] A batch with no runs says so under the header
- [ ] Plain report output is byte for byte today's
- [ ] Smoke: a forced-show report of a fixture run log, and of `--by-ticket` and `--failures`
- [ ] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
