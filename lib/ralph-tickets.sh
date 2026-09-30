#!/bin/bash
# The batch's ticket list, and the questions asked of it. Sourced after ralph-config.sh by
# ralph-next.sh (the `ralph next` command), ralph-human.sh and ralph-loop.sh — never run
# directly.
#
# `ralph next` is the one place that says which tickets a batch has, in what order, and which
# of them have landed (see ralph-next.sh for the modes and the order rules). It used to be
# asked by starting `bash ralph-next.sh`, and every start sourced ralph-config.sh from nothing:
# `ralph status` did that seven times. The answer lives here instead, as functions, so a
# command that has already loaded its config asks in-process — and ralph-next.sh is the same
# functions behind a command line.
#
# A SNAPSHOT is what makes "the ticket list is computed once per command" true. A command
# that is only reading — `status`, `dry-run`, the preflight of a run — holds one
# (ralph_tickets_hold) in its OWN shell, not inside a `$( )`, whose changes die with it; every
# question asked afterwards, from a subshell or not, answers from it. A command about to change
# tickets releases it first (ralph_tickets_release) and asks afresh from then on. Without a
# snapshot every question recomputes the list, exactly as a fresh `ralph next` always did, so
# holding one is only ever a saving, never a requirement for a correct answer.
#
# What a snapshot holds is the list of ticket PATHS, and what each ticket's file says about
# its status (below), read once when the snapshot is taken. With no snapshot held, a ticket's
# file is read at the time of each question.

_RALPH_TICKETS=()
_RALPH_TICKETS_HELD=0     # 1 while a snapshot of the ordered list is held

# ---------------------------------------------------------------------------
# What a ticket's file says about its status
#
# Three things are asked of a ticket, over and over within one command: is it done (its
# status line matches RALPH_DONE_PATTERN), is it a human ticket (RALPH_HUMAN_PATTERN — what that
# means is ralph-human.sh's to say), and what does its `Checks:` line name. Each is answered by
# ONE pass over the file, in bash: the patterns are matched as EREs derived from the configured
# BREs (ralph-config.sh), and no process is started per question. A pattern that did not
# translate is handed to grep, once, for that pass, so a pattern never reads differently.
#
# ralph_ticket_status TICKET sets the answers in variables rather than printing them, so asking
# costs no subshell either:
#   _RALPH_TICKET_DONE    1 if the ticket has landed
#   _RALPH_TICKET_HUMAN   1 if it is a human ticket — never when it is done: done wins
#   _RALPH_TICKET_CHECKS  the trimmed value of its first `Checks:` line, empty if none
# A file that is not there has landed nothing, is nobody's ticket and checks nothing.
# ---------------------------------------------------------------------------
declare -A _RALPH_TS_DONE=() _RALPH_TS_HUMAN=() _RALPH_TS_CHECKS=()    # the held snapshot's reads
_RALPH_TICKET_DONE=0
_RALPH_TICKET_HUMAN=0
_RALPH_TICKET_CHECKS=""
_RALPH_FIELD_VALUE=""
_RALPH_CHECKS_RE='^(\*\*)?Checks:(\*\*)? *(.*)$'

# Is LINE a `NAME:` line, matched by RE (a regex whose third group is the value)? Sets
# _RALPH_FIELD_VALUE to the value with CRs dropped and trailing whitespace trimmed, so a
# CRLF file and a trailing space read like a clean one.
_ralph_field_of() {    # _ralph_field_of LINE RE
  [[ $1 =~ $2 ]] || return 1
  _RALPH_FIELD_VALUE="${BASH_REMATCH[3]//$'\r'/}"
  _RALPH_FIELD_VALUE="${_RALPH_FIELD_VALUE%"${_RALPH_FIELD_VALUE##*[![:space:]]}"}"
}

# Read FILE once and set the three answers, whatever is held.
_ralph_ticket_read() {    # _ralph_ticket_read FILE
  local file="$1" line human=0 have_checks=0
  _RALPH_TICKET_DONE=0
  _RALPH_TICKET_HUMAN=0
  _RALPH_TICKET_CHECKS=""
  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$_RALPH_TICKET_DONE" = 0 ] && [ -n "$_RALPH_DONE_ERE" ] && [[ $line =~ $_RALPH_DONE_ERE ]]; then
      _RALPH_TICKET_DONE=1
    fi
    # The empty-pattern rule: no human ERE, whether the feature is off (empty pattern) or the
    # pattern did not translate (grep's turn, below), never reaches the match — bash, like
    # grep, would match every line against an empty pattern.
    if [ "$human" = 0 ] && [ -n "$_RALPH_HUMAN_ERE" ] && [[ $line =~ $_RALPH_HUMAN_ERE ]]; then
      human=1
    fi
    if [ "$have_checks" = 0 ] && _ralph_field_of "$line" "$_RALPH_CHECKS_RE"; then
      have_checks=1
      _RALPH_TICKET_CHECKS="$_RALPH_FIELD_VALUE"
    fi
  done < "$file"

  [ -n "$_RALPH_DONE_ERE" ] || { grep -q "$RALPH_DONE_PATTERN" "$file" && _RALPH_TICKET_DONE=1; }
  if [ -n "$RALPH_HUMAN_PATTERN" ] && [ -z "$_RALPH_HUMAN_ERE" ]; then
    grep -q "$RALPH_HUMAN_PATTERN" "$file" && human=1
  fi
  [ "$_RALPH_TICKET_DONE" = 1 ] || _RALPH_TICKET_HUMAN=$human
  return 0
}

# Set the three answers for TICKET: from the held snapshot if it has read this ticket, else by
# reading the file now.
ralph_ticket_status() {    # ralph_ticket_status TICKET
  if [ "$_RALPH_TICKETS_HELD" = 1 ] && [ -n "$1" ] && [ -n "${_RALPH_TS_DONE[$1]+set}" ]; then
    _RALPH_TICKET_DONE="${_RALPH_TS_DONE[$1]}"
    _RALPH_TICKET_HUMAN="${_RALPH_TS_HUMAN[$1]}"
    _RALPH_TICKET_CHECKS="${_RALPH_TS_CHECKS[$1]}"
  else
    _ralph_ticket_read "$1"
  fi
}

# Has TICKET landed?
ralph_ticket_is_done() {    # ralph_ticket_is_done TICKET
  ralph_ticket_status "$1"
  [ "$_RALPH_TICKET_DONE" = 1 ]
}

# Read every ticket in _RALPH_TICKETS once, for the snapshot.
_ralph_status_hold() {
  local ticket
  _RALPH_TS_DONE=(); _RALPH_TS_HUMAN=(); _RALPH_TS_CHECKS=()
  for ticket in "${_RALPH_TICKETS[@]}"; do
    _ralph_ticket_read "$ticket"
    _RALPH_TS_DONE[$ticket]="$_RALPH_TICKET_DONE"
    _RALPH_TS_HUMAN[$ticket]="$_RALPH_TICKET_HUMAN"
    _RALPH_TS_CHECKS[$ticket]="$_RALPH_TICKET_CHECKS"
  done
}

# An order entry may be written repo-relative (".scratch/b/issues/01.md") or relative to
# the batch ("issues/01.md"). Accept both; complain about neither-resolves.
_ralph_resolve_ticket() {
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

# Compute the ticket list into _RALPH_TICKETS. KIND is `ordered` (order.md if there is one,
# else filename order) or `unordered` (every ticket the batch HAS, ignoring order.md — the
# question `ralph init` and `ralph order` ask). Returns 2, with the reason on stderr, when the
# batch is malformed; an empty `unordered` list is not an error.
_ralph_tickets_compute() {    # _ralph_tickets_compute KIND
  local kind="$1" line entry resolved resolved_dir file base key excluded skip saw_markers in_block
  _RALPH_TICKETS=()

  if [ "$kind" != unordered ] && [ -f "$ORDER_FILE" ]; then
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

      if ! resolved=$(_ralph_resolve_ticket "$entry"); then
        echo "ralph-next.sh: $ORDER_FILE lists a ticket that does not exist: $entry" >&2
        _RALPH_TICKETS=()
        return 2
      fi
      _RALPH_TICKETS+=("$resolved")
    done < "$ORDER_FILE"

    if [ "$saw_markers" -eq 0 ]; then
      echo "ralph-next.sh: $ORDER_FILE has no <!-- ORDER:BEGIN --> / <!-- ORDER:END --> block." >&2
      echo "               Add one (see $RALPH_HOME/README.md), or delete the file to fall" >&2
      echo "               back to filename order over: $RALPH_ISSUES_DIRS" >&2
      _RALPH_TICKETS=()
      return 2
    fi
  else
    # No order file (or `unordered`, which ignores it): filename order across the issues
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
        [ "$skip" -eq 1 ] || _RALPH_TICKETS+=("$file")
      done < <(find "$resolved_dir" -maxdepth 1 -name '*.md' -type f |
               while IFS= read -r f; do
                 key="$(basename "$f")"
                 [ -z "$RALPH_DONE_PREFIX" ] || key="${key#"$RALPH_DONE_PREFIX"}"
                 printf '%s\t%s\n' "$key" "$f"
               done | sort -t $'\t' -k1,1 | cut -f2-)
    done < <(ralph_issues_dirs)
  fi

  if [ "${#_RALPH_TICKETS[@]}" -eq 0 ]; then
    # An empty batch is a legitimate answer to "what tickets are here", and the only answer
    # `ralph init` can get before any have been written.
    [ "$kind" = unordered ] && return 0
    if [ -f "$ORDER_FILE" ]; then
      echo "ralph-next.sh: the ORDER block in $ORDER_FILE is empty" >&2
      ralph_issues_hint >&2
    else
      echo "ralph-next.sh: no tickets found." >&2
      echo "               There is no order file at $ORDER_FILE, and no *.md under: $RALPH_ISSUES_DIRS" >&2
      ralph_issues_hint >&2
    fi
    return 2
  fi
  return 0
}

# Make _RALPH_TICKETS hold KIND's list: from the snapshot if one is held, else computed now. Only
# the ordered list is ever held, so any other question is computed — and, being computed into
# the same array, ends a snapshot it overwrote.
_ralph_tickets_get() {    # _ralph_tickets_get KIND
  [ "$1" = ordered ] && [ "$_RALPH_TICKETS_HELD" = 1 ] && return 0
  _RALPH_TICKETS_HELD=0
  _ralph_tickets_compute "$1"
}

# Hold a snapshot of the ordered list for every question asked until it is released. Call it in
# the command's own shell. Returns what computing the list returned, so a malformed batch fails
# here once, with its message, and holds nothing.
ralph_tickets_hold() {
  _RALPH_TICKETS_HELD=0
  _ralph_tickets_compute ordered || return $?
  _ralph_status_hold
  _RALPH_TICKETS_HELD=1
}

# Drop the snapshot: from here every question recomputes the list. Before anything that can
# rename, add or reorder a ticket, and at the top of every pass of a loop that does.
ralph_tickets_release() {
  _RALPH_TICKETS_HELD=0
  _RALPH_TICKETS=()
  _RALPH_TS_DONE=(); _RALPH_TS_HUMAN=(); _RALPH_TS_CHECKS=()
}

# Print what `ralph next` prints for MODE, and return what it exits with: 0 fine, 1 nothing
# left (`next` only), 2 the batch is malformed.
ralph_next_answer() {    # ralph_next_answer next|--list|--count|--all|--unordered
  local mode="$1" kind=ordered ticket done_count=0
  local -a remaining=()
  case "$mode" in
    --next) mode=next ;;
    next|--list|--count|--all|--unordered) ;;
    *) echo "ralph-next.sh: unknown mode '$mode' (expected --list, --count, --all, --unordered, or nothing)" >&2
       return 2 ;;
  esac
  [ "$mode" = --unordered ] && kind=unordered

  _ralph_tickets_get "$kind" || return $?
  [ "${#_RALPH_TICKETS[@]}" -gt 0 ] || return 0    # only an empty `unordered` gets here

  # Split into done and remaining. `--all` and `--unordered` are the list as it stands, and
  # need no status reads at all; `next` needs only the first ticket that has not landed.
  case "$mode" in
    --count|--list)
      for ticket in "${_RALPH_TICKETS[@]}"; do
        if ralph_ticket_is_done "$ticket"; then
          done_count=$((done_count + 1))
        else
          remaining+=("$ticket")
        fi
      done
      ;;
    next)
      for ticket in "${_RALPH_TICKETS[@]}"; do
        ralph_ticket_is_done "$ticket" || { remaining=("$ticket"); break; }
      done
      ;;
  esac

  case "$mode" in
    --count) printf '%s %s\n' "$done_count" "${#_RALPH_TICKETS[@]}" ;;
    --all|--unordered) printf '%s\n' "${_RALPH_TICKETS[@]}" ;;
    --list)  [ "${#remaining[@]}" -eq 0 ] || printf '%s\n' "${remaining[@]}" ;;
    next)
      [ "${#remaining[@]}" -eq 0 ] && return 1
      printf '%s\n' "${remaining[0]}"
      ;;
  esac
  return 0
}
