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

# This file's directory, from the shell and not `dirname` (see ralph-config.sh).
RALPH_TOOL_DIR="${BASH_SOURCE[0]%/*}"; [ "$RALPH_TOOL_DIR" != "${BASH_SOURCE[0]}" ] || RALPH_TOOL_DIR=.
RALPH_TOOL_DIR="$(cd "${RALPH_TOOL_DIR:-/}" && pwd)"

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
# The ticket list and the answers to `next`, `--list`, `--count`, `--all` and `--unordered`
# are functions in ralph-tickets.sh, so the loop asks them in-process instead of starting this
# script once per question. This file is only the command line in front of them.
# shellcheck source=ralph-tickets.sh
source "$RALPH_TOOL_DIR/ralph-tickets.sh" || exit 2

ralph_next_answer "$MODE"
exit $?
