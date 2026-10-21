# 06: `foreman setup claude` and the full guided flow

**Status:** ready-for-agent

**Blocked by:** 03, 05

**What to build:**

`foreman setup claude` takes the operator from "no Claude token" to a saved one the sandbox
accepts, and plain `foreman setup` walks through both steps.

The Claude step checks `claude` is on PATH and tells the operator to run `claude setup-token`
in another terminal. That opens a browser and prints a long-lived token, which can't be
captured reliably, so it is pasted. The prompt is hidden. The token is **tested for real**
through the same step the sandbox preflight runs (ticket 03) and saved only on success. Use
the wording ticket 02's handoff settled on (setup-token vs API key).

Plain `foreman setup` runs Docker, then Claude, and skips a step whose credentials are already
present and working. It ends with a summary: the file path, which keys are set (masked
`…ab12`), a reminder that the file is plaintext and outside every repo, and the next command
(`foreman run …`).

See `.scratch/credentials-setup/spec.md`.

**Acceptance criteria:**

- [ ] Happy path with stub `sbx` and piped answers writes all three keys; nothing echoed
- [ ] A rejected Claude token is not saved
- [ ] `setup docker` leaves the Claude line intact, and `setup claude` leaves the Docker lines
      intact
- [ ] Plain `setup` skips a step that already works
- [ ] The summary shows masked values only
- [ ] Output never contains the sentinel token
- [ ] Full smoke suite stays green
