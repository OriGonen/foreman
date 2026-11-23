# 04: The Antigravity capture script

**Status:** ready-for-agent

**Blocked by:** None (can start immediately)

**What to build:**

A script the user runs by hand, in ticket 05, against the real `agy` on this machine. It
answers as many of the spec's "What the smoke test must find out" questions as can be
answered by running `agy`, and saves what `agy` actually printed so that tickets 06–11 are
written against real output. No agent can run it, because the agent's sandbox has no `agy`
and no login.

The script takes the login being captured (`signin` or `key`) and an output directory
(default: a `capture/<login>/` directory inside this spec's directory). It makes a
throwaway git repository of its own, never touches the user's repositories, and for each
probe saves the command it ran, stdout, stderr, exit status and duration as separate files.

Probes, each on the login's default model (Hydrogen for a key, 3.8 Flash signed in), so a
free-tier key spends nothing:

- `agy --version`, `agy models`, and `agy -p "/effort" --output-format json` for each listed model
- a successful headless turn in `json` and in `stream-json` that edits and commits a file
- a turn whose tool call is denied (permissions not granted), to capture the stderr notice and the exit status
- an unknown model; an effort level the model lacks; a suffixed model id together with a different `--effort`, recording which level the envelope or `/effort` reports
- a slash-command skill run in `-p` (a tiny skill the script installs into a temporary skills directory, removed afterwards), and whether it spends tokens
- the first run in a folder `agy` has not seen before, to show whether folder trust stops a headless run
- a shell command that runs longer than two minutes, to find the shell tool's time limit
- a request for a model the plan does not include (e.g. Gemini 4 Neon on a free key or on Plus), to capture the not-available or quota text
- three timed turns of each of: the loop's real checkpoint-turn prompt and its real review-turn prompt, rendered for a fake ticket with an uncommitted change in the throwaway repository

Before saving anything the script replaces the value of `GEMINI_API_KEY` and any e-mail
address with placeholders. It prints a summary table at the end (probe, exit status,
duration, one line of output) and, last, the sandbox steps for the user to try by hand
in ticket 05 (it does not create sandboxes itself).

- [ ] The script exists beside the other test scripts, with a header saying what it does, what it spends (nothing on a free-tier key) and how to run it
- [ ] Every probe above is implemented and saves command, stdout, stderr, exit status and duration
- [ ] It works only inside its own throwaway repository and temporary directories, and removes them on exit
- [ ] Saved files never contain the API key's value or an e-mail address (tested)
- [ ] A smoke case runs it end to end against a stub `agy` on PATH that prints canned output
- [ ] The full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
