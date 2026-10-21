# 03: Sandbox preflight puts the Claude token in place before every run

**Status:** ready-for-agent

**Blocked by:** 01, 02

**What to build:**

Unattended sandbox runs stop dying on "could not be refreshed": before every run, both
sandbox modes put the operator's long-lived Claude token (`FOREMAN_CLAUDE_TOKEN`, read through
ticket 01's reader) into the sandbox's `anthropic` secret.

Preflight order becomes: Docker login → Claude secret → the existing sandbox preflight. All of
it runs before the sandbox exists or any money is spent.

When the token is present: if `sbx secret ls` lists an anthropic **oauth** row, remove it
first (an OAuth secret takes precedence over an api-key one), then pipe the token into
`sbx secret set anthropic` on stdin. If `sbx` rejects it, the run stops in preflight with
sbx's own output and a pointer to `foreman setup` — never the token. When the token is absent,
nothing new runs: today's behaviour.

Read ticket 02's handoff file first
(`.scratch/credentials-setup/handoff/02-find-out-how-sbx-secret-takes-a-setup-token.md`).
Its answers may change two things only: whether to always remove before setting (if re-setting
prompts or fails), and whether the token is a setup-token or an API key (wording only — same
code, same file key). If the handoff file is empty or does not answer those, stop and say so.

Make this step callable on its own: `foreman setup` (ticket 06) will test a pasted token
through exactly this path.

See `.scratch/credentials-setup/spec.md`.

**Acceptance criteria:**

- [ ] With a stub `sbx` that answers `secret ls/rm/set`: the token reaches `set` on stdin
      only, never argv
- [ ] `rm` runs only when an oauth anthropic row is listed (or always, if ticket 02 says
      re-setting needs it)
- [ ] No token configured → no `secret` command runs at all
- [ ] A rejected `set` stops the run in preflight, before the sandbox is prepared, with sbx's
      message and "run `foreman setup`"; the token appears nowhere in output or `foreman-runs.log`
- [ ] Works for both `sandbox` and `sandbox-mount`
- [ ] Full smoke suite stays green
