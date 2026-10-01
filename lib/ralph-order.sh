#!/bin/bash
# Has an agent read a batch's tickets and rewrite order.md: the run order, weighing
# dependencies, importance and each ticket's apparent load, plus the reasoning behind it.
#
#   ralph order <batch>
#
# Runs automatically at the end of `ralph init`. Re-run it by hand after tickets change.
#
# Read-only over the tickets themselves — the only file it writes is <batch>/order.md.
# Runs locally, never in a sandbox: it edits no code, so none of RALPH_EXEC's isolation
# concerns apply, and it should work even in a repo that has no sandbox set up yet.
#
# Costs one model call, on RALPH_MODEL by default — ordering rarely needs the same model
# the tickets themselves run on, so set RALPH_ORDERING_MODEL in ralph.conf to point it at
# something cheaper without touching RALPH_MODEL. If `claude` is not on PATH, this prints a
# note and exits 0 rather than failing whatever called it — order.md just keeps its
# filename order.
set -uo pipefail

# This file's directory, from the shell and not `dirname` (see ralph-config.sh).
RALPH_TOOL_DIR="${BASH_SOURCE[0]%/*}"; [ "$RALPH_TOOL_DIR" != "${BASH_SOURCE[0]}" ] || RALPH_TOOL_DIR=.
RALPH_TOOL_DIR="$(cd "${RALPH_TOOL_DIR:-/}" && pwd)"

show_help() { awk 'NR==1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; }

BATCH_INPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    -*) echo "Usage: ralph order <batch>" >&2; exit 1 ;;
    *) BATCH_INPUT="$1" ;;
  esac
  shift
done
[ -n "$BATCH_INPUT" ] || { echo "Usage: ralph order <batch>" >&2; exit 1; }

# ralph-config.sh gives us BATCH_DIR, ORDER_FILE and RALPH_MODEL resolved the same way
# every other ralph command resolves them — env, then this batch's ralph.conf, then
# defaults — so RALPH_ORDERING_MODEL set there is honoured without this script knowing
# anything about ralph.conf's format itself.
export RALPH_BATCH="$BATCH_INPUT"
# shellcheck source=ralph-config.sh
source "$RALPH_TOOL_DIR/ralph-config.sh" || exit 1
# shellcheck source=ralph-human.sh
source "$RALPH_TOOL_DIR/ralph-human.sh" || exit 1
# shellcheck source=ralph-tickets.sh
source "$RALPH_TOOL_DIR/ralph-tickets.sh" || exit 1

[ -f "$ORDER_FILE" ] || {
  echo "ralph order: $ORDER_FILE does not exist — run: ralph init $BATCH_DIR" >&2
  exit 1
}

if ! command -v claude >/dev/null 2>&1; then
  echo "ralph order: 'claude' is not on PATH — skipping." >&2
  echo "              $ORDER_FILE keeps its filename order; re-run \`ralph order $BATCH_DIR\` once it is." >&2
  exit 0
fi

# The batch's own ticket list, from the one place that knows how a batch answers that
# (ralph-tickets.sh) —
# including any RALPH_ISSUES_DIRS the conf sets. `--unordered` rather than `--all` because
# re-ordering has to see tickets added since order.md was last written.
tickets=()
while IFS= read -r f; do
  [ -n "$f" ] && tickets+=("$f")
done < <(ralph_next_answer --unordered)

if [ "${#tickets[@]}" -eq 0 ]; then
  echo "ralph order: $BATCH_DIR has no tickets — nothing to order."
  ralph_issues_hint
  exit 0
fi

# Human tickets and followup tickets change how the order is chosen, so the agent is told
# about them only when this batch actually has one — an ordinary batch gets the prompt it
# always got.
human_tickets=()
has_checks=0
for t in "${tickets[@]}"; do
  ralph_ticket_status "$t"
  [ "$_RALPH_TICKET_HUMAN" = 1 ] && human_tickets+=("$t")
  [ -n "$_RALPH_TICKET_CHECKS" ] && has_checks=1
done

HUMAN_SECTION=""
if [ "${#human_tickets[@]}" -gt 0 ]; then
  HUMAN_SECTION=$(cat <<HUMAN_EOF


HUMAN TICKETS. These tickets are done by a person, not by the loop:
$(for t in "${human_tickets[@]}"; do printf -- '- %s\n' "$t"; done)
The loop stops at the first human ticket it reaches and runs nothing after it until a
person has finished it. So, for each human ticket:
- it comes after every ticket it depends on;
- every ticket that depends on it — directly, or through another ticket — comes after it;
- it goes as LATE as those two rules allow: every ticket that does not depend on it,
  directly or transitively, goes before it, so the unattended stretch before each stop is
  as long as possible.
In the prose above the order block, name each human ticket, the tickets that wait on it,
and why it sits where it does.
HUMAN_EOF
)
fi

CHECK_SECTION=""
if [ "$has_checks" -eq 1 ]; then
  CHECK_SECTION=$(cat <<CHECK_EOF


FOLLOWUP TICKETS. A ticket with a \`Checks:\` line verifies the ticket it names. It goes
IMMEDIATELY after that ticket, with nothing between them: an unrelated ticket in between
could build on work that has not been checked yet.
CHECK_EOF
)
fi

# Ordering is a much smaller job than implementing a ticket, so it defaults to RALPH_MODEL
# rather than automatically riding whatever the tickets themselves run on — set
# RALPH_ORDERING_MODEL in ralph.conf to point it at something cheaper. Effort stays fixed
# at high regardless of RALPH_EFFORT: reading every ticket and weighing dependencies is the
# one place in this toolkit where skimping on effort risks a bad order, even on a small model.
MODEL="${RALPH_ORDERING_MODEL:-$RALPH_MODEL}"
EFFORT=high

PROMPT=$(cat <<PROMPT_EOF
You are ordering the tickets in $BATCH_DIR for the ralph ticket loop, which implements
exactly one ticket per iteration, in the order given, committing each before moving to the
next.

Read every ticket listed below and the current $ORDER_FILE. Then edit
$ORDER_FILE in place, and change nothing else:

1. Decide a run order, weighing these in priority order: dependencies first, then
   human-ticket placement and followup-ticket adjacency (see below, when this batch has
   either), then importance, then load.
   - DEPENDENCIES. A ticket that reads or builds on something another ticket creates must
     come after it. Two tickets that touch the same file or area should be adjacent, so a
     conflict between them is a sequential edit rather than a merge.
   - IMPORTANCE. Foundational work, or anything several other tickets depend on, goes
     first. Polish and sweep-every-surface tickets go last.
   - LOAD. Each ticket's apparent size or complexity — how much it asks for, how many
     files or seams it likely touches. Prefer not to front-load a run with every large
     ticket back to back when the dependency graph allows spreading them out.
2. Replace the prose above the <!-- ORDER:BEGIN --> marker with your reasoning. Name
   tickets specifically: which dependency chains you found, why anything heavy or
   foundational landed where it did, and any dependency that crosses issue directories or
   isn't obvious from the filenames.
3. Replace the block between <!-- ORDER:BEGIN --> and <!-- ORDER:END --> with the ordered,
   repo-relative ticket paths, one per line, inside the existing code fence.
4. Do not edit any ticket file. Do not invent a ticket that is not in the list below, and
   do not drop one that is.
${HUMAN_SECTION}${CHECK_SECTION}

A ticket's \`Blocked by:\` line, when it has one, is an explicit dependency: honour it
exactly.

Tickets in $BATCH_DIR:
$(for t in "${tickets[@]}"; do printf -- '- %s\n' "$t"; done)
PROMPT_EOF
)

echo "ralph order: reading ${#tickets[@]} ticket(s) in $BATCH_DIR ..."

RESPONSE=$(claude --model "$MODEL" --effort "$EFFORT" --permission-mode acceptEdits \
  --print --output-format json -p "$PROMPT")
status=$?

if [ "$status" -ne 0 ]; then
  echo "ralph order: the agent call failed (exit $status) — $ORDER_FILE is unchanged." >&2
  exit 1
fi

cost=$(node -e '
  try {
    const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
    if (typeof p.total_cost_usd === "number") process.stdout.write(p.total_cost_usd.toFixed(4));
  } catch {}
' <<< "$RESPONSE")

echo "ralph order: wrote $ORDER_FILE${cost:+ (cost \$$cost)}"
echo "             review it — this is a first pass, not a guarantee."

warnings="$(ralph_human_warnings)"
[ -n "$warnings" ] && printf '%s\n' "$warnings"
exit 0
