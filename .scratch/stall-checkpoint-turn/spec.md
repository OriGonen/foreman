# Spec — salvage a stalled turn with a checkpoint turn

Vocabulary: `CONTEXT.md`. Decision record: `docs/adr/0001-checkpoint-turn-over-session-resume.md`.
Design notes: `PLAN-2026-09-14-stall-checkpoint-turn.md`.

## Problem Statement

A turn can end cleanly having done real work and committed none of it. The agent is asked
to checkpoint its own partial work before running out of room, and usually does — but when
it runs out of room *before* reaching that step, the turn ends with exit 0, no error
anywhere, the ticket unflipped, and its work sitting uncommitted in the tree. The loop
calls this a **stall** and stops for a human.

Three things are wrong with what happens next.

**The work is stranded.** The operator is holding a tree full of plausible, unreviewed work
with no commit behind it, and the only path forward is manual.

**The instructions for rescuing it are wrong under the default execution mode.** The stop
prints two blocks that contradict each other: an adapter-correct paragraph saying the
changes live in the sandbox's clone, and then a generic follow-up telling the operator to
run `git add -A && git commit` and rerun. Under the `sandbox` adapter — the default — that
second block finds nothing to commit (the host tree is clean; the changes are in the
clone), so the commit silently does nothing, and the rerun then hard-resets the clone and
destroys the work the stop existed to protect. Both blocks are printed by the same stop, in
the same voice, one after the other.

**Rerunning cannot help, and actively harms.** The first act of any run is to sync the
agent's tree to the host's HEAD. On the default adapter that is a hard reset plus a clean
of untracked files, and it happens before anything looks at whether the tree is dirty. So
the natural operator response to any stop — rerun it — is the single most destructive thing
available.

The net effect is that a ticket which was 80% done costs its whole turn, and the operator
either redoes it from nothing or performs a multi-step manual rescue.

## Solution

When a turn stalls, the loop runs a **checkpoint turn**: a short, single-purpose agent turn
that reads the uncommitted diff, commits it as a `wip:` commit, and writes a `Remaining:`
note. That converts the stall into a **progression** — an ending the loop already handles,
by continuing the same ticket on the next iteration with the handoff in hand.

The loop still never auto-commits. An agent commits; the checkpoint turn is an agent. The
checkpoint turn never continues the ticket's work — it only commits what is already there.

Alongside that, the stop's recovery instructions become adapter-correct, and syncing
refuses to run over a dirty tree rather than resetting it. Finally, a run that starts with
a dirty tree it can prove is its own unfinished business salvages it before syncing, so
"just rerun it" becomes a true instruction rather than a destructive one.

From the operator's side: a stall stops costing a turn's worth of work, stops printing
advice that destroys the thing it is protecting, and stops being a situation that requires
knowing how git bundles move between a host and a container.

## User Stories

**Recovering stalled work**

1. As an operator, I want a turn that ran out of room mid-ticket to have its work committed
   for me, so that the next iteration builds on it instead of starting the ticket again.
2. As an operator, I want the commit that rescues stalled work to be marked `wip:`, so that
   I can tell at a glance which commits in history were a handoff rather than a finished
   ticket.
3. As an operator, I want the rescued commit to leave the ticket's status line unflipped, so
   that nothing claims the ticket landed when it did not.
4. As an operator, I want a `Remaining:` note written alongside the rescued commit, so that
   the next iteration knows what is left rather than re-deriving it from the diff.
5. As an operator, I want the checkpoint turn to refuse to continue the ticket's work, so
   that no substantial unreviewed code is written by a turn I did not commission.
6. As an operator, I want the checkpoint turn to be bounded in length, so that a
   misbehaving one cannot quietly become a full iteration.
7. As an operator, I want a failed checkpoint turn to fall back to today's stop, so that a
   rescue that does not work leaves me exactly where I would have been without it.
8. As an operator, I want the loop to keep never auto-committing, so that every commit in
   my history was made by an agent that looked at the diff.

**Understanding what happened**

9. As an operator, I want a stalled turn to be named as a stall in the terminal, so that I
   can distinguish it from a ticket that failed and from one that handed off deliberately.
10. As an operator, I want a stall to be visually distinct from an iteration I paid for, so
    that the iteration count on screen still reflects the budget I set.
11. As an operator, I want the cost of a checkpoint turn to appear in the run's total, so
    that my spend figures are never quietly understated.
12. As an operator, I want a checkpoint turn recorded as its own row in the run log, so that
    per-iteration cost and duration figures are not distorted by a second turn folded into
    them.
13. As an operator, I want to be able to tell checkpoint rows from ordinary iterations when
    reading the log, so that I can count what the loop actually did.
14. As an operator, I want the run report to account for stalls as their own outcome, so
    that a batch full of stalls reads differently from a batch full of failures.
15. As an operator, I want a stall not to be reported as a failure, so that a report's
    failure list stays a list of things that actually went wrong.

**Budgets and caps**

16. As an operator, I want a stall not to consume one of the run's iterations, so that the
    number I passed on the command line still means "iterations of work I asked for".
17. As an operator, I want a stall not to consume one of a ticket's attempts, so that a
    ticket making progress is not punished by the counter meant for unproductive tries.
18. As an operator, I want a single cap on how many extra turns one ticket may consume, so
    that I have one number to reason about rather than a product of two budgets.
19. As an operator, I want stalls and progressions to feed that same cap, so that a ticket
    cannot loop forever by alternating between them.
20. As an operator, I want the message printed when that cap is reached to be true whether
    the ticket stalled, progressed, or both, so that the terminal never tells me the ticket
    "progressed" when it never did.
21. As an operator, I want that message to break down how many of the extra turns were
    stalls and how many were progressions, so that I know which shape of too-big the ticket
    was.
22. As an operator, I want no new configuration knob for stalls, so that the configuration
    surface does not grow a setting I have to understand to run a batch.
23. As an operator, I want a stalled turn's work rescued even when the run has already
    reached its cost or time budget, so that a budget never causes me to lose work I have
    already paid for.
24. As an operator, I want the run's closing message to say when a budget was overshot to
    salvage work, so that a final figure above my limit is explained rather than mysterious.

**The next iteration**

25. As an operator, I want the iteration after a stall to be told it is continuing a ticket
    rather than starting one, so that it picks up the handoff instead of redoing the work.
26. As an operator, I want that iteration told the handoff was reconstructed from the diff,
    so that it treats the `Remaining:` list as a description of what exists rather than of
    what was intended.
27. As an operator, I want that iteration told the previous turn ran out of room, so that it
    works in smaller pieces and commits sooner rather than stalling the same way.
28. As an operator, I want a continuation after a stall reviewed against the commit the
    ticket was first attempted from, so that a ticket which took several passes is still
    reviewed as one diff.

**Recovery instructions that are true**

29. As an operator, I want the recovery instructions printed by a stop to match the
    execution mode I am actually running, so that following them does something.
30. As an operator running the default sandbox mode, I want the instructions to tell me to
    commit inside the sandbox and transport the commit out, so that I am not told to commit
    a tree that has nothing in it.
31. As an operator running in my own working tree, I want to keep the simple
    commit-and-rerun instructions, so that the advice does not become more complicated than
    my situation.
32. As an operator, I want a stop never to print two contradictory sets of instructions, so
    that I do not have to work out which of them to believe.
33. As a maintainer, I want per-adapter recovery text to live with the adapter, so that
    adding an execution mode means adding one file and not editing the loop.
34. As a maintainer, I want the text for stranded-but-committed work kept distinct from the
    text for uncommitted work, so that two different failures do not share one message.

**Rerunning safely**

35. As an operator, I want rerunning a batch never to destroy uncommitted work, so that the
    most natural response to any stop is also a safe one.
36. As an operator, I want to be told why a sync refused rather than having it fail
    silently, so that I know the work is intact and what to do next.
37. As an operator, I want a rerun after a stall to salvage the work automatically, so that
    the instruction "just rerun it" is true.
38. As an operator, I want a rerun to salvage only work the loop can prove is its own
    unfinished business, so that my own experimentation inside the sandbox is never
    committed under a ticket.
39. As an operator running several batches in one repository, I want one batch's rerun never
    to commit another batch's stalled work, so that a shared sandbox does not cause
    cross-batch damage.
40. As an operator, I want a rerun that cannot prove the dirty tree is its own to refuse and
    explain, so that the ambiguous case is safe rather than guessed at.
41. As an operator, I want any state the loop keeps for this to be disposable, so that
    deleting it is always safe and never leaves a batch in a broken condition.

**Maintaining it**

42. As a maintainer, I want the checkpoint turn to work in every execution mode without
    per-mode code, so that the modes do not drift apart.
43. As a maintainer, I want the stall branch ordered below the permission-denial branch, so
    that a denied commit is still reported as a permission problem rather than as the dirty
    tree it causes.
44. As a maintainer, I want the whole stall path testable without a model, a container, or
    money, so that it is covered by the same suite as everything else.
45. As a maintainer, I want the failure path of the checkpoint turn tested, so that the stop
    it falls back to does not rot the way the recovery text did.
46. As a maintainer, I want each adapter's recovery text assertable without that adapter's
    runtime, so that the sandbox text is covered without a sandbox.
47. As a maintainer, I want the test to exercise the real prompt assembly rather than a
    side channel, so that a change to the checkpoint prompt is caught by the suite.

## Implementation Decisions

**A stall is a distinct outcome, recognised by shape.** A turn stalls when it exits zero,
reports no error, leaves the ticket unflipped, leaves HEAD where it started, and leaves the
tree dirty. This is inferred from the loop's existing signals — it is *not* the same thing
as the reported context-exhaustion condition, which the recorder detects from the payload
and which already has its own retry path. A turn can stall without that signal ever firing.

**Branch order is load-bearing.** The stall branch sits below the permission-denial branch.
A denied `git commit` leaves the tree dirty as a *consequence*, and a stall branch placed
above it would report the symptom and never name the cause.

**The checkpoint turn reuses the existing agent-invocation call with a different prompt, and
simply is not preceded by a sync.** The exec seam already separates "put the agent's tree at
a base" from "run the agent", so "run the agent without syncing first" requires no new
adapter function and no per-adapter agreement. Three of the four adapters already treat
syncing as a no-op; only the clone-based sandbox adapter resets anything. **No function is
added to the adapter interface for this.**

**The checkpoint turn is constrained by its prompt plus a low turn limit, not by a tool
allowlist.** Both sandbox adapters default to a permission mode that bypasses the gate
entirely, where an allowlist plausibly does not bite — a restriction that silently does
nothing in the default mode is worse than none, because it reads as protection. The turn
limit is enforced by the CLI regardless of permission mode. See the ADR.

**The checkpoint prompt is assembled inline alongside the main prompt assembly, not as a
second template.** It has few variable parts — the ticket, the base to diff against, the
adapter's commit note, and the progress file — so a template with four slots would be more
machinery than the thing it holds. Keeping it with the other prompt assembly is where
anyone would look for it.

**The checkpoint turn writes the progress entry.** This is load-bearing rather than
decorative: the entry is what the next iteration reads through the existing continuation
notice. Without it the `wip:` commit is a diff with no explanation.

**Accounting.** A stall does not increment the user-facing iteration counter — the operator
did not commission that turn. Its cost *is* added to the run total, because it is money. It
resets the ticket's attempt counter, on the same reasoning that already applies to a
progression: a stall is not an unproductive attempt.

**One budget, two counters.** A new per-ticket stall counter exists for display and
telemetry only. The *budget* remains the single existing continuation cap, fed by stalls and
progressions alike. No new configuration setting is introduced. Two caps would let one
ticket burn both budgets with no single number bounding it.

**The cap message is reworded** to say a ticket needed some number of extra turns without
landing, with a breakdown of how many were progressions and how many stalls. The advice it
ends on — this is a size problem, split the ticket — is correct either way.

**Budget overshoot is deliberate and announced.** Budget checks happen before an iteration,
but a stall is discovered after one, so a stalled turn can push the run past its cost
budget. The checkpoint turn runs anyway: a budget limits how much work to commission, not
whether to keep work already paid for. The closing message says so.

**Telemetry gains a row kind, not an outcome.** The checkpoint turn is recorded as its own
row, distinguished by a new field naming it as a checkpoint. The recorder's existing derived
outcomes are unchanged — `stalled` is the outcome of the *iteration*, `checkpoint` is the
kind of the extra *row*. The report gains the corresponding bucket.

**The continuation notice gains a stall variant** carrying two facts: that the handoff was
reconstructed from the diff by a turn that never saw the reasoning, and that the previous
turn ran out of room. The second is the same signal the existing context-retry notice
carries and prompts the same correct response.

**Recovery text moves into the adapter interface** as a new function for the
uncommitted-work case, kept separate from the existing function for the
committed-but-stranded case — two different failures, two messages. The shared
implementation used by the non-clone modes keeps today's commit-and-rerun text; both sandbox
adapters print the transport the clone adapter already uses internally. The loop calls the
adapter instead of hardcoding one mode's text.

**Syncing refuses over a dirty tree** rather than resetting it, and says why. This ships
with the corrected text as one change: the stop tells the truth, *and* an operator who
ignores the text still cannot lose the tree by rerunning.

**Start-of-run salvage is gated on a marker the loop wrote itself.** A disposable marker
file in the batch directory records the ticket, the base ref, and the sandbox name at the
moment a stall was left unsalvaged. It is checked before the first sync of a run and deleted
as soon as the tree is clean or a checkpoint succeeds. Marker present and matching → run a
checkpoint turn before syncing. Marker missing or mismatched → refuse to sync, print the
recovery note.

**The marker carries the sandbox name because the sandbox is per-repository, not
per-batch.** Several batches in one repository share a container and clone, so a dirty tree
at run start may belong to another batch or to a human's own session. Committing that blind
under whatever ticket this run picked first is exactly the unreviewed commit the loop
refuses.

**This is a deliberate, bounded exception to the toolkit's no-state rule.** It bends the
same way the existing per-batch bundle file already does: a disposable file in the batch
directory, never a registry, safe to delete at any time, and whose absence always degrades
to the safe behaviour.

## Testing Decisions

**What makes a good test here.** The suite asserts on what an operator observes — the exit
code, which tickets landed, what the terminal said, what the git history contains, and what
the structured run log recorded. It does not assert on internal variables, function call
order, or intermediate state. Every existing case follows this, and the new ones must: a
test that knows the name of the counter is testing the implementation, while a test that
knows the cap message is true is testing the behaviour.

**One seam, already in place.** The end-to-end smoke suite drives the real command-line
entry point against a throwaway repository using the no-model `fake` execution mode. Every
behaviour in this spec is reachable from there. No new test infrastructure is introduced.

**The fake adapter recognises a checkpoint turn from its prompt**, by a sentinel phrase, so
the test exercises the real prompt-assembly path rather than a side channel. Its existing
"leave the tree dirty" behaviour then drives the whole stall → checkpoint → continue path
end to end without any new behaviour name. A second behaviour is added for a checkpoint turn
that fails to commit, because that is the branch which falls through to the stop — and an
untested stop is precisely how the wrong recovery text survived this long.

**Prior art to follow, case by case:**

- The existing partial-handoff case is the closest model for the stall path: it captures the
  prompts to a log file, asserts the terminal names the outcome, asserts the attempt counter
  was not spent, asserts the ticket lands on the continuation, and then asserts the report
  counts it as its own outcome and does not flag it as a failure. The stall case mirrors it
  point for point.
- The existing continuation-cap case is the model for the reworded cap message, including
  driving the cap down by configuration so the case runs in a few iterations.
- The existing dirty-tree case is the model for the recovery-note and refusal assertions,
  and already asserts that nothing was committed.
- The existing permission-denial case is the model for asserting branch order — that the
  terminal names the cause rather than the dirty tree it caused.

**Adapter text is asserted through the existing question-asking pattern.** The exec seam
already has a family of helpers that load a named adapter in a subshell and ask it one
question, built so a caller can interrogate a mode it is not running; the dry-run output of
the permission-mode case is the existing precedent for asserting a non-fake adapter's answer
without that adapter's runtime. The recovery note joins that family, and one case asserts
each adapter's text: the non-clone modes say commit-and-rerun, the sandbox modes say commit
inside the sandbox and transport it out, and neither prints the other's.

**Specific assertions the suite must gain:** a stall is named as such in the terminal; the
iteration counter did not advance for it; a checkpoint row exists in the structured log and
is distinguishable; the shared cap counts the stall; the cap message's breakdown is
accurate; the following iteration's prompt carries both stall facts and reviews against the
ticket's first base; a failed checkpoint turn exits for a human and prints the
adapter-correct note; syncing refuses over a dirty tree rather than resetting it; a rerun
with a matching marker salvages; a rerun with a missing or mismatched marker refuses.

## Out of Scope

- **Session resume.** Reattaching to the agent's own prior conversation is rejected for now
  and recorded in the ADR. Nothing in this spec depends on it, and nothing here forecloses
  it.
- **Any behaviour change to the progression path.** A turn that checkpoints itself is
  already handled correctly and is not touched, beyond the reworded cap message that both
  paths now share.
- **Auto-committing by the loop.** Unchanged and non-negotiable: the loop never commits.
- **Changing what the main prompt asks of the agent about sizing its own work.** The agent's
  own checkpoint step stays exactly as it is; this spec covers only the case where the turn
  never reaches it.
- **Making the sandbox per-batch.** The shared-sandbox hazard is *handled* here, not
  removed.
- **The configurable live-ticker interval** and **a batch-removal command**, both tracked
  separately.
- **Verifying whether a tool allowlist bites under a bypassing permission mode.** Optional
  hardening; the design assumes it does not, and nothing changes if that assumption holds.

## Further Notes

**Ship order matters and the pieces are separable.** The recovery-text fix plus the
refuse-to-sync change is independent of everything else, is small, and should land first —
it is the only recovery path that exists today and it currently destroys the work it claims
to protect. The stall-and-checkpoint work is next. Start-of-run salvage is last, and is what
makes the recovery advice's promise of "just rerun it" literally true.

**The recovery-text bug was found by manually recovering from a real run** on 2026-09-12,
where the printed instructions no-opped and the correct rescue required committing inside
the container and moving the commit out by hand. That rescue is the same transport the clone
adapter already performs internally, which is why the corrected text is easy to check
against working code.

**One fact worth recording for whoever revisits session resume.** The CLI does support
resuming a session in print mode, does append the new prompt as a further turn, does offer a
fork flag that mints a new session id, and without that flag returns the *same* session id —
which would make every resumed turn log an identical id. What remains undocumented, and what
the decision actually turned on, is whether compaction applies in print mode at all.
