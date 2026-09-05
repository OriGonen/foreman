Implement the ticket attached below, and only that ticket, to a high standard.

__ORDER_SENTENCE__ Do not pick a different one, do not start the next one, and do not
implement a dependency you think is missing — if the ticket genuinely cannot proceed
because something it depends on has not landed, stop and say so in __PROGRESS_FILE__
rather than widening the scope.

If the ticket cross-references sibling tickets by path, read the ones it names directly —
not their references in turn — because they often record a decision this ticket has to
honour, or a surface it shares. Each ticket's own '__STATUS_LINE__' line is the source of
truth for whether it has landed.

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

## 3. Verify

Once the ticket is done, run the project's full checks:
__VERIFY_BLOCK__

They must pass. Fix real failures. Never delete a test, weaken an assertion, or skip a
test to get green — if a test looks wrong, say so in __PROGRESS_FILE__ and leave it
failing.
__PROMPT_EXTRA__
## 4. Review

__REVIEW_INSTRUCTION__ Apply the findings you agree with, re-run the checks from step 3
afterwards, and record any finding you deliberately did not act on, with the reason, in
__PROGRESS_FILE__.

## 5. Land it

1. Set the ticket's '__STATUS_LINE__' line to '__DONE_WORD__' and check off its checklist
   items. The loop reads that line to decide what runs next, so a ticket left unflipped
   will be attempted again on the next iteration.
2. Append to __PROGRESS_FILE__: a SHORT entry, opening with a line of exactly
   `--- <this ticket's path>` and then 3-8 bullets, not prose. Write only what the NEXT
   iteration needs from you: a decision it has to honour, a surface it will build on, and
   anything you deliberately did not do, with the reason — including review findings you
   skipped. Do not narrate what you built: that is already recoverable from this ticket's
   '__STATUS_LINE__' line and from the diff, and it is the bulk of what makes these
   entries long. This file is re-attached (as a tail excerpt) to every future iteration's
   prompt, so verbosity here is a recurring cost, not a one-off.
3. __COMMIT_NOTE__
