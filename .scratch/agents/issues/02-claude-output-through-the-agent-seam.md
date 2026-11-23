# 02: Reading Claude's output goes through the agent seam

**Status:** ready-for-agent

**Blocked by:** None (can start immediately)

**What to build:**

The second half of moving Claude behind the agent seam, on the node side (spec: "The agent
seam"). Afterwards the recorder, the `--live` stream labeler and the failure patterns know
nothing about Claude's output format; they work from one canonical result that each
agent's node module produces.

Add Claude's node module to the agent directory. It turns a turn's raw output (stdout,
and stderr where the adapter kept it) into the canonical result: the reply, error state, a
failure class (usage limit, transient, auth, denial, context overflow, other), token
usage, cost and whether the cost is an estimate (never, for Claude), number of steps and
duration. It also yields the tool-call events the stream labeler draws. Claude's existing
usage-limit, auth and denial patterns and its reply extraction move into it.

The recorder and stream labeler take the agent's name (always `claude` for now) and load
its module. The verdict's keys and values do not change in this ticket.

- [ ] Claude's node module exists in the agent directory and produces the canonical result, documented in its header
- [ ] The recorder, the stream labeler and the failure-pattern code contain no Claude-specific parsing or strings
- [ ] Every existing recorder and stream node test passes unchanged, run through the module
- [ ] New node tests for Claude's module cover each failure class from the existing fixtures
- [ ] Every golden file is unchanged
- [ ] The full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
