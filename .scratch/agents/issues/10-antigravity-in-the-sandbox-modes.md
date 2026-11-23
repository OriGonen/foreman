# 10: Antigravity in the sandbox modes

**Status:** ready-for-agent

**Blocked by:** 08

**What to build:**

An Antigravity batch runs in the `sandbox` and `sandbox-mount` modes as a Claude batch
does (spec: "The Antigravity agent", "Configuration"; user stories 32, 35, 59–62). Read the
spec's "Smoke test findings" on sandboxes first.

- Sandboxes are per repository and agent: Claude's stays `foreman-<repo>` so existing sandboxes keep working; Antigravity's is `foreman-<repo>-antigravity`. `FOREMAN_SANDBOX`, when set, names the batch's own agent's sandbox.
- Antigravity's agent file says how its sandbox is created (the maintained kit or the custom kit the findings found) and how its login gets in; the sandbox adapters create it, as they create Claude's, when it is missing.
- In both sandbox modes Antigravity's permission checks are skipped; the sandbox is the boundary.
- The stall marker's sandbox name is the agent's sandbox.

- [ ] A stub `sbx` smoke case asserts the sandbox name and creation command for each agent, and that an existing `foreman-<repo>` Claude sandbox is reused unchanged
- [ ] Stub `sbx`/`agy` smoke cases assert Antigravity's turn command line and environment in `sandbox` and `sandbox-mount`, with permissions skipped
- [ ] The existing sandbox cases on a real clone pass for an Antigravity batch (land, dirty, review turn)
- [ ] `FOREMAN_SANDBOX` overrides the batch's own agent's sandbox only
- [ ] Claude's sandbox behaviour and goldens are unchanged
- [ ] The full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
