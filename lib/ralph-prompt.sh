#!/bin/bash
# Assembles one iteration's prompt. Sourced by ralph-loop.sh, not executed.
#
# Requires: TICKET_FILE, and the variables ralph-config.sh sets (BATCH_DIR, ORDER_FILE,
# PROGRESS_FILE, PROMPT_EXTRA_FILE, RALPH_*). BASE_REF defaults to HEAD. The exec adapter
# is loaded here if the caller has not already loaded one.
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

# What "commit your work" means depends on where the work is happening — only the clone
# arrangement makes an uncommitted change a *lost* change — so the adapter says it, not
# this file. ralph-loop.sh has already loaded one; the guard is for anything that sources
# this file on its own.
if ! declare -F exec_commit_note >/dev/null 2>&1; then
  # shellcheck source=ralph-exec.sh
  source "$RALPH_TOOL_DIR/ralph-exec.sh" && ralph_exec_load "$RALPH_EXEC" || {
    echo "ralph-prompt.sh: cannot load the '$RALPH_EXEC' exec adapter" >&2
    return 1 2>/dev/null || exit 1
  }
fi
_ralph_commit="$(exec_commit_note)"

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
#
# Two caps, entries first and then bytes, so whichever of them cuts more is the one that
# wins.
#
# The entry cap is opt-in (RALPH_PROGRESS_TAIL_ENTRIES=0 disables it) and keeps the last N
# write-ups whole. Entries are delimited by the `--- <ticket>` line step 5.2 of the
# template asks for, so a progress.txt written before that instruction existed has no
# markers at all — in which case this does nothing and the byte cap alone applies, rather
# than cutting the file somewhere that means nothing.
#
# The byte cap always runs, over whatever is left. `tail -c` cuts at a byte, so its first
# line is normally the back half of a sentence — paid for and unusable. Drop it, but only
# when the cut actually happened: a file under the cap would otherwise lose a real line.
# ---------------------------------------------------------------------------
_ralph_progress_src="$PROGRESS_FILE"
_ralph_progress_tmp=""
if [ "$RALPH_PROGRESS_TAIL_ENTRIES" -gt 0 ] && grep -q '^--- ' "$PROGRESS_FILE" 2>/dev/null; then
  _ralph_progress_tmp="$(mktemp)" && awk -v keep="$RALPH_PROGRESS_TAIL_ENTRIES" '
    /^--- / { n++; starts[n] = NR }
    { line[NR] = $0 }
    END {
      first = (n > keep) ? starts[n - keep + 1] : 1
      for (i = first; i <= NR; i++) print line[i]
    }
  ' "$PROGRESS_FILE" > "$_ralph_progress_tmp" && _ralph_progress_src="$_ralph_progress_tmp"
fi

_ralph_progress_size=$(wc -c < "$_ralph_progress_src" 2>/dev/null | tr -cd '0-9')
[ -n "$_ralph_progress_size" ] || _ralph_progress_size=0
if [ "$_ralph_progress_size" -gt "$RALPH_PROGRESS_TAIL_BYTES" ]; then
  PROGRESS_TAIL=$(tail -c "$RALPH_PROGRESS_TAIL_BYTES" "$_ralph_progress_src" | sed 1d)
else
  PROGRESS_TAIL=$(cat "$_ralph_progress_src" 2>/dev/null || true)
fi
[ -n "$PROGRESS_TAIL" ] || PROGRESS_TAIL='(nothing recorded yet — this is the first iteration.)'
[ -n "$_ralph_progress_tmp" ] && rm -f "$_ralph_progress_tmp"

# ---------------------------------------------------------------------------
# Assembly, invariant part first.
#
# Leading with the parts that do not change from iteration to iteration is what gives a
# prompt cache a prefix to hit on. Here that prefix runs from the top of the template
# through step 3 and prompt-extra.md; it ends at step 4, whose review instruction names
# BASE_REF and so differs every time. That is most of the body, where before it was
# nothing at all — the ticket path used to be the very first thing in the prompt.
#
# Worth being honest about the payoff: it only materialises when two iterations of a batch
# land inside the cache's TTL, which a batch of long tickets will not, so it may be worth
# nothing. It costs nothing either — an `@` reference resolves wherever it appears.
# ---------------------------------------------------------------------------
RALPH_PROMPT="${RALPH_PROMPT_BODY}

## The ticket

@${TICKET_FILE}

## Where the last few iterations got to

The most recent excerpt of ${PROGRESS_FILE} (it is appended to every iteration, so the
full history is not repeated here to keep prompts cheap). Each ticket's own
'${RALPH_STATUS_LINE}' line, not this excerpt, is the source of truth for what has landed.

<progress-excerpt>
${PROGRESS_TAIL}
</progress-excerpt>"

# A previous attempt on this ticket ran out of context (ralph-loop.sh sets the flag). One
# fixed sentence: what crosses from the failed attempt is the CATEGORY of constraint that
# bit it, never anything it said or did. There is no narrative here to anchor the retry on
# a wrong approach, and no self-report to have to trust. Appended last so it does not break
# the cacheable prefix the assembly above is arranged around.
if [ "${RALPH_CONTEXT_RETRY:-0}" = "1" ]; then
  RALPH_PROMPT+="

A previous attempt on this ticket ran out of context. Work more economically this time:
read only what the ticket names, do not re-survey the repository, and work in smaller
checkpointed steps, committing as you go."
fi

unset _ralph_template _ralph_order_sentence _ralph_tdd _ralph_iterative _ralph_verify
unset _ralph_review _ralph_commit _ralph_body _ralph_extra
unset _ralph_progress_size _ralph_progress_src _ralph_progress_tmp
