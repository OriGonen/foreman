# 04: `ralph order` places human and check tickets

**Status:** ready-for-agent

**Blocked by:** 03

**What to build:**

`ralph order` has an agent read every ticket and write `order.md`. It has no idea that a human
ticket stops the loop dead, or that a check ticket must sit right after the ticket it checks.
Tell it, and check its work for free.

The ordering prompt gains:

- an explicit priority: dependencies first, then human-ticket placement and check-ticket
  adjacency, then importance, then load;
- when the batch has human tickets, a section listing them and the rules: each comes after
  everything it depends on; everything that depends on it, directly or through another ticket,
  comes after it; and it goes as **late** as those allow — every ticket that does not depend on
  it goes before it, so the unattended stretch before each stop is as long as possible. The
  prose above the order block names each human ticket, what waits on it, and why it sits there;
- when any ticket has a `Checks:` line, a section saying a check ticket goes **immediately**
  after the ticket it names, because an unrelated ticket in between could build on unchecked
  work;
- always: a `Blocked by:` line is an explicit dependency, honoured exactly.

After the agent writes `order.md`, `ralph order` prints the same four warnings as `ralph
status` (ticket 03), with its exit status unchanged. The loop itself still never parses
`Blocked by:` — order.md stays the single source of truth for sequencing.

Full design: `.scratch/human-tickets/plan.md` — the `ralph-order.sh` section.

**Acceptance criteria:**

- [ ] A smoke case puts a stub `claude` first on `PATH` that captures the `-p` prompt and
      prints `{"total_cost_usd":0}`, so `ralph order` runs with no model and no cost
- [ ] With a human ticket and a check ticket in the batch, the captured prompt has the
      human-tickets section naming the human ticket, and the check-tickets section
- [ ] With neither, both sections are absent, and the `Blocked by:` sentence is still there
- [ ] With a human ticket that has no check ticket, `ralph order` prints that warning after
      ordering and still exits 0
- [ ] `bash test/smoke.sh` passes in full
