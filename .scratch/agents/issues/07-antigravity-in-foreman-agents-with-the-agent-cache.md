# 07: Antigravity in `foreman agents`, with the agent cache

**Status:** ready-for-agent

**Blocked by:** 03, 06

**What to build:**

Antigravity appears as an agent the user can choose and inspect, though it cannot run
turns yet (spec: "The Antigravity agent", "The agent cache", "`foreman agents`"; user
stories 7–8, 22–30). Read the spec's "Smoke test findings" first.

- Antigravity's shell file in the agent directory: its program (`agy`) and display name; whether it is installed; whether it is logged in and with which login — an API key when Antigravity's settings name `"modelProvider": "gemini"` and `GEMINI_API_KEY` is set, otherwise a Google account sign-in. Foreman reads Antigravity's settings and never writes them.
- Its default model by login: `gemini-4-hydrogen` with a key, `gemini-3.8-flash` signed in (or as the findings revised them).
- The agent cache: one JSON file per agent under the user's cache directory (`$XDG_CACHE_HOME`, else `~/.cache`, then `foreman/agents/`), recording the login it was built under, when, and each model with its effort levels and default level. Built from `agy models` and `/effort` per model, as the findings say works. Rebuilt when older than 7 days, when the login differs from the recorded one, when a batch names a model it does not list, when missing or unreadable, and on `foreman agents --refresh`. Claude has no cache.
- `foreman agents` lists Antigravity with its install and login state, its models and levels from the cache with the cache's date, and, when signed in with a Google account, one line saying Google does not support wrapping `agy` under consumer plans.
- Preflight's model and effort checks work for an Antigravity batch from the cache.
- Until ticket 08, a run with `FOREMAN_AGENT=antigravity` stops in preflight saying Antigravity turns are not built yet, spending nothing.

- [ ] Antigravity's shell file exists and implements the install, login, default-model and model-list functions
- [ ] Login detection is tested for both logins and for not logged in, with a stub `agy` and a temporary home directory
- [ ] Each cache refresh rule is covered by a smoke case with a stub `agy` that counts its calls; a fresh cache costs no `agy` call
- [ ] Deleting the cache is harmless: the next command rebuilds it
- [ ] Foreman never writes Antigravity's settings (asserted by a smoke case comparing the settings file before and after)
- [ ] `foreman agents` with Antigravity has a plain-output golden for each login, and its machine-readable form includes Antigravity
- [ ] Preflight refuses an Antigravity model or effort level the cache does not list
- [ ] The full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
