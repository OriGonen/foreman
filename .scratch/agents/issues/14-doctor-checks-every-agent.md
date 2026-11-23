# 14: Doctor checks every agent

**Status:** ready-for-agent

**Blocked by:** 10, 12

**What to build:**

`foreman doctor` tells the user, for free, whether every agent a batch names is ready
(spec: "Doctor"; user stories 63–68).

- For the batch's own agent and its fallback: program installed, logged in and with which login, model offered, effort level offered. A problem with the batch's own agent is a failure; a problem with the fallback is a warning, since the run works without it.
- In the sandbox modes: `sbx` installed and logged in (add the login check if doctor does not already make it), and each agent's sandbox present or creatable.
- Antigravity: folder trust, if the findings showed headless runs need it — reported with the command for the user to run. `--fix` never writes Antigravity's settings.
- Foreman's skills installed and current in each installed agent's skills directory.
- The doctor screen, its plain output and the inspector show the agents' checks.

- [ ] Smoke cases with stub programs cover each check passing and failing, for the batch's own agent (failure) and the fallback (warning)
- [ ] The `sbx` login check is covered for a logged-in and a logged-out stub
- [ ] `doctor --fix` leaves Antigravity's settings file untouched (smoke case)
- [ ] For a Claude-only batch with no fallback, doctor's output changes only by checks this ticket deliberately adds; the doctor goldens are updated for exactly those
- [ ] New goldens for doctor on an Antigravity batch and on a batch with a fallback
- [ ] The full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
