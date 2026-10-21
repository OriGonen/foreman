# 08: End-to-end check on this machine

**Status:** ready-for-human
**Handoff:** .scratch/credentials-setup/handoff/08-end-to-end-check-on-this-machine.md

**Blocked by:** 07

**What to do:**

Tickets 01–07 were tested against a stub `sbx`. You now try the real thing and report in the
handoff file.

1. `bash install.sh`, then `foreman setup` and follow it through. Then `foreman setup --check`
   (expect exit 0) and `foreman doctor` in a sandbox batch (expect credentials ok).
2. `sbx secret ls`: anthropic should no longer say `(oauth configured)`.
3. From `C:\Projects\tldw`: `foreman run .\.scratch\m0-frame-lab\ --live 1`. Expect no Docker
   device-code prompt and no auth-failure stop; the next ticket starts and bills tokens.
4. Put a wrong Claude token in the credentials file and run again. It should stop in
   preflight with sbx's message and a pointer to `foreman setup`. Search the console output and
   `foreman-runs.log` for the token: it must appear nowhere. Then run `foreman setup claude` to
   restore it.

Why this is a human ticket: it needs real credentials, a browser login and a paid run.
Never write a token's value into the handoff file.

**Acceptance criteria:**

- [ ] `foreman setup` completed; `--check` exited 0; doctor showed credentials ok
- [ ] `sbx secret ls` no longer shows an oauth anthropic secret
- [ ] The live run started a ticket with no Docker prompt and no auth stop
- [ ] A wrong token stopped the run in preflight, and the token appeared nowhere
- [ ] Anything confusing in `foreman setup`'s wording is written down
