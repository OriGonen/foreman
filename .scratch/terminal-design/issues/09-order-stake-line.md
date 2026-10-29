# 09: foreman order as the numbered stake line

**What to build:** `foreman order` at a terminal shows the 8b design. While the agent reads
the tickets, a one-line spinner shows the elapsed time. Then comes the new order as a
numbered stake line: `moved` beside tickets that changed place, HUMAN and CHECK tags with
what they mean for the loop, and ▲ warnings below. See `spec.md`, "Per command". The
design is `designs/08b-order.ans`, from `designs/source/OrderTakes.dc.html` (panel 8b).

**Blocked by:** 02

**Status:** implemented

- [x] The spinner redraws one line and is cleared when the agent finishes or fails
- [x] `moved` is computed from order.md before and after
- [x] The human-ticket warnings are the ones `foreman_human_warnings` gives today
- [x] Plain order output is byte for byte today's
- [x] Smoke: a forced-show order with a stub agent that moves two tickets
- [x] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
