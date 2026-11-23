# 11: Antigravity setup calls and skills

**Status:** ready-for-agent

**Blocked by:** 08

**What to build:**

A batch set up for Antigravity never needs Claude: `foreman init`'s ordering and
`foreman commands` run on the batch's agent, and foreman's skills are installed where
Antigravity reads them (spec: "Setup calls and skills"; user stories 17, 69–72).

- Ordering and `foreman commands` use the batch's own agent (never the fallback) with `FOREMAN_ORDERING_MODEL` or the batch's model, at effort `high` or the highest level the model has below it. `FOREMAN_ORDERING_MODEL` must be a model of the batch's agent; preflight says so if not.
- Under Antigravity, `foreman commands` runs the `foreman-conf-commands` skill by its slash command if the findings show `agy -p` supports that, otherwise it sends the skill's text as the prompt with the batch directory filled in.
- `install.sh` copies foreman's skills to Antigravity's skills directory (`~/.gemini/config/skills`) as well as Claude's when `agy` is installed, honouring `--no-skill`, and removes nothing of Antigravity's own.

- [ ] Stub `agy` smoke cases run the ordering call and `foreman commands` for an Antigravity batch and assert the command line and the result written
- [ ] Effort for setup calls falls to the highest level below `high` on a model without `high` (smoke case)
- [ ] A Claude model in `FOREMAN_ORDERING_MODEL` on an Antigravity batch is refused with a clear message
- [ ] `install.sh` puts the skills in both directories when `agy` is installed and only Claude's when it is not; its plain-output golden is updated deliberately
- [ ] Claude's ordering and `foreman commands` are unchanged
- [ ] The full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
