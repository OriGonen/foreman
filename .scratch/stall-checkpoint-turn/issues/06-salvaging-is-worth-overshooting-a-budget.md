# 06: Salvaging work is worth overshooting a budget, and the run says so

**Status:** done

**Blocked by:** 04

**What to build:**

Budget checks happen *before* an iteration, but a stall is only discovered *after* one. So a
stalled turn can be the thing that pushes a run past its cost or time budget — and the
work it left behind is then stranded at exactly the moment the loop has decided to stop
spending.

Run the checkpoint turn anyway. A budget limits how much work to **commission**, not whether
to keep work already paid for. The overshoot is one short turn, already bounded by the turn
limit from ticket 03, and the alternative is a stop whose printed instructions ask the
operator to do by hand precisely what the skipped turn would have done.

This deliberately breaks a promise the tool currently makes — that a cost budget holds — so
it must not be silent. The run's closing message says a budget was overshot to salvage
stalled work, so a final figure above the limit is explained rather than mysterious.

**Acceptance criteria:**

- [x] A stall discovered after the cost budget was reached still gets its checkpoint turn
- [x] The same holds for the time budget
- [x] The closing message says a budget was overshot to salvage stalled work, and by how
      much
- [x] The run still stops after salvaging; the overshoot buys the checkpoint turn and
      nothing more
- [x] Budgets are otherwise unchanged: a run not salvaging anything still stops exactly
      where it does today
