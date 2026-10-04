# 01: Docker login reads its credentials from the local credentials file

**Status:** ready-for-agent

**Blocked by:** None (can start immediately)

**What to build:**

The sandbox modes' Docker login reads the Docker username and personal access token from a
local, user-level credentials file, so the operator no longer needs `setx` environment
variables that every child process (including the agent in `local` mode) would inherit.

The file is `~/.config/ralph/env`, or wherever `RALPH_CREDENTIALS_FILE` points. It holds
plain `NAME=value` lines and `#` comments. It is **parsed as data, never sourced**: CR is
stripped, optional surrounding quotes are removed, blank and comment lines are ignored. A
real environment variable of the same name wins over the file, so today's env-var setup
keeps working unchanged.

Build one shared reader, sourced and never run, that resolves the file path, looks up a
name (env, else file, else empty) and masks a value for display (`…last4`). It is the only
parser: the adapters, `ralph setup` and `ralph doctor` will all use it later, so they cannot
disagree. Then switch the existing sandbox Docker login over to it.

Values are never printed, never put in argv and never exported. They reach `sbx` on stdin
only.

Note: the env-var Docker login this builds on was still uncommitted in the operator's
working tree when this ticket was written. If it is not in HEAD, ask before taking it over;
do not commit the operator's unrelated uncommitted work.

See `.scratch/credentials-setup/spec.md`.

**Acceptance criteria:**

- [ ] A name present only in the file is found
- [ ] An environment variable beats the file
- [ ] CRLF line endings, quoted values, comments and blank lines are handled
- [ ] A missing file yields empty, not an error
- [ ] `RALPH_CREDENTIALS_FILE` moves the file
- [ ] A file line containing shell code is never executed
- [ ] The sandbox Docker login uses the file's username and token; with a stub `sbx`, the
      token arrives on stdin and never appears in argv or output
- [ ] With neither file nor env values, the Docker login behaves exactly as today
- [ ] Full smoke suite stays green
