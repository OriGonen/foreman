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
# Costs one model call. If `claude` is not on PATH, this prints a note and exits 0 rather
# than failing whatever called it — order.md just keeps its filename order.
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

# shellcheck source=ralph-repo.sh
source "$RALPH_TOOL_DIR/ralph-repo.sh" || {
  echo "ralph order: cannot load $RALPH_TOOL_DIR/ralph-repo.sh" >&2; exit 1; }

REPO_ROOT="$(ralph_repo_root)" || {
  echo "ralph order: not inside a git repository." >&2; exit 1; }

BATCH_DIR="$(ralph_batch_relpath "$BATCH_INPUT" "$REPO_ROOT")"
case "$?" in
  1) echo "ralph order: $BATCH_INPUT is not a directory" >&2; exit 1 ;;
  2) echo "ralph order: the batch directory must be inside $REPO_ROOT" >&2; exit 1 ;;
esac
cd "$REPO_ROOT" || exit 1

[ -f "$BATCH_DIR/order.md" ] || {
  echo "ralph order: $BATCH_DIR/order.md does not exist — run: ralph init $BATCH_DIR" >&2
  exit 1
}

if ! command -v claude >/dev/null 2>&1; then
  echo "ralph order: 'claude' is not on PATH — skipping." >&2
  echo "              $BATCH_DIR/order.md keeps its filename order; re-run \`ralph order $BATCH_DIR\` once it is." >&2
  exit 0
fi

# The batch's own ticket list, from the one file that knows how a batch answers that —
# including any RALPH_ISSUES_DIRS the conf sets. `--unordered` rather than `--all` because
# re-ordering has to see tickets added since order.md was last written.
tickets=()
while IFS= read -r f; do
  [ -n "$f" ] && tickets+=("$f")
done < <(bash "$RALPH_TOOL_DIR/ralph-next.sh" "$BATCH_DIR" --unordered)

if [ "${#tickets[@]}" -eq 0 ]; then
  echo "ralph order: $BATCH_DIR has no tickets — nothing to order."
  exit 0
fi

MODEL="${RALPH_MODEL:-claude-sonnet-5}"
EFFORT="${RALPH_EFFORT:-high}"

PROMPT=$(cat <<PROMPT_EOF
You are ordering the tickets in $BATCH_DIR for the ralph ticket loop, which implements
exactly one ticket per iteration, in the order given, committing each before moving to the
next.

Read every ticket listed below and the current $BATCH_DIR/order.md. Then edit
$BATCH_DIR/order.md in place, and change nothing else:

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
  echo "ralph order: the agent call failed (exit $status) — $BATCH_DIR/order.md is unchanged." >&2
  exit 1
fi

cost=$(node -e '
  try {
    const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
    if (typeof p.total_cost_usd === "number") process.stdout.write(p.total_cost_usd.toFixed(4));
  } catch {}
' <<< "$RESPONSE")

echo "ralph order: wrote $BATCH_DIR/order.md${cost:+ (cost \$$cost)}"
echo "             review it — this is a first pass, not a guarantee."
