# 06: Write the smoke-test findings into the spec

**Status:** ready-for-agent

**Blocked by:** 05a

**What to build:**

Turn ticket 05's captures and handoff into decisions every later Antigravity ticket can
work from, before any Antigravity code is written (spec user story 88).

Append a "Smoke test findings" section to the spec that answers each question in "What
the smoke test must find out", citing the capture file each answer comes from, and
replacing the spec's provisional wording where a finding settles it:

- the mapping of every envelope `status` seen (and any not seen) to the canonical result
- the exact denial notice on stderr, the authentication-required text, the context-overflow text if seen, and the usage-limit/quota text — or that it is still unknown, so the fallback cannot yet detect Antigravity running out
- which wins between a suffixed model id and `--effort`
- whether `/effort` and slash-command skills work in `-p` and whether they spend tokens
- whether folder trust stops a headless run, and the command a user runs to grant it
- the shell tool's time limit and how to raise it, and the prompt paragraph about long checks for Antigravity that follows from it
- whether a project-level permission allow list exists
- how an Antigravity sandbox is created and how each login gets into it
- the measured lengths of the checkpoint and review turns, and the two time limits set to about three times the typical length (replacing the provisional 3 and 6 minutes)
- each model's effort levels and default, per login

Copy the captured output the later tickets need into the test fixtures (recorder, stream
labeler, stub `agy`), each fixture named for what it shows.

- [ ] Every question in "What the smoke test must find out" has an answer or an explicit "still unknown" in the new section
- [ ] The two time limits in the spec are replaced by measured ones, with the measurements shown
- [ ] Every provisional statement in the spec that a finding settles is updated, and each update cites its capture
- [ ] The fixtures the later tickets need are in the test fixture directories, named for what they show, with no key value or e-mail address in them
