#!/bin/bash
# Assembles one iteration's prompt. Sourced by ralph-loop.sh, not executed.
#
# Requires: TICKET_FILE, and the variables ralph-config.sh sets (BATCH_DIR, ORDER_FILE,
# PROGRESS_FILE, PROMPT_EXTRA_FILE, RALPH_*). BASE_REF defaults to HEAD.
# Produces:  RALPH_PROMPT
#
# The structure comes from prompt.template.md and the project-specific parts come from
# the batch's ralph.conf, so one template serves every repo. Anything that does not fit a
# slot goes in the batch's prompt-extra.md, which is spliced in at the __PROMPT_EXTRA__
# marker (between Verify and Review).
#
# Every path in the prompt is repo-relative, because the repo root is the agent's working
# directory.

if [ -z "${TICKET_FILE:-}" ]; then
  echo "ralph-prompt.sh: TICKET_FILE is not set" >&2
  return 1 2>/dev/null || exit 1
fi

BASE_REF="${BASE_REF:-$(git rev-parse HEAD)}"

_ralph_template="$RALPH_TOOL_DIR/prompt.template.md"
if [ ! -f "$_ralph_template" ]; then
  echo "ralph-prompt.sh: no prompt template at $_ralph_template" >&2
  return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# Work out the variable parts before substituting, so the template stays free of
# conditionals. A knob left empty in ralph.conf degrades to generic prose rather than
# emitting an empty bullet or a dangling command name.
# ---------------------------------------------------------------------------

if [ -f "$ORDER_FILE" ]; then
  _ralph_order_sentence="The ticket was chosen for you by the loop from $ORDER_FILE, which holds the run order for
this batch and the reasoning behind it."
else
  _ralph_order_sentence="The ticket was chosen for you by the loop: it is the first one in $BATCH_DIR that has not
landed yet."
fi

if [ -n "$RALPH_TDD_SKILL" ]; then
  _ralph_tdd="For each named seam, use the \`$RALPH_TDD_SKILL\` skill: write the failing test first, watch
it fail for the right reason, make it pass, then refactor. Write the rest directly."
else
  _ralph_tdd="For each named seam, work test-first: write the failing test, watch it fail for the right
reason, make it pass, then refactor. Write the rest directly."
fi

_ralph_iterative=""
[ -n "$RALPH_CHECK_CMD" ] && _ralph_iterative+="
- run \`$RALPH_CHECK_CMD\` regularly, not just at the end;"
[ -n "$RALPH_FOCUSED_TEST_CMD" ] && _ralph_iterative+="
- run the individual test files you are touching (\`$RALPH_FOCUSED_TEST_CMD\`) after each
  red-green cycle."
[ -n "$_ralph_iterative" ] || _ralph_iterative="
- re-run the project's checks and the tests you are touching as you go, not just at the end."

_ralph_verify=""
[ -n "$RALPH_CHECK_CMD" ] && _ralph_verify+="
- \`$RALPH_CHECK_CMD\`"
[ -n "$RALPH_TEST_CMD" ] && _ralph_verify+="
- \`$RALPH_TEST_CMD\`"
[ -n "$_ralph_verify" ] || _ralph_verify="
- whatever this repo uses to type-check, lint and test (check package.json, Makefile, or
  the contributing docs — and say in $PROGRESS_FILE what you settled on)."

if [ -n "$RALPH_REVIEW_SKILL" ]; then
  _ralph_review="Use the \`$RALPH_REVIEW_SKILL\` skill to review the work since $BASE_REF against the ticket."
else
  _ralph_review="Review your own work since $BASE_REF against the ticket, as a reviewer would: correctness
first, then whether it actually does what the ticket asked."
fi

# Only the clone arrangement makes an uncommitted change a *lost* change, so only it gets
# the warning. The other two modes commit into the tree the loop is watching.
if [ "$RALPH_EXEC" = "sandbox" ]; then
  _ralph_commit="Commit everything. You are on a private clone of the repository; committing to the
   current branch is how the work gets back to the host, so an uncommitted change is a
   lost change. Do not push."
else
  _ralph_commit="Commit everything to the current branch. Do not push."
fi

# ---------------------------------------------------------------------------
# Substitution
#
# The short slots go through ${var//…}. The two free-text blocks — the batch's
# prompt-extra.md and the agent's own progress notes — are CONCATENATED instead: they are
# arbitrary prose, and bash's pattern substitution treats backslashes in a replacement as
# escapes, which would quietly mangle any Windows path or regex someone wrote there.
# ---------------------------------------------------------------------------
# A CRLF checkout of the template would put a stray carriage return at the end of every
# line of the prompt. Strip them for the same reason ralph-config.sh strips its conf.
_ralph_body="$(tr -d $'\r' < "$_ralph_template")"

_ralph_body="${_ralph_body//__ORDER_SENTENCE__/$_ralph_order_sentence}"
_ralph_body="${_ralph_body//__PROGRESS_FILE__/$PROGRESS_FILE}"
_ralph_body="${_ralph_body//__BASE_REF__/$BASE_REF}"
_ralph_body="${_ralph_body//__TDD_INSTRUCTION__/$_ralph_tdd}"
_ralph_body="${_ralph_body//__ITERATIVE_CHECK_BLOCK__/$_ralph_iterative}"
_ralph_body="${_ralph_body//__VERIFY_BLOCK__/$_ralph_verify}"
_ralph_body="${_ralph_body//__REVIEW_INSTRUCTION__/$_ralph_review}"
_ralph_body="${_ralph_body//__COMMIT_NOTE__/$_ralph_commit}"
_ralph_body="${_ralph_body//__STATUS_LINE__/$RALPH_STATUS_LINE}"
_ralph_body="${_ralph_body//__DONE_WORD__/$RALPH_DONE_WORD}"

_ralph_extra=""
if [ -f "$PROMPT_EXTRA_FILE" ] && [ -s "$PROMPT_EXTRA_FILE" ]; then
  _ralph_extra="
## Project-specific instructions

$(cat "$PROMPT_EXTRA_FILE")
"
fi

case "$_ralph_body" in
  *__PROMPT_EXTRA__*)
    RALPH_PROMPT_BODY="${_ralph_body%%__PROMPT_EXTRA__*}${_ralph_extra}${_ralph_body#*__PROMPT_EXTRA__}"
    ;;
  *)
    RALPH_PROMPT_BODY="$_ralph_body$_ralph_extra"
    ;;
esac

# ---------------------------------------------------------------------------
# The progress excerpt
#
# progress.txt grows by one write-up per iteration, so attaching it whole would cost more
# every run. Only the tail goes into the prompt; appends still go to the full file.
#
# It is INLINED AS TEXT rather than attached with `@`. In sandbox-clone mode the agent
# works on its own clone, where a gitignored scratch file from the host does not exist —
# an `@`-attachment would silently resolve to nothing. (That is not hypothetical: it is
# what went wrong for a whole round before this was noticed.)
# ---------------------------------------------------------------------------
PROGRESS_TAIL=$(tail -c "$RALPH_PROGRESS_TAIL_BYTES" "$PROGRESS_FILE" 2>/dev/null || true)
[ -n "$PROGRESS_TAIL" ] || PROGRESS_TAIL='(nothing recorded yet — this is the first iteration.)'

RALPH_PROMPT="@${TICKET_FILE}

${RALPH_PROMPT_BODY}

## Where the last few iterations got to

The most recent excerpt of ${PROGRESS_FILE} (it is appended to every iteration, so the
full history is not repeated here to keep prompts cheap). Each ticket's own
'${RALPH_STATUS_LINE}' line, not this excerpt, is the source of truth for what has landed.

<progress-excerpt>
${PROGRESS_TAIL}
</progress-excerpt>"

unset _ralph_template _ralph_order_sentence _ralph_tdd _ralph_iterative _ralph_verify
unset _ralph_review _ralph_commit _ralph_body _ralph_extra
