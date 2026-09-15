# 05: The iteration after a stall is told what kind of handoff it inherited

**Status:** ready-for-agent

**Blocked by:** 03

**What to build:**

The iteration after a stall already learns that it is continuing a ticket rather than
starting one, because a stall feeds the same counter a deliberate handoff does. But the
notice it gets was written for the deliberate case and overstates how well-understood the
handoff is: it says a previous iteration did part of the work and committed it.

After a stall that is only half true. The work was done by a turn that never got to explain
itself, and the `Remaining:` list was reconstructed **from the diff** by a different turn
that never saw the reasoning. It describes what is *there*, not what was intended, and it
may be missing intent entirely.

Give the notice a stall variant carrying two facts:

- the handoff was reconstructed from the diff, so the `Remaining:` list should be treated as
  a description of what exists rather than of what was planned;
- the previous turn ran out of room — the same signal the existing context-retry notice
  carries, prompting the same correct response: work in smaller pieces and commit sooner.

The continuation must still be reviewed against the commit the ticket was **first**
attempted from, not its own last chunk, so a ticket that took several passes is still
reviewed as one diff.

**Acceptance criteria:**

- [ ] The iteration after a stall is told it is continuing, not starting
- [ ] Its notice says the handoff was reconstructed from the diff
- [ ] Its notice says the previous turn ran out of room
- [ ] The notice after a deliberate handoff is unchanged
- [ ] The continuation is reviewed against the ticket's first base, as it already is for a
      deliberate handoff
- [ ] Asserted by capturing the prompts of a run driven through the no-model test mode
