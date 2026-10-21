# Keep Docker and the sandbox's Claude signed in: local credentials file + `foreman setup`

## Context

Two logins keep dying on unattended `foreman run`s: Docker's `sbx` session (device-code prompt)
and the sandbox's Claude OAuth secret ("could not be refreshed" — `sbx secret ls` shows
`anthropic (oauth configured)`). foreman now stops fast on an auth failure (commit 3a3f41b) and
has an env-var Docker login (`_sbx_login`). The goal:

1. both credentials read from a **local, uncommitted, user-level file** instead of `setx`
   environment variables (which every child process inherits, including the agent in `local`
   mode);
2. foreman keeps the Claude credential in place for the sandbox, using a `claude setup-token`
   long-lived token (subscription);
3. a **`foreman setup` command that guides the user through creating and saving them**.

## The credentials file

One file, outside every repo: `~/.config/foreman/env`, overridable with `FOREMAN_CREDENTIALS_FILE`.
Plain `NAME=value` lines, `#` comments:

```
FOREMAN_DOCKER_USERNAME=someone
FOREMAN_DOCKER_PAT=dckr_pat_...
FOREMAN_CLAUDE_TOKEN=sk-ant-oat...
```

**Parsed as data, never sourced** (a stray line cannot run code). Strip CR, optional
surrounding quotes, ignore blanks/comments. A real environment variable of the same name wins
over the file, so env-var behaviour keeps working. Values are never printed, never put in
argv, never exported to children — they reach `sbx` on stdin only.

One shared reader (sourced, never run) with: the resolved file path; a lookup (env, else
file, else empty) used by the adapters, `setup` and `doctor` so they cannot disagree; an
in-place single-line setter (append if absent, preserve every other line and comment, temp
file + `mv`, create the directory, best-effort `chmod 600`); and a mask (`…last4`).

## Sandbox preflight

Shared by `sandbox` and `sandbox-mount`, all before the sandbox exists or any money is spent:
Docker login → Claude secret → existing preflight.

Claude secret, when `FOREMAN_CLAUDE_TOKEN` is present: if `sbx secret ls` shows an anthropic
**oauth** row, `sbx secret rm anthropic -f` first (an OAuth secret takes precedence over an
api-key one); then pipe the token into `sbx secret set anthropic`. On failure → preflight
warning with sbx's output, never the token. Token absent → today's behaviour. Failure
messages end with "run `foreman setup`".

## `foreman setup`

```
foreman setup              guided: Docker, then Claude (skips a step already working)
foreman setup docker       redo just the Docker step
foreman setup claude       redo just the Claude step
foreman setup --check      no prompts, no network: which keys exist (names only); exit 1 if any missing
```

Guided flow needs a terminal (refuses with a pointer to `--check` otherwise):
1. Preflight: `sbx` and `claude` on PATH.
2. Docker: where to create the token (hub.docker.com → Account settings → Personal access
   tokens; expiration None; permission Repo Public Read-only, fall back to Repo Read-only if
   `sbx login` rejects it). Username visible, token hidden. Tested for real with
   `sbx login … --password-stdin`; saved only on success, else explain and re-prompt (max 3).
3. Claude: run `claude setup-token` in another terminal, paste the token (hidden). Tested
   through the same path the preflight uses; saved only on success.
4. Summary: file path, which keys are set (masked), reminder the file is plaintext and outside
   every repo, the next command.

Never echoes a value; a failed test never writes; unrelated lines in the file survive.

## `foreman doctor`

A "Credentials" section only when a batch asks for a sandbox mode: ok / MISS per credential,
presence only, no network, MISS counts toward the exit code.

## Docs

README "Credentials" section replaces the env-var "Staying signed in to Docker" section.

## Unverified (ticket 02)

1. Does `sbx secret set anthropic` accept a `claude setup-token` token (vs only API keys)? If
   not, the same slot takes an Anthropic API key — same code, only setup wording changes.
2. Re-running `sbx secret set anthropic` when one exists: overwrite, prompt, or error?
3. Does an existing sandbox pick up a changed global secret on next start?
4. Does the custom secret `ANTHROPIC_API_KEY` → `openrouter.ai` interfere?
