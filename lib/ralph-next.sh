#!/bin/bash
# The run order for one batch, resolved against what has actually landed.
#
#   ralph next <batch>            print the next ticket's path; exit 1 if all are done
#   ralph next <batch> --list     print every remaining ticket, in order
#   ralph next <batch> --count    print "<done> <total>"
#   ralph next <batch> --all      print every ticket in order, done or not
#   ralph next <batch> --unordered  print every ticket the batch HAS, ignoring order.md
#
# `--unordered` is the question `ralph init` and `ralph order` ask: what tickets are in
# this batch, before anyone has decided a run order for them. It is the only mode that
# skips the order file, and the only one for which an empty answer is not an error — a
# batch with no tickets yet is exactly what `ralph init` is there to scaffold.
#
# "Next" is the first ticket in the order whose file does not match the batch's
# RALPH_DONE_PATTERN (by default a '**Status:** implemented' line). That includes a human
# ticket (ralph-human.sh): "next" says which ticket comes first, and the loop decides what
# it means for that ticket to be one only a person can do.
#
# THE TICKET STATUS LINES ARE THE ONLY RESUME STATE. There is deliberately no state file:
# an iteration commits its ticket's flipped Status line together with its code, so the
# last commit and the resume point can never disagree. Stop the loop however you like —
# budget, Ctrl-C, a crash, closing the laptop — and the next run picks up at the first
# ticket that has not landed. Nothing to reconcile, nothing to clean up.
#
# WHERE THE ORDER COMES FROM
#   1. <batch>/order.md, if it exists — the lines between <!-- ORDER:BEGIN --> and
#      <!-- ORDER:END -->, one ticket path per line. This is the only way to express an
#      order that filenames cannot: cross-directory sequencing, or a deliberate "do this
#      one last".
#   2. otherwise, every *.md under RALPH_ISSUES_DIRS, sorted by filename. Numeric
#      prefixes (01-, 02-, …) are what make that meaningful.
#
# Exit codes: 0 fine · 1 nothing left to do (in `next` mode) · 2 the batch is malformed.
set -uo pipefail

RALPH_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=next
case "${1:-}" in
  --*) MODE="$1" ;;
  '')  ;;
  *)   export RALPH_BATCH="$1"; shift; MODE="${1:---next}" ;;
esac
[ "$MODE" = "--next" ] && MODE=next
[ "$MODE" = "next" ] || case "$MODE" in
  --list|--count|--all|--unordered) ;;
  *) echo "ralph-next.sh: unknown mode '$MODE' (expected --list, --count, --all, --unordered, or nothing)" >&2; exit 2 ;;
esac

# shellcheck source=ralph-config.sh
source "$RALPH_TOOL_DIR/ralph-config.sh" || exit 2

# ---------------------------------------------------------------------------
# Collect the ticket list
# ---------------------------------------------------------------------------
tickets=()

# An order entry may be written repo-relative (".scratch/b/issues/01.md") or relative to
# the batch ("issues/01.md"). Accept both; complain about neither-resolves.
resolve_ticket() {
  local entry="$1"
  if [ -f "$entry" ]; then printf '%s' "$entry"; return 0; fi
  if [ -f "$BATCH_DIR/$entry" ]; then printf '%s' "$BATCH_DIR/$entry"; return 0; fi
  # Not there under that name: the loop may have renamed it to DONE_<name> since the order
  # was written (RALPH_DONE_PREFIX), so a finished ticket stays findable.
  if [ -n "$RALPH_DONE_PREFIX" ]; then
    local dir base
    dir="$(dirname "$entry")"; base="$(basename "$entry")"
    if [ -f "$dir/$RALPH_DONE_PREFIX$base" ]; then printf '%s' "$dir/$RALPH_DONE_PREFIX$base"; return 0; fi
    if [ -f "$BATCH_DIR/$dir/$RALPH_DONE_PREFIX$base" ]; then
      printf '%s' "$BATCH_DIR/$dir/$RALPH_DONE_PREFIX$base"; return 0
    fi
  fi
  return 1
}

if [ "$MODE" != "--unordered" ] && [ -f "$ORDER_FILE" ]; then
  saw_markers=0
  in_block=0
  while IFS= read -r line || [ -n "$line" ]; do
    # Strip CR: a repo with `* text=auto` checks order.md out with CRLF on Windows.
    line="${line%$'\r'}"
    case "$line" in
      '<!-- ORDER:BEGIN -->'*) in_block=1; saw_markers=1; continue ;;
      '<!-- ORDER:END -->'*)   in_block=0; continue ;;
    esac
    [ "$in_block" = 1 ] || continue

    entry="${line#"${line%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ -n "$entry" ] || continue                 # blank lines inside the block
    [ "${entry:0:3}" = '```' ] && continue      # the code fence around it
    [ "${entry:0:1}" = '#' ] && continue        # a commented-out ticket

    if ! resolved=$(resolve_ticket "$entry"); then
      echo "ralph-next.sh: $ORDER_FILE lists a ticket that does not exist: $entry" >&2
      exit 2
    fi
    tickets+=("$resolved")
  done < "$ORDER_FILE"

  if [ "$saw_markers" -eq 0 ]; then
    echo "ralph-next.sh: $ORDER_FILE has no <!-- ORDER:BEGIN --> / <!-- ORDER:END --> block." >&2
    echo "               Add one (see $RALPH_HOME/README.md), or delete the file to fall" >&2
    echo "               back to filename order over: $RALPH_ISSUES_DIRS" >&2
    exit 2
  fi
else
  # No order file (or `--unordered`, which ignores it): filename order across the issues
  # directories, which is why tickets are numbered. `sort` is applied per directory so the
  # directories stay in the order given. ralph_issues_dirs (ralph-config.sh) is the one
  # place that decides what a RALPH_ISSUES_DIRS entry resolves to, so this and `ralph order`
  # cannot disagree.
  #
  # Sorted on the name WITHOUT the done prefix, so a renamed ticket keeps its place in the
  # numbering instead of sinking below every unrenamed one.
  while IFS= read -r resolved_dir; do
    [ -d "$resolved_dir" ] || continue
    while IFS= read -r file; do
      base="$(basename "$file")"
      skip=0
      for excluded in $RALPH_ISSUES_EXCLUDE; do
        [ "$base" = "$excluded" ] && skip=1 && break
      done
      [ "$skip" -eq 1 ] || tickets+=("$file")
    done < <(find "$resolved_dir" -maxdepth 1 -name '*.md' -type f |
             while IFS= read -r f; do
               key="$(basename "$f")"
               [ -z "$RALPH_DONE_PREFIX" ] || key="${key#"$RALPH_DONE_PREFIX"}"
               printf '%s\t%s\n' "$key" "$f"
             done | sort -t $'\t' -k1,1 | cut -f2-)
  done < <(ralph_issues_dirs)
fi

if [ "${#tickets[@]}" -eq 0 ]; then
  # An empty batch is a legitimate answer to "what tickets are here", and the only answer
  # `ralph init` can get before any have been written.
  [ "$MODE" = "--unordered" ] && exit 0
  if [ "$MODE" != "--unordered" ] && [ -f "$ORDER_FILE" ]; then
    echo "ralph-next.sh: the ORDER block in $ORDER_FILE is empty" >&2
    ralph_issues_hint >&2
  else
    echo "ralph-next.sh: no tickets found." >&2
    echo "               There is no order file at $ORDER_FILE, and no *.md under: $RALPH_ISSUES_DIRS" >&2
    ralph_issues_hint >&2
  fi
  exit 2
fi

# ---------------------------------------------------------------------------
# Split into done and remaining
# ---------------------------------------------------------------------------
remaining=()
done_count=0
for ticket in "${tickets[@]}"; do
  if grep -q "$RALPH_DONE_PATTERN" "$ticket"; then
    done_count=$((done_count + 1))
  else
    remaining+=("$ticket")
  fi
done

case "$MODE" in
  --count) printf '%s %s\n' "$done_count" "${#tickets[@]}" ;;
  --all|--unordered) printf '%s\n' "${tickets[@]}" ;;
  --list)  [ "${#remaining[@]}" -eq 0 ] || printf '%s\n' "${remaining[@]}" ;;
  next)
    [ "${#remaining[@]}" -eq 0 ] && exit 1
    printf '%s\n' "${remaining[0]}"
    ;;
esac

exit 0
