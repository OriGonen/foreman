#!/bin/bash
# Scaffolds a ralph batch in a directory that already has tickets.
#
#   bash tools/ralph/ralph-init.sh <batch-dir>
#   bash tools/ralph/ralph-init.sh <batch-dir> --force    overwrite what is already there
#
# Creates, if missing:
#   <batch>/ralph.conf     from ralph.conf.template — every knob, all commented out
#   <batch>/order.md       generated from <batch>/issues/*.md in filename order, with the
#                          machine-readable ORDER block the loop reads
#   <batch>/progress.txt   empty, with a one-line header
#
# It never touches a ticket file, and it never overwrites without --force.
#
# order.md is optional: delete it and the loop falls back to filename order over
# <batch>/issues. It is generated anyway because a batch nearly always ends up needing one
# line moved — a ticket that must go last, or a dependency across two issue directories —
# and editing a generated list beats writing one.
set -uo pipefail

RALPH_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FORCE=0
BATCH_INPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --help|-h) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Usage: $0 <batch-dir> [--force]" >&2; exit 1 ;;
    *) BATCH_INPUT="$1" ;;
  esac
  shift
done

if [ -z "$BATCH_INPUT" ]; then
  echo "Usage: $0 <batch-dir> [--force]" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ralph-init: not inside a git repository" >&2; exit 1; }

mkdir -p "$BATCH_INPUT" || exit 1
BATCH_ABS="$(cd "$BATCH_INPUT" && pwd)"
# Round-tripped through cd+pwd for the same reason as in ralph-config.sh: on Windows
# `git rev-parse` says C:/… and `pwd` says /c/…, and the two never compare equal.
cd "$REPO_ROOT" || exit 1
REPO_ROOT="$(pwd)"

if command -v realpath >/dev/null 2>&1; then
  BATCH_DIR="$(realpath --relative-to="$REPO_ROOT" "$BATCH_ABS" 2>/dev/null)"
  case "${BATCH_DIR:-}" in /*|[A-Za-z]:[/\\]*) BATCH_DIR="" ;; esac
fi
[ -n "${BATCH_DIR:-}" ] || BATCH_DIR="${BATCH_ABS#"$REPO_ROOT"/}"

case "$BATCH_DIR" in
  ''|/*|..|../*)
    echo "ralph-init: the batch directory must be inside $REPO_ROOT" >&2
    exit 1 ;;
esac

wrote_any=0

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
  tickets=()
  if [ -d "$BATCH_DIR/issues" ]; then
    while IFS= read -r file; do
      case "$(basename "$file")" in README.md|spec.md|order.md) continue ;; esac
      tickets+=("$file")
    done < <(find "$BATCH_DIR/issues" -maxdepth 1 -name '*.md' -type f | sort)
  fi

  {
    echo "# $(basename "$BATCH_DIR") — implementation order"
    echo
    echo "\`ralph-loop.sh\` reads the block at the bottom of this file, takes the first ticket"
    echo "whose Status line is not flipped, and runs exactly that one."
    echo
    if [ "${#tickets[@]}" -eq 0 ]; then
      echo "**No tickets found under \`$BATCH_DIR/issues/\`.** Add them, then either fill in the"
      echo "block below by hand or re-run \`ralph-init.sh $BATCH_DIR --force\`."
    else
      echo "Generated from \`$BATCH_DIR/issues/\` in filename order. **Re-order it.** Filename"
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
if [ "$wrote_any" -eq 1 ]; then
  echo "Next:"
  echo "  1. edit $BATCH_DIR/ralph.conf     — at minimum RALPH_CHECK_CMD and RALPH_TEST_CMD"
  echo "  2. re-order $BATCH_DIR/order.md"
  echo "  3. bash tools/ralph/ralph-loop.sh $BATCH_DIR --dry-run   (free; prints the exact prompt)"
  echo "  4. bash tools/ralph/ralph-loop.sh $BATCH_DIR 1           (one iteration, then look)"
else
  echo "Nothing to do — this batch is already set up."
fi
