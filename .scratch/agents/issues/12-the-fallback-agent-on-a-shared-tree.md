# 12: The fallback agent, on a shared working tree

**Status:** ready-for-agent

**Blocked by:** 08, 09

**What to build:**

A batch can name a fallback agent that takes over when its agent hits a usage limit, in
the modes where both agents work on the same tree — `local` and `sandbox-mount` (spec:
"The fallback agent", "Configuration"; user stories 15–16, 44–50, 52–58; CONTEXT.md
**Fallback agent**). Carrying work between two clone sandboxes is ticket 13; until then, a
fallback in `sandbox` mode is reported as not ready, with that reason.

- `FOREMAN_FALLBACK_AGENT` (default none) and `FOREMAN_FALLBACK_MODEL` (default: that agent's default model), documented in the conf template; status, dry-run and the run's opening line name the fallback.
- Preflight checks the fallback as it checks the agent — installed, logged in, model offered, and with a cost budget set, a priced model — but never refuses the run for it: it warns once, naming what is missing, and the run starts with no fallback.
- Effort: the fallback uses the batch's level, or the highest level its model offers below it, and the takeover message says so if it was lowered.
- Trigger: only the usage-limit failure class, and only with a ready fallback. On it, the turn's verdict is recorded under the first agent; the stall marker stays and records the agent whose tree holds the work; the run announces the takeover and continues with the fallback for the rest of the run, its first turn being the review turn on the uncommitted work. A usage limit under the fallback, or with no ready fallback, pauses the run as today, saying why the fallback could not take over.
- The next run starts with the batch's own agent.
- The run's lines, log, JSONL record and `foreman report` show each turn's agent; the report can total cost per agent.

- [ ] Smoke cases on the fake adapter, in `local` mode: Claude hits a usage limit mid-ticket and Antigravity takes over with a review turn first, then lands the ticket; Antigravity takes over from Claude and keeps the rest of the run; the next run starts with Claude
- [ ] Smoke cases: a fallback that also hits a limit pauses the run; a fallback that is not installed, not logged in, or unpriced under a budget lets the run start with a warning, and a limit then pauses it as today, naming the reason
- [ ] A smoke case shows the fallback's effort lowered and the takeover message saying so
- [ ] Auth, denial and context-overflow failures under the first agent never hand over (smoke cases)
- [ ] The stall marker records the agent, and a run started after a fallback's interrupted turn reviews the work with the batch's own agent
- [ ] `foreman report` shows each turn's agent; goldens are updated deliberately
- [ ] A batch with no fallback behaves exactly as before
- [ ] The full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
