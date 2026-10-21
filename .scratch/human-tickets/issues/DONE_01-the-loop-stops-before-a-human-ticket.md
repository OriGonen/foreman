# 01: The loop stops before a human ticket

**Status:** done

**Blocked by:** None (can start immediately)

**What to build:**

A ticket only a person can do is marked on its own status line, `**Status:** ready-for-human`.
Today the loop treats that as "not done" and hands it to an agent, which either fails it the
expensive way or fakes the human's part. Make the loop recognise it and stop.

Whenever the **next** ticket in the order is a human ticket, `foreman run` stops before
spending anything — before the sandbox is prepared, before any budget check, before any sync,
before any prompt — and exits **30** ("waiting on a human"). It never looks past the human
ticket for runnable work: the order is trusted. Rerunning without finishing it stops the same
way, every time, for free. Once the person sets it to `done` and commits, a rerun continues
with the next ticket; the status lines stay the only resume state.

The stop can happen at the start of a run (nothing starts, nothing is recorded) or mid-run,
after the last agent ticket before the human one lands (the usual footer, then the note, and
the run log records `# stopped: waiting on a human — <ticket>`). The gate is checked before
the budget checks, so a run whose budget and next-ticket-is-human coincide reports the human.

The stop prints one note, identical wherever it is printed: the ticket, the handoff file named
on its `**Handoff:**` line (when it has one that resolves), the numbered steps (do it, fill in
the handoff, commit, set it done, rerun with the exact rerun command), and that rerunning early
costs nothing. `foreman dry-run` at a human ticket exits 0, says it would stop there, and prints
no prompt.

The word is `FOREMAN_HUMAN_WORD` (default `ready-for-human`), with a derived
`FOREMAN_HUMAN_PATTERN`, both derived the same way as the done word and pattern; an empty word
turns the feature off.

This ticket also creates the single module that knows what a human ticket is — the
needs-human test, reading a `Name:` field from a ticket, resolving the `Handoff:` path — which
tickets 02–04 extend. Its "sent back" lookup can wait for ticket 02.

Full design: `.scratch/human-tickets/plan.md` — "The ticket formats", "Precedence", and the
`foreman-config.sh`, `foreman-human.sh` and `foreman-loop.sh` sections (gate, note, footer).

**Acceptance criteria:**

- [x] A human ticket at the head of the order makes `foreman run` exit 30 with no new commits,
      no run-log rows, and no prompt sent (fake adapter's prompt log stays empty)
- [x] A run that reaches a human ticket mid-batch lands the tickets before it, stops at it
      with exit 30, never prompts a ticket after it, and the run log ends with
      `# stopped: waiting on a human`
- [x] With an iteration budget of 1 and a human ticket second, the run lands the first and
      exits 30, not 10
- [x] Rerunning without finishing it exits 30 again with HEAD unchanged and nothing recorded
- [x] Setting the human ticket to `done` and committing lets a rerun continue with the next
      ticket
- [x] The note names the ticket, its handoff path when it has one, and the exact rerun command
- [x] `foreman dry-run` at a human ticket exits 0, says it would stop there, prints no prompt
- [x] `FOREMAN_HUMAN_WORD=needs-owner` stops on that word; `FOREMAN_HUMAN_WORD=` hands a
      `ready-for-human` ticket to the agent like any other
- [x] The loop's header documents exit 30 and `FOREMAN_HUMAN_WORD`
- [x] New smoke cases cover the above, and `bash test/smoke.sh` passes in full
