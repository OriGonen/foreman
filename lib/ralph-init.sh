#!/bin/bash
# Scaffolds a ralph batch in a directory that already has tickets.
#
#   ralph init <batch-dir>
#   ralph init <batch-dir> --force      overwrite what is already there
#   ralph init <batch-dir> --no-order   skip the automatic ordering pass
#
# <batch-dir> is a directory in the CURRENT repository. The toolkit itself lives elsewhere
# and nothing is copied into your repo except this batch's three files.
#
# Creates, if missing:
#   <batch>/ralph.conf     from ralph.conf.template — every knob, all commented out
#   <batch>/order.md       generated from <batch>/issues/*.md in filename order, with the
#                          machine-readable ORDER block the loop reads
#   <batch>/progress.txt   empty, with a one-line header
#
# It never touches a ticket file, and it never overwrites without --force.
#
# order.md is then handed to an agent — see ralph-order.sh — which rewrites the run order
# and the reasoning above it, weighing dependencies between tickets, which look foundational
# or important, and each ticket's apparent load. That costs one model call; skip it with
# --no-order and order.md is left in plain filename order, same as before that step existed.
# Either way, order.md is optional: delete it and the loop falls back to filename order over
# <batch>/issues.
set -uo pipefail

RALPH_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FORCE=0
NO_ORDER=0
BATCH_INPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --no-order) NO_ORDER=1 ;;
    --help|-h) awk 'NR==1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    -*) echo "Usage: $0 <batch-dir> [--force] [--no-order]" >&2; exit 1 ;;
    *) BATCH_INPUT="$1" ;;
  esac
  shift
done

if [ -z "$BATCH_INPUT" ]; then
  echo "Usage: $0 <batch-dir> [--force] [--no-order]" >&2
  exit 1
fi

# shellcheck source=ralph-repo.sh
source "$RALPH_TOOL_DIR/ralph-repo.sh" || {
  echo "ralph-init: cannot load $RALPH_TOOL_DIR/ralph-repo.sh" >&2; exit 1; }

REPO_ROOT="$(ralph_repo_root)" || {
  echo "ralph-init: not inside a git repository" >&2; exit 1; }

# The batch has to exist before git can tell us where it is, and creating it is this
# script's job anyway.
mkdir -p "$BATCH_INPUT" || exit 1

BATCH_DIR="$(ralph_batch_relpath "$BATCH_INPUT" "$REPO_ROOT")"
case "$?" in
  1) echo "ralph-init: $BATCH_INPUT is not a directory" >&2; exit 1 ;;
  2) echo "ralph-init: the batch directory must be inside $REPO_ROOT" >&2; exit 1 ;;
esac

# Everything below writes repo-relative paths, so stand at the repo root.
cd "$REPO_ROOT" || exit 1

wrote_any=0
order_written=0

write_if_absent() {
  local target="$1"
  if [ -e "$target" ] && [ "$FORCE" -eq 0 ]; then
    echo "   kept     $target (already exists — pass --force to replace)"
    return 1
  fi
  return 0
}

echo "Batch: $BATCH_DIR"

# --- ralph.conf ------------------------------------------------------------
if write_if_absent "$BATCH_DIR/ralph.conf"; then
  cp "$RALPH_TOOL_DIR/ralph.conf.template" "$BATCH_DIR/ralph.conf" || exit 1
  echo "   created  $BATCH_DIR/ralph.conf"
  wrote_any=1
fi

# --- order.md --------------------------------------------------------------
if write_if_absent "$BATCH_DIR/order.md"; then
  # What tickets this batch has is ralph-next.sh's question, not this file's: it is the
  # one place that knows about RALPH_ISSUES_DIRS and RALPH_ISSUES_EXCLUDE, so a batch
  # whose ralph.conf points somewhere other than `issues/` is scaffolded from the right
  # directory. `--unordered` is what makes this safe under --force, too: it never reads
  # the order.md we are about to overwrite.
  tickets=()
  while IFS= read -r file; do
    [ -n "$file" ] && tickets+=("$file")
  done < <(bash "$RALPH_TOOL_DIR/ralph-next.sh" "$BATCH_DIR" --unordered)

  {
    echo "# $(basename "$BATCH_DIR") — implementation order"
    echo
    echo "\`ralph-loop.sh\` reads the block at the bottom of this file, takes the first ticket"
    echo "whose Status line is not flipped, and runs exactly that one."
    echo
    if [ "${#tickets[@]}" -eq 0 ]; then
      echo "**No tickets found in \`$BATCH_DIR\`.** Add them, then either fill in the"
      echo "block below by hand or re-run \`ralph-init.sh $BATCH_DIR --force\`."
    else
      echo "Generated from \`$BATCH_DIR\` in filename order. **Re-order it.** Filename"
      echo "order is a starting point, not a plan — put shared foundations first, put the"
      echo "sweep-everything tickets last, and keep two tickets that fight over the same file"
      echo "adjacent so the conflict is a sequential edit rather than a merge."
      echo
      echo "Anything the loop cannot infer belongs in prose here: a dependency that crosses"
      echo "issue directories, or a ticket that must not run until a human has done something."
    fi
    echo
    echo "<!--"
    echo "The machine-readable order. One repo-relative ticket path per line, in run order."
    echo "ralph-next.sh reads only the lines between the ORDER markers."
    echo "-->"
    echo
    echo "<!-- ORDER:BEGIN -->"
    echo '```'
    for t in "${tickets[@]}"; do echo "$t"; done
    echo '```'
    echo "<!-- ORDER:END -->"
  } > "$BATCH_DIR/order.md"
  echo "   created  $BATCH_DIR/order.md (${#tickets[@]} ticket(s) — re-order it before running)"
  wrote_any=1
  [ "${#tickets[@]}" -gt 0 ] && order_written=1
fi

# --- progress.txt ----------------------------------------------------------
if write_if_absent "$BATCH_DIR/progress.txt"; then
  {
    echo "# $(basename "$BATCH_DIR") — the agent's running notes."
    echo "# One short entry per iteration, appended by the agent. The tail of this file is"
    echo "# attached to every later prompt, so length here is a recurring cost."
    echo
  } > "$BATCH_DIR/progress.txt"
  echo "   created  $BATCH_DIR/progress.txt"
  wrote_any=1
fi

echo

if [ "$order_written" -eq 1 ] && [ "$NO_ORDER" -eq 0 ]; then
  echo
  bash "$RALPH_TOOL_DIR/ralph-order.sh" "$BATCH_DIR"
fi

echo
if [ "$wrote_any" -eq 1 ]; then
  echo "Next:"
  echo "  1. edit $BATCH_DIR/ralph.conf     — at minimum RALPH_CHECK_CMD and RALPH_TEST_CMD"
  echo "  2. review $RALPH_INVOKE order picked in $BATCH_DIR/order.md — it is a first pass, not a guarantee"
  echo "  3. $RALPH_INVOKE dry-run $BATCH_DIR   (free; prints the exact prompt)"
  echo "  4. $RALPH_INVOKE run $BATCH_DIR       (one iteration, then look)"
else
  echo "Nothing to do — this batch is already set up."
fi
