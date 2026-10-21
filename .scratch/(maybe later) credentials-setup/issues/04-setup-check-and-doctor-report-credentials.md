# 04: `foreman setup --check` and doctor's Credentials section report which keys are present

**Status:** ready-for-agent

**Blocked by:** 01

**What to build:**

The operator can ask, without prompts or network, whether foreman has the credentials a
sandbox run needs.

Add the `foreman setup` command, dispatched the way `init` and `doctor` are: its header
comment doubles as `--help`, and `foreman`'s own help gains a line for it. This ticket gives it
one working mode, `foreman setup --check`, which lists which of `FOREMAN_DOCKER_USERNAME`,
`FOREMAN_DOCKER_PAT` and `FOREMAN_CLAUDE_TOKEN` are set (names only, never values or masks), names
the credentials file, and exits 1 if any is missing. It works outside a repo.

The guided modes (`foreman setup`, `setup docker`, `setup claude`) come in tickets 05 and 06.
For now, without `--check` and without a terminal, `setup` refuses and points to `--check`.
With a terminal, it may say the guided flow is not available yet.

`foreman doctor` gains a small "Credentials" section, shown only when the batch asks for a
sandbox mode: `ok  Docker login configured` / `MISS Docker login — run foreman setup`, same for
Claude. Presence only, through ticket 01's reader; no network. A MISS counts toward doctor's
exit code like its other MISS lines.

See `.scratch/credentials-setup/spec.md`.

**Acceptance criteria:**

- [ ] `foreman setup --check` with all keys → exit 0, names listed
- [ ] `foreman setup --check` with a key missing → exit 1, the missing name shown
- [ ] `--check` output never contains a sentinel value from the file
- [ ] `foreman setup --help` and `foreman`'s help mention the command
- [ ] Non-tty `foreman setup` without `--check` refuses with a pointer to `--check`
- [ ] Doctor shows the Credentials section for a sandbox batch and not for a `fake` batch
- [ ] A missing credential in that section makes doctor exit non-zero
- [ ] Full smoke suite stays green
