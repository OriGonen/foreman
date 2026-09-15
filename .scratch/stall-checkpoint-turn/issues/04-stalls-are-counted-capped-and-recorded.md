# 04: Stalls are counted, capped and recorded

**Status:** ready-for-agent

**Blocked by:** 03

**What to build:**

A stall now costs a turn that the operator did not ask for, so the accounting has to stay
honest in both directions: the extra turn must not silently spend the budget the operator
set, and its cost must not silently vanish from the total.

A stall does not advance the user-facing iteration counter — that number means "iterations
of work I commissioned". It does not spend one of the ticket's attempts either, on the same
reasoning that already applies to a ticket that hands off deliberately: the attempt counter
counts unproductive tries, and a stall is not one. The checkpoint turn's cost **is** added
to the run total, because it is money.

The checkpoint turn gets its own row in the structured run log, marked as a checkpoint, so
per-iteration cost and duration figures are not distorted by a second turn folded into
them. The report gains the corresponding bucket, and a stall is not counted as a failure.

A per-ticket stall counter exists for display and telemetry only. The **budget** stays the
single existing continuation cap, fed by stalls and deliberate handoffs alike — no new
configuration setting. Two caps would let one ticket burn both with no single number
bounding it.

That shared cap's message currently says a ticket "has progressed N times without landing",
which becomes false the moment stalls feed the counter — a ticket may have stalled three
times and progressed never. Reword it to say the ticket needed some number of extra turns
without landing, with a breakdown of how many were which. The advice it ends on — this is a
size problem, split the ticket — is right either way.

**Acceptance criteria:**

- [ ] A stall does not advance the user-facing iteration counter
- [ ] A stall does not spend one of the ticket's attempts
- [ ] The checkpoint turn's cost is included in the run's total
- [ ] The checkpoint turn is recorded as its own row, distinguishable from an iteration
- [ ] The report accounts for stalls as their own outcome and does not flag them as failures
- [ ] Stalls and deliberate handoffs feed the same existing cap; no new configuration
      setting is introduced
- [ ] The cap message is true whether the ticket stalled, progressed, or both, and breaks
      down how many were which
- [ ] Reaching the cap still stops the run for a human and still advises splitting the
      ticket
