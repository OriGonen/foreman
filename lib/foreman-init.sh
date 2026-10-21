#!/bin/bash
# Scaffolds a foreman batch in a directory that already has tickets.
#
#   foreman init <batch-dir>
#   foreman init <batch-dir> --force      overwrite what is already there
#   foreman init <batch-dir> --no-order   skip the automatic ordering pass
#
# <batch-dir> is a directory in the CURRENT repository. The toolkit itself lives elsewhere
# and nothing is copied into your repo except this batch's three files.
#
# Creates, if missing:
#   <batch>/foreman.conf     from foreman.conf.template — every knob, all commented out
#   <batch>/order.md       generated from <batch>/issues/*.md in filename order, with the
#                          machine-readable ORDER block the loop reads
#   <batch>/progress.txt   empty, with a one-line header
#
# It never touches a ticket file, and it never overwrites without --force.
#
# order.md is then handed to an agent — see foreman-order.sh — which rewrites the run order
# and the reasoning above it, weighing dependencies between tickets, which look foundational
# or important, and each ticket's apparent load. That costs one model call; skip it with
# --no-order and order.md is left in plain filename order, same as before that step existed.
# Either way, order.md is optional: delete it and the loop falls back to filename order over
# <batch>/issues.
set -uo pipefail

# This file's directory, from the shell and not `dirname` (see foreman-config.sh).
FOREMAN_TOOL_DIR="${BASH_SOURCE[0]%/*}"; [ "$FOREMAN_TOOL_DIR" != "${BASH_SOURCE[0]}" ] || FOREMAN_TOOL_DIR=.
FOREMAN_TOOL_DIR="$(cd "${FOREMAN_TOOL_DIR:-/}" && pwd)"

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

# shellcheck source=foreman-repo.sh
source "$FOREMAN_TOOL_DIR/foreman-repo.sh" || {
  echo "foreman-init: cannot load $FOREMAN_TOOL_DIR/foreman-repo.sh" >&2; exit 1; }

foreman_repo_root REPO_ROOT || {
  echo "foreman-init: not inside a git repository" >&2; exit 1; }

# The batch has to exist before git can tell us where it is, and creating it is this
# script's job anyway.
mkdir -p "$BATCH_INPUT" || exit 1

foreman_batch_relpath BATCH_DIR "$BATCH_INPUT" "$REPO_ROOT"
case "$?" in
  1) echo "foreman-init: $BATCH_INPUT is not a directory" >&2; exit 1 ;;
  2) echo "foreman-init: the batch directory must be inside $REPO_ROOT" >&2; exit 1 ;;
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

# --- foreman.conf ------------------------------------------------------------
# legacy: a batch from before the rename keeps its ralph.conf rather than getting a second,
# empty conf beside it that would shadow every setting in the old one.
if [ -f "$BATCH_DIR/ralph.conf" ] && [ ! -e "$BATCH_DIR/foreman.conf" ]; then
  echo "   kept     $BATCH_DIR/ralph.conf (from before the rename to Foreman)"
  echo "            rename it:  git mv \"$BATCH_DIR/ralph.conf\" \"$BATCH_DIR/foreman.conf\""
elif write_if_absent "$BATCH_DIR/foreman.conf"; then
  cp "$FOREMAN_TOOL_DIR/foreman.conf.template" "$BATCH_DIR/foreman.conf" || exit 1
  echo "   created  $BATCH_DIR/foreman.conf"
  wrote_any=1
fi

_foreman_basename init_batch_name "$BATCH_DIR"

# --- order.md --------------------------------------------------------------
if write_if_absent "$BATCH_DIR/order.md"; then
  # What tickets this batch has is foreman-next.sh's question, not this file's: it is the
  # one place that knows about FOREMAN_ISSUES_DIRS and FOREMAN_ISSUES_EXCLUDE, so a batch
  # whose foreman.conf points somewhere other than `issues/` is scaffolded from the right
  # directory. `--unordered` is what makes this safe under --force, too: it never reads
  # the order.md we are about to overwrite.
  tickets=()
  while IFS= read -r file; do
    [ -n "$file" ] && tickets+=("$file")
  done < <(bash "$FOREMAN_TOOL_DIR/foreman-next.sh" "$BATCH_DIR" --unordered)

  {
    echo "# $init_batch_name — implementation order"
    echo
    echo "\`foreman-loop.sh\` reads the block at the bottom of this file, takes the first ticket"
    echo "whose Status line is not flipped, and runs exactly that one."
    echo
    if [ "${#tickets[@]}" -eq 0 ]; then
      echo "**No tickets found in \`$BATCH_DIR\`.** Add them, then either fill in the"
      echo "block below by hand or re-run \`foreman-init.sh $BATCH_DIR --force\`."
    else
      echo "Generated from \`$BATCH_DIR\` in filename order. **Re-order it.** Filename"
      echo "order is a starting point, not a plan — put shared foundations first, put the"
      echo "sweep-everything tickets last, and keep two tickets that fight over the same file"
      echo "adjacent so the conflict is a sequential edit rather than a merge."
      echo
      echo "Anything the loop cannot infer belongs in prose here: a dependency that crosses"
      echo "issue directories. A step only a person can do belongs in its own ticket instead —"
      echo "give it \`**Status:** ready-for-human\`, a \`**Handoff:**\` file, and a followup"
      echo "ticket that \`Checks:\` it; \`foreman order\` places them, and the loop stops there."
    fi
    echo
    echo "<!--"
    echo "The machine-readable order. One repo-relative ticket path per line, in run order."
    echo "foreman-next.sh reads only the lines between the ORDER markers."
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
    echo "# $init_batch_name — the agent's running notes."
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
  bash "$FOREMAN_TOOL_DIR/foreman-order.sh" "$BATCH_DIR"
fi

echo
if [ "$wrote_any" -eq 1 ]; then
  echo "Next:"
  echo "  1. edit $BATCH_DIR/foreman.conf     — at minimum FOREMAN_CHECK_CMD and FOREMAN_TEST_CMD"
  echo "  2. review $FOREMAN_INVOKE order picked in $BATCH_DIR/order.md — it is a first pass, not a guarantee"
  echo "  3. $FOREMAN_INVOKE dry-run $BATCH_DIR   (free; prints the exact prompt)"
  echo "  4. $FOREMAN_INVOKE run $BATCH_DIR       (one iteration, then look)"
else
  echo "Nothing to do — this batch is already set up."
fi
