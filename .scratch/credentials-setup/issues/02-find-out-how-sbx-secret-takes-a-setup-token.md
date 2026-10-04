# 02: Find out how `sbx secret` handles a `claude setup-token` token

**Status:** ready-for-human
**Handoff:** .scratch/credentials-setup/handoff/02-find-out-how-sbx-secret-takes-a-setup-token.md

**Blocked by:** None (can start immediately)

**What to do:**

Ticket 03 will have the sandbox preflight put a long-lived Claude token into the sandbox's
`anthropic` secret before every run. Four things about `sbx` could not be confirmed
read-only, and they touch real secrets, so you try them and write the answers in the
handoff file.

1. Run `claude setup-token` and keep the token somewhere safe (not in any repo).
2. Scoped first: `sbx secret set anthropic --sandbox ralph-tldw`, paste the token, then run
   an agent in that sandbox. Does it authenticate and bill against the subscription?
   If not, does an Anthropic API key in the same slot work instead?
3. Run `sbx secret set anthropic` again while one exists. Does it overwrite silently,
   prompt, or fail? Same question for the global (unscoped) secret, and when the existing
   one is `(oauth configured)`.
4. Change the global secret and restart the existing `ralph-tldw` sandbox. Does it pick up
   the new value?
5. Does the custom secret `ANTHROPIC_API_KEY` → `openrouter.ai` interfere with any of the
   above?

Why this is a human ticket: it needs real credentials, a browser login and judgment about
billing. Never write a token's value into the handoff file; say where it is stored instead.

**Acceptance criteria:**

- [ ] Whether the anthropic slot accepts a setup-token token, or only an API key, is recorded
- [ ] What re-setting an existing secret does (global, scoped, over oauth) is recorded
- [ ] Whether an existing sandbox picks up a changed global secret is recorded
- [ ] Whether the openrouter custom secret interferes is recorded
- [ ] The exact `sbx` output for a rejected/invalid token is pasted (value redacted)
