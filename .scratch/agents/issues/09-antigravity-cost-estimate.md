# 09: Antigravity's cost estimate

**Status:** ready-for-agent

**Blocked by:** 08

**What to build:**

Every Antigravity turn reports what it would cost at Google's API prices, whichever login
it ran on, and the cost budget works on it (spec: "Cost"; user stories 73–79).

- A price table in Antigravity's agent files: per model, per effective date, prices per 1M tokens for input, output, thinking and cache reads. Thinking and cache-read pricing are taken from the AI Studio pricing page (or the spec's findings) when the table is written; the page and date read are noted beside the table. Start with the prices in the spec, including Carbon and Argon's change on 2026-12-01 and Flash's on 2027-01-01.
- Antigravity's node module computes the cost from `usage` and the row in effect at the turn's date, and sets `cost_estimated`. The verdict gains `cost_estimated` (false for Claude).
- Wherever a cost is shown — the run's lines, the end-of-run summary, `foreman report` — an estimate is prefixed "≈", and a turn with no row shows "cost unknown", never $0.
- The cost budget (`FOREMAN_MAX_COST_USD`) counts estimates as it counts reported costs. With a budget set, preflight refuses a run whose model has no row.

- [ ] Node tests compute the cost of captured Antigravity turns, across an effective-date change, and for a model with no row
- [ ] The terminal and `foreman report` mark estimates with "≈" and unknown costs as "cost unknown", with goldens updated deliberately
- [ ] A smoke case on the fake adapter stops an Antigravity run at its cost budget using estimates
- [ ] A smoke case shows preflight refusing an unpriced model under a budget, and allowing it without one
- [ ] Claude's costs and their display are unchanged
- [ ] The full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
