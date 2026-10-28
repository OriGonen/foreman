# 05: foreman dry-run as the walk round at dawn

**What to build:** `foreman dry-run` at a terminal shows the 11a design. It has the low
sun and the header, WOULD RUN with ▶ on the first ticket, and SETTINGS in two columns.
Then comes the prompt with line numbers, folded with `⋮` when it is longer than the screen,
and the closing rule saying nothing was sent. Plain output, which people pipe to get the
whole prompt, is unchanged. See `spec.md`, "Per command". The design is
`designs/11a-dry-run.ans`, from `designs/source/DryRunTakes.dc.html` (panel 11a).

**Blocked by:** 04

**Status:** ready-for-agent

- [ ] Settings show exec, perms, model, effort, live and budgets, from the same values `budget_label` and the conf give today
- [ ] The prompt is exactly `$FOREMAN_PROMPT`, numbered; the fold keeps the first lines and the last, and says how many lines there are in all
- [ ] Plain dry-run is byte for byte today's, including the full prompt between the `===` lines
- [ ] Smoke: the forced show holds the ticket list, each setting, line 1 of the prompt and the closing rule
- [ ] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
