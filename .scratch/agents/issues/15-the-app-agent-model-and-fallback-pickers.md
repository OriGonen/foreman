# 15: The app: agent, model and fallback pickers

**Status:** ready-for-agent

**Blocked by:** 09, 12

**What to build:**

The app lets the user choose the agent, model and fallback when starting a run, and shows
what the terminal shows about agents and costs (spec: "The app"; user stories 80–85;
ADR 0004 — the app works out nothing the CLI decides).

- Run settings: an agent picker, then a model picker filled from `foreman agents`' machine-readable form for that agent, then a fallback agent and model picker (none by default), and the effort that will actually be used, including a lowered level for the fallback. The choices reach the same `foreman run` as its flags and environment.
- The "can't run" screen names the missing program (e.g. "agy missing") instead of "claude / sbx missing"; the login-expired screen names the agent whose login expired.
- The run and report screens show each turn's agent, mark estimated costs with "≈" and unknown ones as "cost unknown", and announce a fallback takeover. The bill shown before a run uses the same estimate.

- [ ] The pickers list exactly what `foreman agents` reports, and an empty or failed listing shows the error rather than a guess
- [ ] Starting a run from the app with Antigravity and a fallback runs the same command line the terminal would (tested at the app's existing test seam)
- [ ] The two screens name the actual program and agent
- [ ] Run and report screens show agents, "≈" and "cost unknown" as the terminal does
- [ ] A Claude-only batch looks as it does today apart from the new pickers
- [ ] The app's existing tests pass, and the full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
