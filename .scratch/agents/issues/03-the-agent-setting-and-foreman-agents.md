# 03: The agent setting, and `foreman agents` for Claude

**Status:** ready-for-agent

**Blocked by:** 01, 02

**What to build:**

A batch can name its agent, and the user can see what agents and models exist (spec:
"Configuration", "`foreman agents`"; user stories 1–6, 9, 11, 12–14, 18–21, 26). Only
Claude exists yet, so the visible change is the new setting, the new command and the
agent named in what foreman prints.

- `FOREMAN_AGENT` (default `claude`), and `foreman run --agent` and `--model`, following the existing precedence (environment over conf over default). The conf template documents them.
- `FOREMAN_MODEL`'s default comes from the agent (Claude: `claude-sonnet-5-5`, unchanged).
- Claude's agent file lists its models, each with its effort levels and default level, kept by hand.
- Preflight refuses, before anything is spent, a model the agent does not offer and an effort level the batch's model does not offer, naming the valid ones.
- `foreman status`, `foreman dry-run` and the run's opening line name the agent beside the model and effort; their machine-readable forms gain an `agent` line.
- `foreman agents`, a free action: each agent in the agent directory, whether its program is installed and logged in, and its models with their effort levels and default level, the default model marked, and where the list came from ("built in"). Plain output follows the existing plain-output rules; a machine-readable form, as `foreman status` has, is what the app will read. `foreman help` lists it.
- Agents are discovered from the agent directory; nothing else holds a list of them.

- [ ] `FOREMAN_AGENT=claude` and no setting at all behave identically; an unknown agent name is refused with the list of agents
- [ ] `--agent` and `--model` override the conf for one run
- [ ] Preflight refuses an unknown model and an unoffered effort level, spending nothing, with a smoke case for each
- [ ] Status, dry-run and the run's opening line name the agent; their goldens are updated deliberately in this ticket and in no other way
- [ ] `foreman agents` has a plain-output golden and a machine-readable form covered by a smoke case
- [ ] `foreman agents` is marked free wherever free actions are listed
- [ ] The full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
