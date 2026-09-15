# ralph

A loop that implements one ticket per iteration, until a batch of tickets is done or a
budget stops it. This file is the project's glossary: what the words mean, and which
words not to use. It holds no implementation detail — `README.md` describes how the loop
behaves, `lib/` is how it does it, and `docs/adr/` is why.

## Language

### The things being worked on

**Batch**:
A directory containing a `ralph.conf`, and the tickets to be worked through. The unit
`ralph run` is pointed at.
_Avoid_: Project, job, queue

**Ticket**:
One unit of work, as a file with a status line the agent flips when it is done.
_Avoid_: Task, issue, story

**Order**:
The sequence the batch's tickets are attempted in, and the reasoning behind it, written
in the batch's `order.md`.
_Avoid_: Priority, backlog, schedule

### The loop's units of work

**Run**:
One invocation of `ralph run`. Holds a budget and its own in-memory accounting; ends
when the batch is done, a budget is reached, or something needs a human.
_Avoid_: Session, execution

**Iteration**:
One pass of the loop: pick a ticket, sync, build a prompt, run a turn, decide what
happened. The unit the user's `<n>` budget is spent in.
_Avoid_: Cycle, round, step

**Turn**:
One `claude --print` invocation. It prints a single JSON object and exits; there is no
second turn. An iteration normally contains exactly one, and a stalled iteration
contains two — its own and a checkpoint turn.
_Avoid_: Call, request, agent run

### How a turn ends

**Landed**:
The ticket's status line was flipped to the done word and the work was committed. The
only ending that finishes a ticket.
_Avoid_: Completed, finished, passed

**Progressed**:
HEAD moved, the ticket is unflipped, and nothing errored: the agent committed a
checkpoint of its own accord and handed the rest off. Not a failure — the same ticket
gets the next iteration.
_Avoid_: Partial, incomplete, WIP (as a verb)

**Stalled**:
The turn ended cleanly with the ticket unflipped, HEAD unmoved, and its work sitting
uncommitted in the tree: it ran out of room before reaching its own checkpoint step. The
loop's response is a checkpoint turn.
_Avoid_: Dirty, timed out, ran out of context (that is a different, reported condition)

**Checkpoint turn**:
A short, single-purpose turn the loop runs in response to a stall: read the uncommitted
diff, commit it as `wip:`, and write the `Remaining:` list. It never continues the
ticket's work. It converts a stall into a progression.
_Avoid_: Salvage run, auto-commit, rescue

### Budgets and counters

**Attempt**:
An unproductive try at a ticket — one that neither landed nor progressed nor stalled.
Counted per ticket per run, capped by `RALPH_TICKET_ATTEMPTS`.
_Avoid_: Retry, try

**Continuation**:
An extra turn a ticket needed after progressing or stalling. Counted per ticket per run
and capped by `RALPH_MAX_CONTINUATIONS`, which is the single budget for "how many extra
turns has this one ticket needed".
_Avoid_: Extension, follow-up

**Stall count**:
How many of a ticket's continuations were stalls rather than progressions. Reported and
logged; it has no budget of its own.
_Avoid_: Stall budget, max stalls

**Verdict**:
The fixed key/value summary of one turn that the recorder writes for the loop to read —
the loop's only structured view of what the model did.
_Avoid_: Result, outcome, report

### Where the agent runs

**Adapter**:
A file in `lib/exec/` implementing the fixed set of `exec_*` functions for one execution
mode. Adding an execution mode is adding a file there; nothing else holds a list of the
modes that exist.
_Avoid_: Backend, driver, provider, executor

**Clone**:
The agent's own copy of the repository inside the sandbox, under the `sandbox` adapter.
Commits reach the host from it by bundle; an uncommitted change in it is a lost change.
_Avoid_: Workspace, container repo

**Sandbox**:
The `sbx` container the agent runs in. One per **repository**, not per batch — several
batches in the same repository share it.
_Avoid_: Environment, box, VM

### Resuming

**Resume**:
Rerunning `ralph run` on a batch so it picks up at the first ticket that has not landed.
There is no state to restore and nothing to pass; rerunning the same command is the whole
procedure.
_Avoid_: Restart, continue (that is what a continuation does)

**Session resume**:
The deferred idea of reattaching to the agent's *own* prior conversation via the CLI's
`--resume` flag, so a stalled turn continues with its reasoning intact. Not implemented,
and always named in full — an unqualified "resume" means the batch, not the session.
See `docs/adr/0001-checkpoint-turn-over-session-resume.md`.
_Avoid_: Resume (unqualified), reattach
