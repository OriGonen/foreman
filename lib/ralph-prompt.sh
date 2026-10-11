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

# ---------------------------------------------------------------------------
# The checkpoint prompt — the short, single-purpose turn the loop runs when an iteration's
# own turn stalled: it ended cleanly, with its work still sitting uncommitted. Not a second
# template: with only four variable parts (the ticket, the base to diff against, the
# adapter's own commit note, and the progress file) a template would be more machinery than
# the prompt it holds, so it is built directly here, beside the main prompt assembly.
#
# A function, not top-level code like the rest of this file: ralph-loop.sh calls it only
# when a turn has actually stalled, never every iteration. It diffs against THIS turn's own
# base, never REVIEW_BASE above — a checkpoint turn does not review the ticket, it only
# preserves whatever this one turn left behind.
# ---------------------------------------------------------------------------
ralph_checkpoint_prompt() {    # ralph_checkpoint_prompt TICKET BASE
  local ticket="$1" base="$2"
  cat <<EOF
This is a CHECKPOINT TURN, not a continuation of ${ticket}. A previous turn on this ticket
ran out of room and ended with its work sitting uncommitted in the tree. Your only job is to
preserve that work — do not write, edit, or plan any more of the ticket's own implementation,
and do not investigate whether it is correct.

1. Commit first, before you look at anything. Your FIRST command is exactly:
   git add -A && git commit -q -m 'wip: ${ticket} — remaining: see ${PROGRESS_FILE}' && git show --stat --format= HEAD
   $(exec_commit_note)
   This turn has only a few tool calls. Reading the diff before committing is how a
   checkpoint turn runs out of them with nothing saved.
2. If that listing includes build output or tool caches (\`build/\`, \`.kotlin/\`,
   \`node_modules/\`, \`__pycache__/\` and the like), take them back out with
   \`git rm -r -q --cached <dir> && git commit -q --amend --no-edit\`. Do not edit .gitignore.
3. Now look at what you committed: \`git diff ${base} --stat\`, then \`git diff ${base}\`. Open
   a file on its own only if that output was truncated.
4. Append an entry to ${PROGRESS_FILE} describing what the diff contains, ending in a
   'Remaining:' list of what is left. You did not do this work and were not told why it was
   done this way — write only what the diff shows, never what you guess was intended.
5. Commit the entry: \`git add -A && git commit -m 'wip: ${ticket} — remaining: <short summary
   of what is left>'\`. If git says there is nothing to commit, the progress file is not
   tracked here, and the commit from step 1 is enough.
6. Do not touch the '${RALPH_STATUS_LINE}' line — this ticket has not landed.

Stop as soon as step 5 is done. Do nothing else.
EOF
}

# ---------------------------------------------------------------------------
# The review checkpoint prompt — the start-of-run variant. An EARLIER run stopped part-way
# through a turn (a usage limit, Ctrl-C, a closed terminal, or a stall it could not salvage)
# and left work uncommitted; nobody has looked at it since, and unlike the mid-run stall the
# turn that wrote it may have been cut off mid-file. So this turn reads the diff against the
# ticket before committing it, and may refuse.
#
# Reading only: interrupted work usually fails its checks, so running them would be paid for
# and say little, and the next iteration runs them anyway. A refusal is a sentinel line in
# the reply, not a file — on the clone sandbox a file written in the clone never comes back.
# "CHECKPOINT TURN" stays in the first line: the fake adapter recognises the turn by it.
# ---------------------------------------------------------------------------
RALPH_REVIEW_REJECTED_SENTINEL="RALPH_REVIEW: REJECTED"

ralph_review_checkpoint_prompt() {    # ralph_review_checkpoint_prompt TICKET BASE
  local ticket="$1" base="$2"
  cat <<EOF
This is a REVIEW CHECKPOINT TURN, not a continuation of ${ticket}. An earlier run stopped
part-way through this ticket — a usage limit, an interrupt, or a turn that ran out of room —
and left its work sitting uncommitted in the tree. It may have been cut off mid-edit. Your
job is to judge that work by reading it, and then either preserve it or refuse it. Do not
write, edit, fix or finish any of the ticket's implementation, and do not run builds, tests
or checks: the work is expected to be unfinished, and the next turn verifies it.

1. Read ${ticket}. Then run \`git add -N .\` (intent-to-add: it lists untracked files in the
   index as empty placeholders, staging no content) and \`git diff ${base}\`, which now shows
   new and modified files together in one output. Open a file separately only if that diff
   output was truncated.
2. Decide whether this is work on ${ticket}. REFUSE it only for a clear red flag:
   - changes plainly outside the ticket's scope (unrelated files or features);
   - secrets or credentials (keys, tokens, passwords, .env contents);
   - mass deletion, or content that is garbage rather than code or prose.
   Incomplete, rough or broken work is NOT a red flag — that is what a checkpoint is for.
3. If you refuse: commit nothing, change nothing, and end your reply with exactly one line:
   ${RALPH_REVIEW_REJECTED_SENTINEL}: <the reasons, on one line>
   Then stop.
4. Otherwise append an entry to ${PROGRESS_FILE} describing what the diff contains, ending
   in a 'Remaining:' list of what is left. Include what you noticed reading it: truncated
   files, stubs, TODOs, half-written functions. You did not do this work — write only what
   the diff shows, never what you guess was intended.
5. Commit everything as-is, the progress entry included: \`git add -A && git commit -m
   'wip: ${ticket} — remaining: <short summary of what is left>'\`. $(exec_commit_note)
6. Do not touch the '${RALPH_STATUS_LINE}' line — this ticket has not landed.

Stop as soon as the commit exists, or the refusal line is written.
EOF
}

BASE_REF="${BASE_REF:-$(git rev-parse HEAD)}"

# The commit the agent's work is REVIEWED against. Normally this iteration's BASE_REF, and
# the two are the same for every ticket that lands in one go. On a continuation the loop
# passes the ticket's FIRST base instead, so the landing iteration reviews the ticket's
# whole diff rather than only its last chunk — chunking that silently produced unreviewed
# code would be worse than the bug it exists to fix.
#
# Only the review base moves. exec_sync_down and exec_collect keep using BASE_REF: a
# continuation that synced down to the ticket's original base would reset the sandbox clone
# over its own committed chunk.
REVIEW_BASE="${RALPH_REVIEW_BASE:-$BASE_REF}"

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
  _ralph_review="Use the \`$RALPH_REVIEW_SKILL\` skill to review the work since $REVIEW_BASE against the ticket."
else
  _ralph_review="Review your own work since $REVIEW_BASE against the ticket, as a reviewer would: correctness
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
# All slots go through _ralph_fill rather than bash's ${var//pat/repl}: in a replacement,
# `&` means "the text that matched" and `\` escapes the next character, so a RALPH_TEST_CMD
# containing either (a shell `&&`, a Windows path, a regex) would come out mangled — and
# there is no way to escape those in the replacement text either, since the escaping is
# itself subject to the same rule. _ralph_fill does a literal split-and-concat instead, the
# same strategy already used for the free-text blocks below.
# ---------------------------------------------------------------------------
# A CRLF checkout of the template would put a stray carriage return at the end of every
# line of the prompt. Strip them for the same reason ralph-config.sh strips its conf.
_ralph_body="$(tr -d $'\r' < "$_ralph_template")"

_ralph_fill() {                    # _ralph_fill <marker> <value> — rewrites _ralph_body
  local marker="$1" value="$2" out=""
  while [ "${_ralph_body#*"$marker"}" != "$_ralph_body" ]; do
    out+="${_ralph_body%%"$marker"*}$value"
    _ralph_body="${_ralph_body#*"$marker"}"
  done
  _ralph_body="$out$_ralph_body"
}

_ralph_fill __ORDER_SENTENCE__ "$_ralph_order_sentence"
_ralph_fill __PROGRESS_FILE__ "$PROGRESS_FILE"
_ralph_fill __BASE_REF__ "$REVIEW_BASE"
_ralph_fill __CONTEXT_BUDGET__ "$RALPH_CONTEXT_BUDGET_TOKENS"
_ralph_fill __TDD_INSTRUCTION__ "$_ralph_tdd"
_ralph_fill __ITERATIVE_CHECK_BLOCK__ "$_ralph_iterative"
_ralph_fill __VERIFY_BLOCK__ "$_ralph_verify"
_ralph_fill __REVIEW_INSTRUCTION__ "$_ralph_review"
_ralph_fill __COMMIT_NOTE__ "$_ralph_commit"
_ralph_fill __STATUS_LINE__ "$RALPH_STATUS_LINE"
_ralph_fill __DONE_WORD__ "$RALPH_DONE_WORD"

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

# A previous iteration committed progress on this ticket without landing it, and the loop
# is continuing it rather than counting it as a failure (ralph-loop.sh sets the flag). This
# goes at the TOP, ahead of the instructions: an agent that reads "implement the attached
# ticket" and starts from nothing has already wasted the handoff the last one wrote.
#
# Two variants, because the two handoffs are not equally trustworthy. A deliberate handoff
# was written by the same turn that did the work, so its 'Remaining:' list reflects intent.
# A stall's handoff was reconstructed from the diff by a checkpoint turn that never saw the
# reasoning (ralph-loop.sh sets RALPH_STALL_CONTINUATION for exactly this case) — it
# describes what is there, not what was planned, and may be missing intent entirely.
_ralph_continuation=""
if [ "${RALPH_STALL_CONTINUATION:-0}" = "1" ]; then
  _ralph_continuation="You are CONTINUING this ticket, not starting it. The previous turn on it ran out of room
before it could commit its own work or explain it; a checkpoint turn salvaged the uncommitted
diff and reconstructed the most recent ${PROGRESS_FILE} entry from that diff alone. Treat its
'Remaining:' list as a description of what the diff contains, not of what was planned — it may
be missing intent entirely. Before doing anything else, read that entry and the commits since
${REVIEW_BASE}, and pick up from there rather than starting over. Work in smaller pieces and
commit sooner than the previous turn did.

"
elif [ "${RALPH_CONTINUATION:-0}" = "1" ]; then
  _ralph_continuation="You are CONTINUING this ticket, not starting it. A previous iteration did part of the work
and committed it; the ticket has not landed yet. Before doing anything else, read the most
recent ${PROGRESS_FILE} entry — it ends with a 'Remaining:' list — and the commits since
${REVIEW_BASE}, and pick up from there rather than starting over.

"
fi

RALPH_PROMPT="@${TICKET_FILE}

${_ralph_continuation}${RALPH_PROMPT_BODY}

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
# a wrong approach, and no self-report to have to trust.
if [ "${RALPH_CONTEXT_RETRY:-0}" = "1" ]; then
  RALPH_PROMPT+="

A previous attempt on this ticket ran out of context. Work more economically this time:
read only what the ticket names, do not re-survey the repository, and work in smaller
checkpointed steps, committing as you go."
fi

unset _ralph_template _ralph_order_sentence _ralph_tdd _ralph_iterative _ralph_verify
unset _ralph_review _ralph_commit _ralph_body _ralph_extra _ralph_continuation
unset -f _ralph_fill
