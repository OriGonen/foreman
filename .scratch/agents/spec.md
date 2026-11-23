# Spec — a second agent: Antigravity, and a fallback agent for usage limits

**Status:** ready-for-agent

Vocabulary: `CONTEXT.md` (new terms: **agent**, **effort**, **agent cache**, **fallback agent**;
changed: **turn**, **sandbox**). Decision records:
`docs/adr/0005-antigravity-cli-not-gemini-cli.md`,
`docs/adr/0006-the-agent-is-its-own-setting.md`. The review turn this builds on:
`docs/adr/0002-in-flight-marker-and-review-turn.md`. The checkpoint turn it limits:
`docs/adr/0001-checkpoint-turn-over-session-resume.md`.

## Problem Statement

Foreman can only drive one agent: Claude Code. Every turn, every setup call, every failure
string it recognises, every hint it prints, the prompt's paragraph about long checks, the
sandbox it creates and the app's screens assume `claude`.

That costs the user in two ways.

**A usage limit ends the run.** The user works on a subscription. When it hits its limit
mid-run, the loop pauses, and the batch waits until the limit resets — hours, sometimes a
day — even though the user has a second account, with another company's models, sitting
idle.

**There is no way to try a different model family.** The user has a Google AI Plus
subscription and a free Google AI Studio API key, and wants to run batches on Gemini
models — either as the batch's agent from the start, or as the one that takes over when
Claude runs out. Foreman has no setting for it, and nothing in it could run another
program in Claude's place.

## Solution

A batch names its **agent** — Claude Code (`claude`, the default) or Google's Antigravity
CLI (`agy`) — and a model and **effort** for it. Everything that today assumes Claude asks
the batch's agent instead, so an Antigravity batch runs the same loop, with the same
tickets, the same verdicts, the same stops, in all three real execution modes.

A batch may also name a **fallback agent**. When its agent hits a usage limit mid-run, the
fallback takes over for the rest of that run, starting with a review turn on whatever the
first agent left uncommitted. The next run starts with the batch's own agent again.

The user can see what is available with `foreman agents`: each agent, whether it is
installed and logged in, and its models with their effort levels. Doctor checks the login
of every agent the batch names, and the sandbox's. The app's run settings gain an agent,
model and fallback picker. Every turn still reports what it would cost at API prices —
Claude's figure from Claude Code, Antigravity's as foreman's own estimate — whether the
agent runs on a subscription or a key.

Antigravity works with either of its logins: a Google account sign-in (the user's Plus
subscription) or an AI Studio API key. Foreman uses whichever one Antigravity is set up
with, says which, and never changes it.

## User Stories

### Choosing the agent

1. As a batch author, I want to set `FOREMAN_AGENT=antigravity` in a batch's `foreman.conf`, so that the batch is worked by Antigravity instead of Claude.
2. As a batch author, I want `FOREMAN_AGENT` to default to `claude`, so that every existing batch behaves exactly as it does today.
3. As an operator, I want `foreman run --agent antigravity` to override the batch's agent for one run, so that I can try another agent without editing the conf.
4. As an operator, I want `foreman run --model <id>` to override the model for one run, so that I can switch model as easily as agent.
5. As a batch author, I want `FOREMAN_MODEL` to default to the agent's own default model, so that naming only the agent gives a sensible model.
6. As a Claude user, I want Claude's default model to stay `claude-sonnet-5-5`, so that nothing changes for me.
7. As an Antigravity user on an API key, I want the default model to be `gemini-4-hydrogen`, so that a free-tier key works out of the box.
8. As an Antigravity user signed in with Plus, I want the default model to be `gemini-3.8-flash`, so that the default is a model my plan actually has.
9. As an operator, I want a run to refuse to start when the batch names a model its agent does not offer, so that I find out before spending anything.
10. As a batch author, I want `FOREMAN_ANTIGRAVITY_ARGS` alongside `FOREMAN_CLAUDE_ARGS`, so that I can pass agent-specific flags without foreman knowing about them.
11. As an operator, I want `foreman status`, `foreman dry-run` and the run's opening line to name the agent, model, effort and fallback, so that I always know what a run will use.

### Effort

12. As a batch author, I want `FOREMAN_EFFORT` to keep its meaning and its default of `high` for both agents, so that one setting covers the batch.
13. As an operator, I want foreman to pass the effort level to the agent unchanged, so that `high` means whatever the agent's own `high` means, with no translation table to go stale.
14. As an operator, I want a run to refuse to start when the batch's model does not offer the batch's effort level, so that I am not silently given another level.
15. As an operator, I want the fallback agent to use the batch's effort level, or the highest level its model has below it, so that I don't configure effort twice and a fallback is never dropped to a much lower level.
16. As an operator, I want foreman to say once, when the fallback takes over, if it had to lower the effort level, so that the change is visible.
17. As an operator, I want the setup calls (ordering, `foreman commands`) to stay at `high`, or the highest level the model has below it, so that they work on every model.

### Listing agents and models

18. As a user, I want `foreman agents` to list every agent foreman supports, so that I know what I can choose from.
19. As a user, I want `foreman agents` to show, for each agent, whether it is installed and whether it is logged in, and with which login (signed in or API key), so that I can see what is ready.
20. As a user, I want `foreman agents` to list each agent's models with their effort levels and default level, and to mark the default model, so that I can choose a model and effort that exist.
21. As a user, I want `foreman agents` to be a free action, so that I can run it at any time without spending anything.
22. As a user, I want `foreman agents --refresh` to rebuild what foreman knows about an agent's models, so that a new model shows up when I want it to.
23. As a user, I want foreman to look up Antigravity's models and levels once and keep them in the agent cache, so that commands don't pay for the lookup every time.
24. As a user, I want the agent cache refreshed by itself when it is a week old, when Antigravity's login changes, or when a batch names a model it does not know, so that it does not go stale without my noticing.
25. As a user, I want deleting the agent cache to be always safe, so that I never have to repair it.
26. As the app, I want `foreman agents` to have a machine-readable form, so that the run settings' pickers show exactly what the CLI knows.

### Antigravity's two logins

27. As an Antigravity user, I want foreman to work whether Antigravity is signed in with my Google account or set up with an AI Studio API key, so that I can use either my Plus subscription or my key.
28. As an Antigravity user, I want foreman to read which login Antigravity is using and never change Antigravity's settings, so that my setup stays mine.
29. As a user signed in with a consumer plan, I want the docs and `foreman agents` to tell me once that Google does not support wrapping `agy` under consumer plans, so that I choose knowingly.
30. As a user, I want switching between Antigravity's logins to need no change in foreman, so that the next run simply uses the new login and its default model.

### Running Antigravity turns

31. As an operator, I want an Antigravity turn to end in the same verdict a Claude turn would — landed, progressed, stalled, error, usage limit, denied, context overflow — so that every stop and continuation works the same.
32. As an operator, I want Antigravity to run in the `local`, `sandbox` and `sandbox-mount` modes, so that choosing an agent never limits where it runs.
33. As an operator, I want a denied tool call under Antigravity, which still exits 0 with only a notice on stderr, to stop the run as a denial does today, so that a silent denial is never read as a clean turn.
34. As an operator, I want the denial stop to name the denied call and give a hint that fits the agent, so that I am not told to edit Claude's allowlist when Antigravity denied it.
35. As an operator, I want Antigravity's permission checks skipped in the sandbox modes, so that the sandbox is the boundary there, as it is for Claude.
36. As an operator, I want Antigravity in local mode to use a project-level allow list if Antigravity supports one, and doctor to refuse local mode with Antigravity otherwise unless `FOREMAN_ANTIGRAVITY_ARGS` is set, so that a local Antigravity run never silently does nothing.
37. As an operator, I want `foreman run --live` to show an Antigravity turn's tool calls as it does Claude's, so that I can watch either agent.
38. As an operator, I want the hints foreman prints (log in again, install, the permission hint) to name the agent that needs them, so that I am never told to run `claude login` for an Antigravity batch.
39. As an agent running a ticket, I want the prompt's paragraph about long checks to describe my own shell tool, so that I can follow it.

### The checkpoint and review turns under Antigravity

40. As an operator, I want an Antigravity checkpoint turn limited to 3 minutes, so that the short turn stays short where Claude's is limited to 10 steps.
41. As an operator, I want an Antigravity review turn limited to 6 minutes, so that it has room to read the diff against the ticket first, as Claude's 20 steps do.
42. As an operator, I want a checkpoint or review turn that hits its time limit treated as an unsalvaged stall, so that the work stays put for the next run's review turn instead of being lost.
43. As a maintainer, I want both time limits to be provisional until the smoke test has timed real Antigravity checkpoint and review turns, and then set to about three times the typical length, so that the limits are well above a normal turn without being guesses.

### The fallback agent

44. As a batch author, I want to set `FOREMAN_FALLBACK_AGENT` (and optionally `FOREMAN_FALLBACK_MODEL`), so that a usage limit does not end my run.
45. As a batch author, I want no fallback by default, so that existing batches never switch agent unexpectedly.
46. As a batch author, I want the fallback's model to default to that agent's default model, so that naming the fallback agent is enough.
47. As an operator, I want the fallback to take over only at a usage limit, so that a lost login, a denied tool call or an overflowing context still stop the run for me to look at.
48. As an operator, I want the fallback to keep the work for the rest of the run, so that the run does not flap between agents guessing when a limit has reset.
49. As an operator, I want the next `foreman run` to start with the batch's own agent again, so that the fallback is only ever a stand-in.
50. As an operator, I want the fallback's first turn to be a review turn on whatever the first agent left uncommitted, so that half-done work is checked and committed as `wip:` before anything builds on it.
51. As an operator in clone sandbox mode, I want foreman to carry the first agent's uncommitted work from its sandbox's clone into the fallback's, so that the fallback's review turn sees it.
52. As an operator, I want the stall marker to record which agent's sandbox the work is in, so that the next run, whichever agent it starts with, finds the work and carries it over first.
53. As an operator, I want a run whose fallback also hits a usage limit to pause as today, so that nothing loops.
54. As an operator, I want a run to check the fallback agent's install, login, model and price before it starts and warn me if it is not ready, so that I learn it is broken before the moment I need it.
55. As an operator who has only one agent installed or one subscription, I want a fallback that is not ready never to stop the run from starting, so that foreman never forces me to install both agents or pay for both.
56. As an operator, I want a usage limit hit while the fallback is not ready to pause the run as it does today, saying why the fallback could not take over, so that an unready fallback costs nothing more than having none.
57. As an operator, I want the run's output, logs and report to show which agent ran each turn, so that I can see when and why the fallback took over.
58. As an operator, I want the takeover announced in the terminal and the app, so that I notice it while it happens.

### Sandboxes

59. As an operator with an existing Claude sandbox, I want its name to stay `foreman-<repo>`, so that it keeps working after the upgrade.
60. As an operator, I want an Antigravity sandbox named `foreman-<repo>-antigravity`, so that the two agents never share a sandbox an agent was not created for.
61. As an operator, I want foreman to create the Antigravity sandbox the way the smoke test found works (a maintained kit if one exists, otherwise a custom kit on Docker's shell image), so that `foreman run` sets it up like Claude's.
62. As an operator, I want the Antigravity sandbox to get Antigravity's login (a sign-in inside the sandbox, or the API key passed in as the smoke test found works), so that turns in it are authenticated.

### Doctor

63. As a user, I want doctor to check every agent the batch names — installed, logged in and with which login — failing for the batch's own agent and only warning for the fallback, so that I know whether the fallback is ready without being made to set it up.
64. As a user, I want doctor to check the `sbx` login in the sandbox modes, so that an expired sandbox login is caught before a run.
65. As a user, I want doctor to check that the batch's model and effort exist for its agent, and that the fallback's do, so that a typo is caught for free.
66. As a user, I want doctor to report if Antigravity needs to trust the repository's folder and print the command for me to run, so that a run does not stop on it, while foreman still never writes Antigravity's settings.
67. As a user, I want doctor to check that foreman's skills are installed where each installed agent reads them, so that `foreman commands` works under either agent.
68. As a user, I want doctor's checks for a Claude-only batch to read as they do today, apart from any check deliberately added, so that nothing I rely on moves.

### Setup calls and skills

69. As a batch author, I want `foreman init`'s ordering call and `foreman commands` to use the batch's agent, so that a batch set up for Antigravity never needs Claude.
70. As a batch author, I want `FOREMAN_ORDERING_MODEL` to keep working and to be checked against the batch's agent, so that a Claude model is not passed to Antigravity.
71. As a user, I want `install.sh` to copy foreman's skills into Antigravity's skills directory too when `agy` is installed, so that both agents have them.
72. As a user of `foreman commands` under Antigravity, I want it to run the skill by its slash command if `agy -p` supports that, and otherwise to send the skill's text as the prompt, so that it works either way.

### Cost

73. As an operator, I want every turn to report what it would cost at API prices, for both agents and both of Antigravity's logins, so that I can compare agents and plans by one figure.
74. As an operator, I want Antigravity's cost worked out from its token counts and Google's published prices, with thinking tokens and cache reads priced as Google prices them, so that the estimate is as close as foreman can make it.
75. As an operator, I want an estimated cost marked with "≈" in the terminal, the report and the app, so that I never mistake foreman's estimate for a provider's figure.
76. As a maintainer, I want the price table to give each price with the date it takes effect, so that a price change (Carbon and Argon on Dec 1, Flash on Jan 1) needs one new row and old runs keep the prices they ran at.
77. As an operator, I want a model with no known price shown as "cost unknown", so that a missing price is never shown as $0.
78. As an operator, I want a run with `FOREMAN_MAX_COST_USD` set to refuse to start when its own agent's model has no known price, and to treat a fallback with no known price as not ready, so that a cost budget is never silently unenforced.
79. As an operator, I want the cost budget to count Antigravity's estimate as it counts Claude's figure, so that one budget covers a run that switched agent.

### The app

80. As an app user, I want the run settings to let me choose the agent, then a model from that agent's list, then a fallback agent and model, so that I can start any run from the window.
81. As an app user, I want the run settings to show the effort that will actually be used, including a lowered level for the fallback, so that there are no surprises.
82. As an app user, I want the "can't run" screen to name the missing program ("agy missing"), not "claude / sbx missing", so that it tells me what to install.
83. As an app user, I want the login-expired screen to name the agent whose login expired, so that I know which one to log in to.
84. As an app user, I want the run and report screens to show which agent ran each turn and mark estimated costs with "≈", so that the window says what the terminal says.
85. As an app user, I want the app to read agents, models and levels from the CLI and work out nothing itself, so that the window and the terminal never disagree.

### Getting started and the unknowns

86. As a user, I want the work to begin with a human ticket in which I install `agy`, sign in with my Plus account and create an AI Studio key, so that a real Antigravity is there to learn from.
87. As a maintainer, I want the followup ticket to run a smoke test against the real `agy` and record its actual output, so that the Antigravity agent is written against what `agy` really prints, not what the docs say.
88. As a maintainer, I want the smoke test's findings written into this spec before any Antigravity code is written, so that every later ticket starts from facts.

### Adding an agent later

89. As a future maintainer's coding agent, I want a step-by-step guide to adding an agent beside the agent files, so that adding a third agent is following a checklist.
90. As a future maintainer, I want `CLAUDE.md` to point to that guide, so that a coding agent finds it without searching.
91. As a future maintainer, I want adding an agent to be adding files to the agent directory plus the guide's listed touch points, with nothing else holding a list of agents, so that the change stays small.

### Nothing changes for Claude

92. As an existing user, I want every golden and smoke case to pass unchanged after Claude moves behind the agent seam, so that the refactor is proven to change nothing before Antigravity is added.
93. As an existing user, I want Claude's command lines, environment, prompt and messages byte-for-byte the same after the refactor, so that my runs and costs are unaffected.

## Implementation Decisions

### The agent seam

- A second seam beside the execution adapters: **where** the agent runs (`local`, `sandbox`, `sandbox-mount`, `fake`) stays an adapter; **which** agent runs is an agent file. Every agent works in every mode, and a fallback switches agent without switching mode. See ADR 0006.
- Agents live in one agent directory, one shell file per agent, plus a node module per agent for what the node side needs (output normalisation, stream labels, failure strings). No stubs for agents not being built. Nothing outside that directory holds a list of agents; `foreman agents`, doctor and the app discover them from it, as execution modes are discovered from the adapter directory.
- An agent file implements a fixed set of functions. Each answers one question the rest of foreman used to answer with Claude-specific code:
  - its name, its program, and the name shown to people;
  - whether the program is installed, and whether and how it is logged in;
  - the command line for a turn: prompt, model, effort, permission handling, the batch's extra arguments, output format (single JSON or a stream), and the checkpoint/review limit, expressed in the agent's own terms (Claude: `--max-turns`; Antigravity: `--print-timeout`);
  - the command line for a setup call (a single question with no tools: ordering, `foreman commands`);
  - the environment a turn needs (Claude's raised shell timeout, `BASH_MAX_TIMEOUT_MS`, moves here);
  - its models, each with its effort levels and default level, and its default model for each login;
  - the prompt's paragraph about long checks;
  - the hints foreman prints when it needs logging in, installing, or a permission changed;
  - its sandbox: the `sbx` agent or kit it is created with and how its login gets in;
  - where its skills are installed.
- The node module per agent turns the agent's raw output (stdout, and stderr, which the adapters keep for it) into the one canonical result the recorder already works from: the reply, error state, a failure class (usage limit, transient, auth, denial, context overflow, other), token usage, cost and whether the cost is an estimate, the number of steps and the duration. The recorder, the verdict and everything that reads them stay agent-neutral; a verdict gains `agent` and `cost_estimated`.
- The stream labeler used by `foreman run --live` gets its tool-call events from the same module, so Antigravity's `stream-json` events are labelled as Claude's are.
- Execution adapters ask the agent for the command line and environment and run it where they run things; they keep no Claude-specific text.
- The loop's Claude-specific messages (log in again, the permission hint and its git allowlist suggestion, install hints) and the direct `claude` calls in ordering and `foreman commands` go through the agent.

### The Claude agent

- Moved behind the seam first, with no behaviour change: identical command lines, environment, prompt text, messages and goldens. This lands before any Antigravity code.
- Its model list and levels are kept in its file and updated by hand; Claude Code has no command that lists models. Default model `claude-sonnet-5-5`. Its cost is the figure Claude Code reports.
- Its sandbox keeps the name `foreman-<repo>`.

### The Antigravity agent

- Runs `agy` in headless mode (`-p`) with `--output-format json`, or `stream-json` for `--live`. The JSON envelope's `status` maps onto the canonical result (SUCCESS → ok; ERROR and INVALID → error, classified by its text; CANCELED and INTERRUPTED → interrupted). `WAITING` and anything the smoke test shows is mapped by the smoke test's findings.
- A soft-denied tool call is found by the notice on stderr and classified as a denial, even though the exit status is 0.
- Effort is passed as `--effort` with the bare model id. Whether a suffixed model id would override it is a smoke-test question; foreman never passes a suffixed id itself.
- Default model by login: `gemini-4-hydrogen` with an API key, `gemini-3.8-flash` when signed in.
- Login is read, never written: an API key login is `"modelProvider": "gemini"` in Antigravity's settings plus `GEMINI_API_KEY` in the environment; otherwise it is a Google account sign-in. Per-run switching between them is not supported, because Antigravity has none.
- Checkpoint turn limited by `--print-timeout` of 3 minutes, review turn of 6 minutes; both provisional, to be reset to about three times the typical lengths the smoke test measures. Hitting the limit is an unsalvaged stall.
- Permissions: skipped in the sandbox modes; in local mode a project-level allow list if Antigravity supports one, otherwise doctor refuses local mode with Antigravity unless `FOREMAN_ANTIGRAVITY_ARGS` is set.
- Its prompt paragraph about long checks starts generic — run checks in the foreground, never in the background, split a check too long to finish — until the smoke test finds its shell tool's time limit and how to raise it.
- Its sandbox is `foreman-<repo>-antigravity`. How it is created and how its login gets in are decided by the smoke test, since the local `sbx` lists no Antigravity agent and the two lookups disagree on whether a maintained kit exists.

### Configuration

- New settings: `FOREMAN_AGENT` (default `claude`), `FOREMAN_FALLBACK_AGENT` (default none), `FOREMAN_FALLBACK_MODEL` (default: the fallback agent's default model), `FOREMAN_ANTIGRAVITY_ARGS`. New `foreman run` flags: `--agent`, `--model`. All follow the existing precedence (environment over conf over default), and the conf template documents them.
- `FOREMAN_MODEL` keeps its name; its default now depends on the agent (and, for Antigravity, on the login).
- `FOREMAN_EFFORT` keeps its name and default (`high`) and applies to both agents. There is no fallback effort setting: the fallback uses the batch's level, or the highest level its model offers below it, and says so once.
- `FOREMAN_CLAUDE_ARGS` keeps its name and meaning. `FOREMAN_PERMISSION_MODE` stays Claude's vocabulary; dry-run says when it does not apply to the batch's agent.
- `FOREMAN_ORDERING_MODEL` keeps working and must be a model of the batch's agent.
- `FOREMAN_SANDBOX`, when set, names the batch's own agent's sandbox; the fallback's is always derived from the repository and agent.
- Preflight, before anything is spent, refuses the run when the batch's own agent is not installed or logged in, its model does not exist, the effort level is not offered on that model, or — with `FOREMAN_MAX_COST_USD` set — its model has no known price.
- The fallback never blocks a run. Preflight checks it the same way, and if any check fails it warns once, naming what is missing, and the run starts with no fallback: a usage limit then pauses the run as it does today, repeating why the fallback could not take over. A user with one agent installed or one subscription is never made to set up the other.

### The agent cache

- One JSON file per agent in the user's cache directory (`$XDG_CACHE_HOME`, else `~/.cache`, under `foreman/agents/`). It records the login it was built under, when it was built, and each model with its effort levels and default level.
- Built for Antigravity from `agy models` (plain text: a model id, then its display name) and, per model, `agy -p "/effort" --model <id> --output-format json`, which reports the model's current and available levels. Claude needs no cache.
- Rebuilt when it is more than 7 days old, when Antigravity's login differs from the one it records, when a batch names a model it does not list, or on `foreman agents --refresh`. Missing or unreadable means rebuild. Deleting it is always safe.

### `foreman agents`

- A free action. Lists every agent in the agent directory: installed or not, logged in or not and with which login, and its models with effort levels and default level, the default model marked. Says where each list came from (built in, or the cache and its date). For Antigravity signed in with a Google account, it notes once that Google does not support wrapping `agy` under consumer plans.
- Plain output follows the existing rules for plain output; a machine-readable form, as `foreman status` has one, is what the app reads.

### The fallback agent

- Trigger: only the canonical failure class "usage limit", and only when preflight found the fallback ready. Auth, denial, context overflow and every other failure stop the run as today.
- On the trigger: the turn's verdict is recorded under the first agent; the stall marker stays and gains the agent whose sandbox holds the work; the run announces the takeover and continues with the fallback for the rest of the run. Its first turn is the review turn on the uncommitted work, exactly as a run's start takes one when the marker matches. If the fallback hits a usage limit too, the run pauses as today.
- Carrying work between sandboxes (clone mode only; `local` and `sandbox-mount` share one tree): commits come out of the first agent's clone by bundle as they do today; the uncommitted remainder — modified, deleted and untracked files — is carried through the host as a binary-safe patch, never as a commit. The fallback's clone is first synced to the base ref the marker records, then the patch applied, then the review turn runs. The same carry-over runs at the start of any run whose marker names a different agent's sandbox than the agent about to run.
- The run's log, its JSONL record, the verdict and the report carry the agent of each turn; the report can total cost per agent.

### Cost

- Claude: Claude Code's reported cost, as today.
- Antigravity: input, output, thinking and cache-read tokens from the envelope's `usage`, multiplied by a price table in the Antigravity agent's files, keyed by model and effective date, at Google's paid API prices (also for free-tier keys and for sign-in, where the turn costs nothing). Thinking tokens are priced as Google bills them — to be confirmed from the AI Studio pricing page when the table is written. Shown with "≈".
- A model with no row: "cost unknown"; never $0. With a cost budget set, preflight refuses such a run.
- The cost budget counts estimates as it counts reported costs.
- Prices known today (per 1M tokens, input / output): Gemini 4 Carbon and Argon $2 / $10, rising to $4 / $20 on 2026-12-01; Gemini 4 Neon $3 / $15; Gemini 4 Hydrogen $1.50 / $7.50; Gemini 3.8 Flash $0.75 / $3.75, input rising to $1.50 on 2027-01-01. Cache-read prices to be added from the same page.

### Doctor

- Checks every agent the batch names (its own and the fallback): program installed, logged in and which login, model known, effort level offered. A problem with the batch's own agent is a failure; a problem with the fallback is a warning, since the run works without it. In the sandbox modes: `sbx` installed and logged in, and each agent's sandbox present or creatable. Antigravity: folder trust, if the smoke test shows it is needed — reported with the command to run, never fixed by foreman. Skills installed where each installed agent reads them.
- A Claude-only batch's doctor output is unchanged by the refactor; checks added deliberately (the `sbx` login, if it is not already checked) update the goldens in the ticket that adds them.

### Setup calls and skills

- Ordering and `foreman commands` use the batch's own agent (never the fallback) and `FOREMAN_ORDERING_MODEL` or the batch's model, at `high` or the highest level below it.
- `install.sh` copies foreman's skills to Claude's skills directory as today and, when `agy` is installed, to Antigravity's (`~/.gemini/config/skills`). `foreman commands` under Antigravity runs the skill by slash command if `agy -p` supports it, else sends the skill's text as the prompt.

### The app

- Run settings: agent picker, model picker filled from `foreman agents`' machine-readable form, fallback agent and model pickers, and the effort that will be used. The choices are passed to the same `foreman run` as flags and environment; the app decides nothing itself.
- The "can't run" screen names the missing program; the login-expired screen names the agent. Run and report screens show each turn's agent and mark estimates with "≈". The bill shown before a run uses the same estimate.

### Documentation

- A guide to adding an agent, beside the agent files, written for a coding agent as a checklist: the functions an agent file defines, its node module, its failure strings, its prompt paragraph, its entry in the agent cache (or a built-in list), its doctor checks, its sandbox kit and login, its skills directory, its app label, its price table, and the golden and smoke cases to add. `CLAUDE.md` points to it in one line.
- README covers choosing an agent, the fallback agent, Antigravity's two logins and the consumer-plan note, and `foreman agents`.

### Order of the work

1. Move Claude behind the agent seam; goldens identical. (Independent of 2.)
2. Human ticket: install `agy`, sign in with Plus, create an AI Studio key, fill in the handoff file. Followup ticket: the smoke test (below), its findings appended to this spec.
3. The Antigravity agent, the agent cache and `foreman agents`.
4. Configuration, flags, preflight, cost estimate.
5. The fallback agent, including the carry-over between sandboxes.
6. Doctor and `install.sh`.
7. The app.
8. The guide and the README.

### What the smoke test must find out

Real output of `agy -p` in `json` and `stream-json`, for a success, an error, a soft denial (with its stderr notice), an authentication failure, a context overflow and — if one can be reached on the free key — a usage limit or quota message; whether a free-tier key works with `agy` at all; which wins between a suffixed model id and `--effort`; whether `agy -p "/effort"` and `agy -p "/<skill>"` work and spend nothing; whether `agy -p` needs folder trust; Antigravity's shell tool's time limit and how to raise it; whether a project-level permission allow list exists; how to create an Antigravity sandbox (maintained kit or custom kit on the shell image) and get either login into it; how thinking tokens and cache reads are billed; and the typical length of a real checkpoint turn and review turn, to set the two time limits.

## Testing Decisions

- A good test drives foreman from outside, through a command a user runs, and asserts on what a user sees: exit status, what landed, the run log, the verdict, plain output. It does not assert on which internal function was called or how an agent file builds its command line, except where the command line *is* the external contract with the agent program (asserted through a stub program that records its arguments).
- **The smoke suite, on the `fake` execution mode** (highest seam; existing). The fake adapter learns to answer in each agent's output format, chosen by the batch's agent: Claude's JSON as today, Antigravity's envelope, and Antigravity's stderr denial notice. Its existing behaviours (land, noop, dirty, commit-dirty, error, transient, limit, limit-dirty, stream, …) work under both. New behaviours cover the fallback (a limit under the first agent, then the second agent's turns), a soft denial, and a checkpoint turn that hits its time limit. Cases cover: an Antigravity batch landing; every ending under Antigravity; the fallback taking over with its review turn first; the next run starting with the batch's own agent; a fallback that hits a limit too; effort lowered for the fallback; preflight refusing an unknown model, an unoffered effort level and an unpriced model under a cost budget; and a fallback that is not installed, not logged in or unpriced, where the run still starts with a warning and a usage limit pauses it as today.
- **The recorder's node tests** (existing). Fed real `agy` output captured by the smoke-test ticket and kept as fixtures: verdicts for each status and failure class, the cost estimate against the price table (including an effective-date change and an unknown model), and the `cost_estimated` flag.
- **Stub programs on PATH** (existing pattern, as the sandbox cases stub `claude` and `sbx`). A stub `agy` (and the existing stub `claude` and `sbx`) record their arguments and print canned output, for: `foreman agents` and the agent cache's refresh rules; doctor's checks for both agents and both Antigravity logins; ordering and `foreman commands` under Antigravity; each execution mode's command line and environment for Antigravity; the sandbox's name and creation; and the carry-over of uncommitted work between two clones.
- **Goldens** (existing). Every golden is byte-for-byte unchanged after Claude moves behind the seam; that is the first change's acceptance test. New goldens: `foreman agents` plain output, and dry-run, status and doctor for an Antigravity batch and for a batch with a fallback.
- **The stream labeler's node tests** (existing) gain Antigravity `stream-json` fixtures from the smoke test.
- Prior art: `test/smoke.sh` and the `fake` adapter's behaviours; the stub `claude`/`sbx` cases in the smoke suite; `test/node/record.test.cjs` and `stream.test.cjs`; `test/golden/`.
- Nothing in the automated tests calls a real agent or spends money. The only real-agent run is the smoke-test ticket, done once by hand.

## Out of Scope

- OpenAI Codex or any agent other than Claude Code and Antigravity. The seam and the guide make a later one cheap; no stubs are written for one now.
- Gemini CLI. See ADR 0005.
- Choosing the agent per role (a different agent for ordering, setup or review turns than for ticket turns).
- Two Antigravity logins in one batch (for example Plus as the agent and an API key as the fallback). Antigravity has no per-run login switch.
- Foreman changing Antigravity's settings: its login, folder trust, permissions, or `useG1Credits`.
- Switching back to the batch's own agent mid-run when its limit resets.
- Handing over to the fallback on anything but a usage limit.
- A separate effort setting for the fallback.
- Session resume for either agent (ADR 0001 stands).
- Two agents in one sandbox.

## Further Notes

- Google's FAQ says wrapping `agy` in third-party apps "is not supported under consumer plans" and recommends an AI Studio API key. The user chose to support the Plus sign-in anyway; foreman notes it once and does not block it.
- On Plus, Antigravity offers Gemini 3.8 Flash and no Gemini 4 model; a free AI Studio key also has Gemini 4 Hydrogen. Free-tier prompts may be used by Google, and its rate limits are not published. Claude Sonnet and Opus 4.6 and GPT-OSS-120b inside Antigravity are removed on 2026-11-30 and are not supported.
- Antigravity's effort levels use Claude's names (`low` … `max`) but not its amounts, and most Gemini models offer only `low`, `medium` (their default) and `high`; Hydrogen and Neon add `xhigh`.
- What Antigravity prints at a usage limit is not documented. Until the smoke test or a real run captures it, the fallback works from Claude to Antigravity but cannot detect Antigravity running out; the docs say so, and the string is added when first seen.
- `sbx` 0.53.0 retired its built-in `gemini` agent name; the local `sbx` is 0.47.0. A sandbox keeps the agent it was created with.
- Facts in this spec about `agy` come from its documentation (antigravity.google/docs) as read on 2026-11-23, not from running it.
