#!/bin/bash
# What a human ticket is, and where it keeps its handoff file. Sourced by ralph-loop.sh after
# ralph-config.sh — never run directly.
#
# A HUMAN TICKET is one only a person can do, marked on its own status line
# ('**Status:** ready-for-human', RALPH_HUMAN_WORD). The loop never gives one to an agent:
# reaching one at the head of the order ends the run (exit 30). This file is the ONE place
# that knows the marker and the fields a human ticket carries; everything else asks.
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
