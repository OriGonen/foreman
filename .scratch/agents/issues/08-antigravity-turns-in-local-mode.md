# 08: Antigravity turns in local mode

**Status:** ready-for-agent

**Blocked by:** 07

**What to build:**

An Antigravity batch runs in `local` mode and ends every turn in the verdict a Claude turn
would (spec: "The Antigravity agent"; user stories 10, 31, 33–34, 36–43). Read the spec's
"Smoke test findings" first; they override anything provisional below.

- Antigravity's command line for a turn: `agy -p` with `--output-format json` (or `stream-json` for `--live`), `--model` with the bare model id, `--effort`, `FOREMAN_ANTIGRAVITY_ARGS`, and for checkpoint and review turns `--print-timeout` set to the limits the findings gave. Its environment, its prompt paragraph about long checks, and its hints (install, log in again, the denial hint without Claude's allowlist suggestion).
- Antigravity's node module: the envelope's `status`, `response`, `error`, `usage`, `num_turns` and `duration_seconds` become the canonical result; every status maps as the findings say; a soft-denied tool call is found by its stderr notice and becomes a denial even though the exit status is 0; auth, context-overflow and (if known) usage-limit texts become their failure classes. The adapters keep stderr for it. Cost stays unset here (ticket 09).
- A checkpoint or review turn that hits its time limit is an unsalvaged stall: the work stays uncommitted and the stall marker stays for the next run's review turn.
- `foreman run --live` labels Antigravity's tool calls from its `stream-json` events.
- Local mode's permissions: the project-level allow list if the findings found one; otherwise preflight refuses local mode with Antigravity unless `FOREMAN_ANTIGRAVITY_ARGS` is set, saying why.
- The `fake` adapter answers in Antigravity's format when the batch's agent is Antigravity — its envelope, its stderr denial notice, its stream events — so every existing fake behaviour works for both agents, plus `deny-soft` and a checkpoint that hits its time limit.
- The verdict gains `agent`.
- Remove ticket 07's "not built yet" stop for local mode.

- [ ] The recorder's node tests turn every captured Antigravity output from the fixtures into the right verdict, including the soft denial
- [ ] The stream labeler's node tests label captured Antigravity stream events
- [ ] Smoke cases on the fake adapter take an Antigravity batch to every ending: landed, progressed, stalled and checkpointed, error, transient, usage limit, denial, and a checkpoint that hits its time limit
- [ ] A stub `agy` smoke case asserts the local mode's command line and environment for a turn, a checkpoint turn and a review turn
- [ ] Denial and log-in hints name Antigravity and never suggest Claude's allowlist
- [ ] Verdicts and the run's JSONL record name the agent; goldens that show them are updated deliberately
- [ ] Claude's command lines, verdict values other than the new `agent` key, and every other golden are unchanged
- [ ] The full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
