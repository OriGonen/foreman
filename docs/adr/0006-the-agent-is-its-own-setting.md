---
status: accepted
---

# The agent is its own setting, not another execution mode

Which agent runs a turn (`FOREMAN_AGENT`) is a second setting beside where it runs
(`FOREMAN_EXEC`), with its own directory of agent files beside the execution adapters.
It is not folded into the execution modes.

## Considered options

**More execution modes** (`antigravity-local`, `antigravity-sandbox`, …) was the shortcut:
the adapter seam already exists and nothing new would be needed. It was rejected because
the modes would multiply with every agent (three real modes per agent), each pair would
repeat the other's Claude- or Antigravity-specific code, and a fallback agent would have
to switch execution mode mid-run to switch agent.

**A second seam** costs one more directory and one more fixed set of functions, and the
move of every Claude-specific line — command lines, failure strings, hints, the prompt's
paragraph on long checks — behind it. In exchange every agent works in every mode, the
adapters stay about where things run, and a fallback switches agent without touching the
mode.

## Consequences

Adding an agent is adding files to the agent directory and following its guide; nothing
else holds a list of agents. Claude moved behind the seam first, with every golden
unchanged, before any second agent was written.
