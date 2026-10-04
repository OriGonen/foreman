# Handoff — 02: Find out how `sbx secret` handles a `claude setup-token` token

<!-- Fill in every section below, then set ticket 02's status line to done, tick its boxes and
     commit. Ticket 02a-followup-find-out-how-sbx-secret-takes-a-setup-token.md checks this file.
     This file is committed and read by an agent: record a secret by WHERE it is stored, never
     its value. -->

## Whether the anthropic slot accepts a setup-token token, or only an API key, is recorded

Token stored in ~/.config/ralph/env as RALPH_CLAUDE_TOKEN

**Result: NO. The anthropic slot does not accept a `claude setup-token` token** (sbx v0.39.0, Claude Code 2.1.221 in the sandbox).

Clean test on `ralph-excuse-me`, which answered `claude -p "Reply with the single word ok"` with `ok` on the global oauth before the test:

1. `sbx secret set anthropic --sandbox ralph-excuse-me`, token entered at the `Enter secret:` prompt.
2. `sbx run --name ralph-excuse-me -- -p "Reply with the single word ok"` -> `Failed to authenticate. API Error: 401 API key is invalid.` (exit 1).

So the slot treats whatever it holds as an API key (it is sent as an API key and Anthropic rejects an `sk-ant-oat…` token there). Reproduced on a fresh throwaway sandbox `ralph-s02` (global oauth gave `ok` first; after `sbx secret set anthropic --sandbox ralph-s02` with the setup-token, `sbx run … -- --model haiku -p "Reply with the single word ok"` gave the same 401).

**API-key fallback: not tried, by decision** (the owner will not use an API key for this). So it is unknown whether an `sk-ant-api…` key in the slot works; only the setup-token path is proven dead.

`sbx secret set` does no validation: it saved and applied the token without complaint, and the failure only shows up when an agent makes a request.

Side finding that matters for ticket 03: `ralph-tldw` fails with `Failed to authenticate: OAuth session expired and could not be refreshed` even with only the global oauth and no scoped secret. Its `~/.claude/.credentials.json` is stale (`expiresAt: 0`, not rewritten on start) and it runs Claude Code 2.1.287, while `ralph-excuse-me` runs 2.1.221 and gets its login file refreshed on start. A preflight that only reads `sbx secret ls` would call `ralph-tldw` healthy. The ticket's `ralph-tldw` experiments were redone on `ralph-excuse-me` for that reason.

<!-- -->

## What re-setting an existing secret does (global, scoped, over oauth) is recorded

sbx v0.39.0. Scoped tests ran on `ralph-s02` with dummy values; none of them silently overwrites.

| Command (existing secret present) | Result | Exit |
|---|---|---|
| `echo dummy \| sbx secret set anthropic --sandbox S` (stdin) | prints the existing secret masked, asks `Secret already exists. Overwrite? (y/N):`, the piped text is consumed as the answer -> `Cancelled`, nothing changed | **0** |
| `sbx secret set anthropic --sandbox S --token dummy` | `ERROR: secret already exists for service "anthropic" in scope "S"; rerun with -f to overwrite` | 1 |
| same with `-f` | `Saved secret for service "anthropic" in scope "S"` + `Applied secret for sandbox "S"` | 0 |
| `sbx secret set anthropic --token dummy` over global `(oauth configured)` | `ERROR: anthropic OAuth token already exists for scope "(global)"; rerun with -f to overwrite`; `sbx secret ls` afterwards still `(oauth configured)` | 1 |

Traps for ticket 03:
- Piping a value on stdin to an existing secret does **not** overwrite and still exits 0 (`Cancelled`). A preflight must use `--token … -f` (or check `sbx secret ls` first), not rely on the exit code of the stdin form.
- Global over oauth needs `-f` like any other secret; without it nothing is lost.
- Not tested: `-f` over the global oauth and global-over-global, because overwriting `(oauth configured)` would cost the global login (restorable only by `/login` in a sandbox).
- `sbx secret set --help` also offers `--command '<cmd>'` / `--ref` (1Password / AWS ARN), which store a *source* resolved on the host at use time (refresh default 55m). Untested here; relevant to how the preflight could supply the token without a literal value.

<!-- -->

## Whether an existing sandbox picks up a changed global secret is recorded

**Not tested, by decision.** Changing the global secret means overwriting the global `(oauth configured)` login (`-f` is required, see above), which can only be restored with `/login` inside a sandbox. The owner chose not to risk it.

Evidence that does exist: a scoped `sbx secret set … --sandbox S -f` on an existing sandbox prints `Applied secret for sandbox "S"`, and the next `sbx run` used the new value (the setup-token 401 appeared right after the set, without recreating the sandbox). Whether that also holds for a *global* change on a sandbox that has no scoped secret is unknown; ticket 03's preflight should not assume it and can sidestep it by setting the scoped secret on the specific sandbox.

<!-- -->

## Whether the openrouter custom secret interferes is recorded

**No interference observed, but the custom secret was never removed, so it is not proven.** The global custom secret `ANTHROPIC_API_KEY` -> `openrouter.ai` (placeholder `sbx-cs-…`) was present for every test:

- Global oauth: `claude -p` answered `ok` on a fresh sandbox (`ralph-s02`) with the openrouter secret present.
- Scoped setup-token: the 401 matches what the previous sandbox gave, and the openrouter secret was present both times. It does not tell us whether the placeholder changed which credential Claude Code picked.
- `sbx secret set-custom --help`: the proxy only swaps the placeholder in requests to the target host (`openrouter.ai`), so it cannot alter what `api.anthropic.com` receives.
- `sbx exec ralph-s02 printenv ANTHROPIC_API_KEY` printed nothing, i.e. the env var is not set in the `exec` context. That may differ from the env the agent process gets, so it is weak evidence only.

Not done: removing the openrouter secret and re-running the setup-token test, because `sbx secret rm` would discard a real key the owner may not have kept elsewhere.

<!-- -->

## The exact `sbx` output for a rejected/invalid token is pasted (value redacted)

`sbx secret set` itself prints no error for a token the API will reject:

```
PS C:\Projects> sbx secret set anthropic --sandbox ralph-excuse-me
Enter secret:
Saved secret for service "anthropic" in scope "ralph-excuse-me"
Applied secret for sandbox "ralph-excuse-me"
```

The rejection comes from the agent on the first request:

```
PS C:\Projects> sbx run --name ralph-excuse-me -- -p "Reply with the single word ok"
Attaching to existing sandbox "ralph-excuse-me" (workspace: C:\Projects\excuse-me).
Sandbox ralph-excuse-me started successfully
Starting claude agent in sandbox 'ralph-excuse-me'...
Workspace: C:\Projects\excuse-me
Failed to authenticate. API Error: 401 API key is invalid.
ERROR: agent exited with code 1
```

`sbx secret ls` shows a stored scoped secret as `(stored)`; `sbx secret rm anthropic --sandbox <name> -f` prints it masked as `sk-ant******...******<last4>` before deleting.

<!-- -->
