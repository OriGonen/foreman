#!/bin/bash
# The run order for one batch, resolved against what has actually landed.
#
#   foreman next <batch>            print the next ticket's path; exit 1 if all are done
#   foreman next <batch> --list     print every remaining ticket, in order
#   foreman next <batch> --count    print "<done> <total>"
#   foreman next <batch> --all      print every ticket in order, done or not
#   foreman next <batch> --unordered  print every ticket the batch HAS, ignoring order.md
#
# `--unordered` is the question `foreman init` and `foreman order` ask: what tickets are in
# this batch, before anyone has decided a run order for them. It is the only mode that
# skips the order file, and the only one for which an empty answer is not an error — a
# batch with no tickets yet is exactly what `foreman init` is there to scaffold.
#
# "Next" is the first ticket in the order whose file does not match the batch's
# FOREMAN_DONE_PATTERN (by default a '**Status:** implemented' line). That includes a human
# ticket (foreman-human.sh): "next" says which ticket comes first, and the loop decides what
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
#   2. otherwise, every *.md under FOREMAN_ISSUES_DIRS, sorted by filename. Numeric
#      prefixes (01-, 02-, …) are what make that meaningful.
#
# THE SHOW. `--all` and `--count` are for people as much as for scripts, so at a terminal wide
# enough for it (see THE SHOW in foreman-ui.sh) they are drawn, with foreman-draw.cjs, as the stake
# row and its list, or as one line; everywhere else they print what they always did. `next`,
# `--list` and `--unordered` are only ever read by scripts, and print bare paths on every stream.
# Nothing of this is in foreman_next_answer (foreman-tickets.sh), which the loop asks in-process:
# a picture drawn there would be drawn into the loop's pipes. Asking whether to draw starts no
# process on a plain run.
#
# Exit codes: 0 fine · 1 nothing left to do (in `next` mode) · 2 the batch is malformed.
set -uo pipefail

# This file's directory, from the shell and not `dirname` (see foreman-config.sh).
FOREMAN_TOOL_DIR="${BASH_SOURCE[0]%/*}"; [ "$FOREMAN_TOOL_DIR" != "${BASH_SOURCE[0]}" ] || FOREMAN_TOOL_DIR=.
FOREMAN_TOOL_DIR="$(cd "${FOREMAN_TOOL_DIR:-/}" && pwd)"

MODE=next
case "${1:-}" in
  --*) MODE="$1" ;;
  '')  ;;
  *)   export FOREMAN_BATCH="$1"; shift; MODE="${1:---next}" ;;
esac
[ "$MODE" = "--next" ] && MODE=next
[ "$MODE" = "next" ] || case "$MODE" in
  --list|--count|--all|--unordered) ;;
  *) echo "foreman-next.sh: unknown mode '$MODE' (expected --list, --count, --all, --unordered, or nothing)" >&2; exit 2 ;;
esac

# shellcheck source=foreman-config.sh
source "$FOREMAN_TOOL_DIR/foreman-config.sh" || exit 2
# The ticket list and the answers to `next`, `--list`, `--count`, `--all` and `--unordered`
# are functions in foreman-tickets.sh, so the loop asks them in-process instead of starting this
# script once per question. This file is only the command line in front of them.
# shellcheck source=foreman-tickets.sh
source "$FOREMAN_TOOL_DIR/foreman-tickets.sh" || exit 2

# The renderer's own minimum width for the scenes is this number, here so a narrow terminal starts no
# node; a smoke case holds the two together.
_next_min_cols=40

# The facts for the renderer (scene `next`: a `ticket` line for each, in order, as `foreman status`
# gives them; scene `next-count`: `done` and `total`). Needs nothing held, and prints nothing and fails
# if the batch cannot be read, so the plain answer says why.
_next_facts() {    # _next_facts --all|--count
  local ticket base state human seen_next=0 done_count=0
  _foreman_tickets_get ordered || return 1
  for ticket in "${_FOREMAN_TICKETS[@]}"; do
    foreman_ticket_status "$ticket"
    human=""
    if [ "$_FOREMAN_TICKET_DONE" = 1 ]; then
      state=done; done_count=$((done_count + 1))
    else
      state=todo
      if [ "$seen_next" = 0 ]; then state=next; seen_next=1; fi
      [ "$_FOREMAN_TICKET_HUMAN" != 1 ] || human=human
    fi
    [ "$1" = --all ] || continue
    base="${ticket##*/}"
    [ -z "$FOREMAN_DONE_PREFIX" ] || base="${base#"$FOREMAN_DONE_PREFIX"}"
    printf 'ticket\t%s\t%s\t%s\t%s\n' "$state" "$base" "$human" "$_FOREMAN_TICKET_CHECKS"
  done
  [ "$1" != --count ] || printf 'done\t%s\ntotal\t%s\n' "$done_count" "${#_FOREMAN_TICKETS[@]}"
}

# Draws the picture, all or nothing: what the renderer prints before it fails is not printed, so the
# plain answer that follows is never preceded by half a picture. Fails when it cannot be drawn.
_next_picture() {    # _next_picture --all|--count
  local facts out code scene=next
  [ "$1" != --count ] || scene=next-count
  facts="$(_next_facts "$1" 2>/dev/null)" || return 1
  out="$(node "$FOREMAN_TOOL_DIR/foreman-draw.cjs" "$scene" --tier "$NEXT_TIER" --cols "$NEXT_COLS" <<< "$facts" 2>/dev/null; printf 'x%s' "$?")"
  code="${out##*x}"
  [ "$code" = 0 ] || return 1
  out="${out%x*}"
  printf '%s' "$out"
}

case "$MODE" in
  --all|--count)
    if ui_show 1 NEXT_TIER && ui_cols NEXT_COLS 1 && [ "$NEXT_COLS" -ge "$_next_min_cols" ] && _next_picture "$MODE"; then
      exit 0
    fi
    ;;
esac

foreman_next_answer "$MODE"
exit $?
