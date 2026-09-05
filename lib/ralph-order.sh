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
# something cheaper without touching RALPH_MODEL. Effort is RALPH_ORDERING_EFFORT, high by
# default. If `claude` is not on PATH, this prints a note and exits 0 rather than failing
# whatever called it — order.md just keeps its filename order.
#
# The call is skipped entirely for a batch of one ticket that order.md already lists: there
# is no order left to decide. A stale order.md is still sent, since picking up tickets added
# since it was written is half of what this command is for.
set -uo pipefail

RALPH_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

[ -f "$ORDER_FILE" ] || {
  echo "ralph order: $ORDER_FILE does not exist — run: ralph init $BATCH_DIR" >&2
  exit 1
}

# The batch's own ticket list, from the one file that knows how a batch answers that —
# including any RALPH_ISSUES_DIRS the conf sets. `--unordered` rather than `--all` because
# re-ordering has to see tickets added since order.md was last written.
#
# Gathered before the PATH check below, because the "nothing to decide" cases are answers
# in their own right and should not depend on having a runner installed.
tickets=()
while IFS= read -r f; do
  [ -n "$f" ] && tickets+=("$f")
done < <(bash "$RALPH_TOOL_DIR/ralph-next.sh" "$BATCH_DIR" --unordered)

if [ "${#tickets[@]}" -eq 0 ]; then
  echo "ralph order: $BATCH_DIR has no tickets — nothing to order."
  exit 0
fi

# One ticket, and order.md already lists exactly it: there is no order left to decide, so
# a model call would only write back what is there. Both halves matter. The count alone is
# not enough — `ralph order` also exists to pick up tickets added since order.md was last
# written, and ralph-next.sh's `--all` reads only the ORDER block, so skipping on the count
# would silently leave a new ticket out of the order and the loop would never run it.
#
# Deliberately not extended to two tickets: which of them goes first is exactly the
# question, and getting it backwards costs more than the one small call it would save.
if [ "${#tickets[@]}" -eq 1 ]; then
  ordered=$(bash "$RALPH_TOOL_DIR/ralph-next.sh" "$BATCH_DIR" --all 2>/dev/null || true)
  if [ "$ordered" = "${tickets[0]}" ]; then
    echo "ralph order: $BATCH_DIR has one ticket — the order is already decided."
    echo "             $ORDER_FILE is unchanged."
    exit 0
  fi
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "ralph order: 'claude' is not on PATH — skipping." >&2
  echo "              $ORDER_FILE keeps its filename order; re-run \`ralph order $BATCH_DIR\` once it is." >&2
  exit 0
fi

# Ordering is a much smaller job than implementing a ticket, so it defaults to RALPH_MODEL
# rather than automatically riding whatever the tickets themselves run on — set
# RALPH_ORDERING_MODEL in ralph.conf to point it at something cheaper.
#
# Effort defaults to high rather than following RALPH_EFFORT, because reading every ticket
# and weighing dependencies is the one place in this toolkit where skimping risks a bad
# order that then propagates through every iteration of the batch. RALPH_ORDERING_EFFORT is
# there for anyone who has decided otherwise for their batch; nothing changes if it is unset.
MODEL="${RALPH_ORDERING_MODEL:-$RALPH_MODEL}"
EFFORT="${RALPH_ORDERING_EFFORT:-high}"

PROMPT=$(cat <<PROMPT_EOF
You are ordering the tickets in $BATCH_DIR for the ralph ticket loop, which implements
exactly one ticket per iteration, in the order given, committing each before moving to the
next.

Read every ticket listed below and the current $ORDER_FILE. Then edit
$ORDER_FILE in place, and change nothing else:

1. Decide a run order, weighing three things:
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
