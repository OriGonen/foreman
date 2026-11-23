---
status: accepted
---

# Gemini models are driven through the Antigravity CLI, not the Gemini CLI

To run turns on Gemini models, foreman invokes Google's Antigravity CLI (`agy`), not the
Gemini CLI, even though "Gemini CLI" is the name anyone would reach for first.

## Considered options

**Gemini CLI** was the obvious choice, and Docker's `sbx` once shipped a `gemini` agent for
it. It was rejected because it now serves enterprise and paid accounts only, is not tuned
for the Gemini 4 models, and its `sbx` kit is retired (`sbx` 0.53.0 dropped the `gemini`
agent name), so a sandbox for it would be foreman's to maintain against a tool Google is
moving away from.

**Antigravity CLI** documents a headless mode (`agy -p`) "intended for direct scripting and
CI workflows", a JSON envelope with a status and token usage, per-invocation `--model` and
`--effort`, and works with both a Google account sign-in and an AI Studio API key. Its
costs: no cost figure (foreman estimates one from tokens), no turn cap (the checkpoint and
review turns are limited by time instead), tool denials that still exit 0 (found on
stderr), and no documented usage-limit message yet.

## Consequences

The agent is named `antigravity` in configuration, not `gemini`: an agent is the program,
and Gemini is the model family it runs. Reversing this means writing a second agent file
and sandbox setup; nothing outside the agent directory would change.
