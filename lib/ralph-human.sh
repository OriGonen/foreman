#!/bin/bash
# What a human ticket is, and where it keeps its handoff file. Sourced by ralph-loop.sh after
# ralph-config.sh — never run directly.
#
# A HUMAN TICKET is one only a person can do, marked on its own status line
# ('**Status:** ready-for-human', RALPH_HUMAN_WORD). The loop never gives one to an agent:
# reaching one at the head of the order ends the run (exit 30). This file is the ONE place
# that knows the marker, the fields a human ticket carries and how a check ticket names it;
# everything else asks.
#
# Lookup only — each function greps a ticket file, none calls a model, none decides policy.

# Not done, and marked as a human ticket. Done wins: a human ticket its person has set to
# `done` is done, whatever else its file says. An empty pattern (RALPH_HUMAN_WORD= switches
# the feature off) matches nothing — never hand it to grep, where it would match every line.
ralph_ticket_needs_human() {    # ralph_ticket_needs_human TICKET
  [ -n "$RALPH_HUMAN_PATTERN" ] || return 1
  [ -f "$1" ] || return 1
  grep -q "$RALPH_DONE_PATTERN" "$1" && return 1
  grep -q "$RALPH_HUMAN_PATTERN" "$1"
}

# The trimmed value of the first `NAME:` line — anchored at the start, bold optional, so
# '**Handoff:** x' and 'Handoff: x' read alike. Prints nothing when there is none.
ralph_ticket_field() {    # ralph_ticket_field TICKET NAME
  sed -n -e "s/^\\(\\*\\*\\)\\{0,1\\}$2:\\(\\*\\*\\)\\{0,1\\} *//p" "$1" 2>/dev/null |
    head -n 1 | tr -d '\r' | sed -e 's/[[:space:]]*$//'
}

# The `Handoff:` file of TICKET, resolved like an order.md entry: as given if it exists, else
# relative to the batch directory. Prints nothing when the ticket names none, or names a file
# that is not there.
ralph_handoff_path() {    # ralph_handoff_path TICKET
  local given
  given="$(ralph_ticket_field "$1" Handoff)"
  [ -n "$given" ] || return 0
  if [ -f "$given" ]; then printf '%s' "$given"
  elif [ -f "$BATCH_DIR/$given" ]; then printf '%s' "$BATCH_DIR/$given"
  fi
}

# ---------------------------------------------------------------------------
# Check tickets
#
# A CHECK TICKET is an ordinary agent ticket that immediately follows a human ticket and names
# it on a `Checks:` line — a file NAME, not a path. It verifies the human's handoff file before
# any agent work builds on it and, if the handoff falls short, sends the human ticket back.
# ---------------------------------------------------------------------------

# A ticket's file name without the done prefix: what a `Checks:` line names and what
# it is matched on, so the prefix on either side is irrelevant.
_ralph_ticket_key() {    # _ralph_ticket_key PATH_OR_NAME
  local base
  base="$(basename "$1")"
  [ -z "$RALPH_DONE_PREFIX" ] || base="${base#"$RALPH_DONE_PREFIX"}"
  printf '%s' "$base"
}

# The batch's tickets, in order, done or not.
_ralph_batch_tickets() { bash "$RALPH_TOOL_DIR/ralph-next.sh" "$BATCH_DIR" --all 2>/dev/null; }

# The first of the tickets on stdin whose key is NAME's. The one place a `Checks:` name becomes
# a ticket.
_ralph_match_ticket() {    # _ralph_match_ticket NAME < tickets
  local want ticket
  want="$(_ralph_ticket_key "$1")"
  while IFS= read -r ticket; do
    if [ "$(_ralph_ticket_key "$ticket")" = "$want" ]; then printf '%s' "$ticket"; return 0; fi
  done
  return 1
}

# The ticket CHECK_TICKET's `Checks:` line names, as the batch spells its path. Prints nothing
# and succeeds when the ticket has no such line; returns 1 when it has one that names no ticket
# in the batch.
ralph_checked_ticket() {    # ralph_checked_ticket CHECK_TICKET
  local name
  name="$(ralph_ticket_field "$1" Checks)"
  [ -n "$name" ] || return 0
  _ralph_batch_tickets | _ralph_match_ticket "$name"
}

# A NOT-done ticket whose `Checks:` line names TICKET, if there is one — the rename rule asks
# whether anything is still waiting to verify TICKET.
ralph_pending_checker() {    # ralph_pending_checker TICKET
  local ticket="$1" tickets candidate name
  tickets="$(_ralph_batch_tickets)"
  while IFS= read -r candidate; do
    [ -f "$candidate" ] || continue
    grep -q "$RALPH_DONE_PATTERN" "$candidate" && continue
    name="$(ralph_ticket_field "$candidate" Checks)"
    [ -n "$name" ] || continue
    if [ "$(printf '%s\n' "$tickets" | _ralph_match_ticket "$name")" = "$ticket" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done <<< "$tickets"
  return 1
}

# The check ticket named by TICKET's LAST `## Sent back by …` heading, if any. Last, because a
# ticket sent back twice should point at the latest reason.
ralph_was_sent_back() {    # ralph_was_sent_back TICKET
  grep '^## Sent back by ' "$1" 2>/dev/null | tail -n 1 | tr -d '\r' |
    sed -e 's/^## Sent back by //' -e 's/[[:space:]]*$//'
}
