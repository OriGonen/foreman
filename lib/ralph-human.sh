#!/bin/bash
# What a human ticket is, and where it keeps its handoff file. Sourced by ralph-loop.sh after
# ralph-config.sh — never run directly.
#
# A HUMAN TICKET is one only a person can do, marked on its own status line
# ('**Status:** ready-for-human', RALPH_HUMAN_WORD). The loop never gives one to an agent:
# reaching one at the head of the order ends the run (exit 30). This file is the ONE place
# that knows the marker, the fields a human ticket carries and how a followup ticket names it;
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
# Followup tickets
#
# A FOLLOWUP TICKET is an ordinary agent ticket that immediately follows a human ticket and
# names it on a `Checks:` line — a file NAME, not a path. It verifies the human's handoff file
# before any agent work builds on it and, if the handoff falls short, sends the human ticket
# back.
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

# Every ticket in the batch (done or not) whose `Checks:` line resolves to TICKET, one per
# line, in batch order. The one place that answers "who checks this ticket" — used both by
# the rename rule (which only cares about not-done ones) and by the warnings (which do not).
_ralph_checkers_of() {    # _ralph_checkers_of TICKET < all-tickets
  local ticket="$1" all candidate name
  all="$(cat)"
  while IFS= read -r candidate; do
    [ -f "$candidate" ] || continue
    name="$(ralph_ticket_field "$candidate" Checks)"
    [ -n "$name" ] || continue
    [ "$(printf '%s\n' "$all" | _ralph_match_ticket "$name")" = "$ticket" ] && printf '%s\n' "$candidate"
  done <<< "$all"
}

# A NOT-done ticket whose `Checks:` line names TICKET, if there is one — the rename rule asks
# whether anything is still waiting to verify TICKET.
ralph_pending_checker() {    # ralph_pending_checker TICKET
  local ticket="$1" candidate
  while IFS= read -r candidate; do
    grep -q "$RALPH_DONE_PATTERN" "$candidate" && continue
    printf '%s' "$candidate"
    return 0
  done < <(_ralph_batch_tickets | _ralph_checkers_of "$ticket")
  return 1
}

# The followup ticket named by TICKET's LAST `## Sent back by …` heading, if any. Last, because a
# ticket sent back twice should point at the latest reason.
ralph_was_sent_back() {    # ralph_was_sent_back TICKET
  grep '^## Sent back by ' "$1" 2>/dev/null | tail -n 1 | tr -d '\r' |
    sed -e 's/^## Sent back by //' -e 's/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# Warnings
#
# A batch whose human and followup tickets are missing a piece — no checker, no handoff file, a
# followup ticket out of place, a `Checks:` line that resolves to nothing. `ralph status`,
# `ralph dry-run` and `ralph order` all print the same list, last, after everything else. They
# never change an exit code and never stop a run: this is a check, not policy.
# ---------------------------------------------------------------------------

# One `warning: …` line per issue found, in the order `ralph-next.sh --all` lists the tickets.
# Prints nothing when there is nothing to warn about. Always returns 0.
ralph_human_warnings() {
  local tickets ticket is_done checker name target prev_ticket=""
  tickets="$(_ralph_batch_tickets)"
  [ -n "$tickets" ] || return 0

  while IFS= read -r ticket; do
    [ -n "$ticket" ] || continue
    is_done=0
    grep -q "$RALPH_DONE_PATTERN" "$ticket" 2>/dev/null && is_done=1

    # 1 & 2: a not-done human ticket with no checker, or no usable handoff file. Skipped
    # entirely when the human word is off — nothing is ever "human" then.
    if [ "$is_done" -eq 0 ] && [ -n "$RALPH_HUMAN_PATTERN" ] && ralph_ticket_needs_human "$ticket"; then
      checker="$(printf '%s\n' "$tickets" | _ralph_checkers_of "$ticket" | head -n 1)"
      [ -n "$checker" ] || printf 'warning: %s is a human ticket with no ticket that Checks: it\n' "$ticket"
      [ -n "$(ralph_handoff_path "$ticket")" ] || printf 'warning: %s has no Handoff: file\n' "$ticket"
    fi

    # 3 & 4: a not-done followup ticket out of place, or naming nothing in the batch. Keyed on
    # `Checks:` and order only — the checked ticket may already be done.
    if [ "$is_done" -eq 0 ]; then
      name="$(ralph_ticket_field "$ticket" Checks)"
      if [ -n "$name" ]; then
        target="$(printf '%s\n' "$tickets" | _ralph_match_ticket "$name")"
        if [ -z "$target" ]; then
          printf 'warning: %s Checks: %s, which is not a ticket in this batch\n' "$ticket" "$name"
        elif [ "$target" != "$prev_ticket" ]; then
          printf 'warning: %s should come right after %s in order.md\n' "$ticket" "$target"
        fi
      fi
    fi

    prev_ticket="$ticket"
  done <<< "$tickets"
  return 0
}
