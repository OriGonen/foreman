Implement the attached ticket, and only that ticket, to a high standard.

__ORDER_SENTENCE__ Do not pick a different one, do not start the next one, and do not
implement a dependency you think is missing — if the ticket genuinely cannot proceed
because something it depends on has not landed, stop and say so in __PROGRESS_FILE__
rather than widening the scope.

If the ticket cross-references sibling tickets by path, read the ones it names — they
often record a decision this ticket has to honour, or a surface it shares. Each ticket's
own '__STATUS_LINE__' line is the source of truth for whether it has landed.

## 1. Agree the seams before writing code

Read the ticket and the code it touches. Then write out, in your response, a short list of:

- the behaviours you will build test-first (the seams worth testing: pure logic, module
  boundaries, anything with branching or edge cases), and
- the parts you will just write directly (wiring, markup, config).

That list is the contract for step 2. Do not test-drive everything, and do not skip
test-driving the seams you named.

## 2. Implement

__TDD_INSTRUCTION__

While working:
__ITERATIVE_CHECK_BLOCK__

Stay inside the ticket's scope. If you find an unrelated problem, note it in
__PROGRESS_FILE__ rather than fixing it.

Before you start any substantial piece of work — a large file, a long-running command, a
wide read of the repository — ask whether you can finish *that* and still land the whole
ticket in what is left of this turn. If you cannot, checkpoint what you already have first,
using the handoff at the end of step 5, and let the next iteration continue from it.

Ask it explicitly rather than waiting to notice. This turn has an output budget as well as
a context window, and the output budget is invisible to you: when it runs out the turn
simply ends, with the deliverable half-written, nothing committed, and no error anywhere to
tell you that is what happened. You are expected to land this ticket well inside
__CONTEXT_BUDGET__ tokens of context; past that with substantial work still remaining, stop
adding to it and hand off.

## 3. Verify

Once the ticket is done, run the project's full checks:
__VERIFY_BLOCK__

Run every one of them in the foreground and wait for it to finish. One command may run for
up to __COMMAND_TIMEOUT__ minutes in this session: give the Bash tool a `timeout` long enough for
the check (at most __COMMAND_TIMEOUT_MS__ ms), and do not wrap the command in a shorter `timeout`
of your own. Never background a check — no `&`, no `nohup`, no `run_in_background`. This
session is a single non-interactive turn: nothing will ever wake you when a background
command finishes, so a check you background is a check whose outcome you will never see, and
the turn ends with the ticket neither verified nor landed.

If a check cannot finish inside that limit even on its own, run it in parts that each can
(per module, per task, per test directory) rather than backgrounding it, and add nothing to
it that it does not need, such as a `clean`.

They must pass. Fix real failures. Never delete a test, weaken an assertion, or skip a
test to get green — if a test looks wrong, say so in __PROGRESS_FILE__ and leave it
failing.
__PROMPT_EXTRA__
## 4. Review

__REVIEW_INSTRUCTION__ Apply the findings you agree with, re-run the checks from step 3
afterwards, and record any finding you deliberately did not act on, with the reason, in
__PROGRESS_FILE__.

## 5. Land it

All three steps below happen in this turn. Nothing you defer to "after the run finishes"
ever happens: the turn is the run, and a ticket left unflipped or uncommitted stops the loop
for a human instead of moving on.

1. Set the ticket's '__STATUS_LINE__' line to '__DONE_WORD__' and check off its checklist
   items. The loop reads that line to decide what runs next, so a ticket left unflipped
   will be attempted again on the next iteration.
2. Append to __PROGRESS_FILE__: a SHORT entry (aim for 5-10 lines, bullets not prose) —
   the ticket, what you built, the seams you test-drove, review findings applied or
   skipped, and anything the next iteration must know. This file is re-attached (as a
   tail excerpt) to every future iteration's prompt, so verbosity here is a recurring
   cost, not a one-off — skip detail that is already recoverable from the diff or the
   ticket file itself.
3. __COMMIT_NOTE__

If you reach this point without having finished the ticket, you have not done what was
asked — but do not compound it by leaving the work uncommitted, and do not flip the status
line to hide it. Hand off instead:

- commit what you have as `wip: <ticket> — <what remains>`;
- leave the '__STATUS_LINE__' line exactly as it is, so the loop knows the ticket has not
  landed and gives it another iteration;
- write a `Remaining:` list in __PROGRESS_FILE__ — what is left, and where you got to.

The next iteration starts from that commit and reads that list.
