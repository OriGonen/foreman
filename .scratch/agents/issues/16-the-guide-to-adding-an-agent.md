# 16: The guide to adding an agent, and the README

**Status:** ready-for-agent

**Blocked by:** 11, 13, 14

**What to build:**

A future coding agent can add a third agent by following a checklist, and a user can learn
everything in this spec from the README (spec: "Documentation"; user stories 89–91;
ADR 0006).

- A guide beside the agent files, written for a coding agent as a checklist, each step naming what to add and the test that proves it: the shell file's functions; the node module and its canonical result; failure strings and their fixtures; the prompt paragraph about long checks; the model list (built in, or the agent cache); default models per login; effort levels; the price table, or a reported cost; the sandbox kit and how the login gets in; the skills directory; doctor's checks; the app's labels; the `fake` adapter's output format; and the golden and smoke cases to add. It says what never needs touching (anything outside the agent directory that discovers agents from it).
- `CLAUDE.md` points to the guide in one line.
- The README covers choosing an agent and model, effort across agents, `foreman agents` and the agent cache, Antigravity's two logins and the consumer-plan note, the fallback agent and what it does at a usage limit, and costs shown as estimates.

- [ ] The guide exists beside the agent files and covers every step above
- [ ] Each step of the guide is checked against the actual code: every function, file kind and test it names exists
- [ ] `CLAUDE.md` has one line pointing to the guide
- [ ] The README sections exist and match the behaviour shipped in tickets 01–15
- [ ] `CONTEXT.md`'s terms (agent, effort, agent cache, fallback agent, turn, sandbox) still match the behaviour; any drift is fixed there
