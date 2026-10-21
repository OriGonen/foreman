# 05: `foreman setup docker` walks through creating, testing and saving a Docker token

**Status:** ready-for-agent

**Blocked by:** 04

**What to build:**

`foreman setup docker` takes the operator from "no Docker token" to a saved, working one.

It tells them where to create the token: hub.docker.com → Account settings → Personal access
tokens; expiration *None*; permission **Repo Public Read-only**, falling back to *Repo
Read-only* if `sbx login` rejects it. It checks `sbx` is on PATH. It prompts for the username
(visible) and the token (hidden). It **tests them for real** with `sbx login … --password-stdin`
and saves both to the credentials file only on success. On rejection it explains, shows sbx's
message without the token, and re-prompts, at most 3 times; nothing is written.

Saving adds the setter to ticket 01's reader: rewrite that one `NAME=value` line in place, or
append it if absent; keep every other line and comment; write through a temp file and `mv`;
create the directory if needed; best-effort `chmod 600`.

Output uses the existing UI helpers, like the rest of foreman. It never echoes a value.

See `.scratch/credentials-setup/spec.md`.

**Acceptance criteria:**

- [ ] With a stub `sbx` that accepts, piped answers save both Docker keys to the file
- [ ] A rejected token is not saved and re-prompts; three rejections end with a non-zero exit
- [ ] The setter replaces an existing line in place and keeps other lines and comments
      (including an existing `FOREMAN_CLAUDE_TOKEN` line) byte for byte
- [ ] The setter creates a missing directory and file
- [ ] Output never contains the sentinel token; argv to `sbx` never contains it
- [ ] Full smoke suite stays green
