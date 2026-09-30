#!/bin/bash
# The seam between the loop and wherever the agent actually runs.
# Sourced by ralph-loop.sh, ralph-prompt.sh, ralph-config.sh and ralph-doctor.sh —
# never run directly.
#
# RALPH_EXEC names an adapter file in lib/exec/. ADDING AN EXECUTION MODE IS ADDING A
# FILE THERE: nothing else in the toolkit holds a list of the modes that exist, and
# nothing else asks which mode is in force. Before this file, that question was asked at
# eleven points across four scripts, in three different spellings.
#
# Every adapter defines exactly these functions. Callers use nothing else. Adapters read
# only RALPH_* variables (ralph-config.sh's outputs) and REPO_ROOT — never a caller's
# locals, so an adapter can be loaded and asked a question without the loop present.
#
#   exec_required_tool      the command that must be on PATH, or nothing
#   exec_default_permission_mode  the --permission-mode to use when the user named none
#   exec_preflight          cheap checks; 0 ready, 1 stop. Warns for itself.
#   exec_prepare            expensive setup, once per run, before any money is spent
#   exec_cleanup            OPTIONAL. Remove anything exec_prepare left behind; called from
#                           the loop's EXIT trap, so it must be safe to call before
#                           exec_prepare has run, and more than once
#   exec_describe           one line naming the arrangement, for status and dry-run
#   exec_commit_note        the prompt's paragraph about committing
#   exec_tree_dirty         is the agent's tree dirty right now? 0 no, 1 yes. Read-only —
#                           unlike exec_collect, it never moves commits.
#   exec_sync_down BASE     put the agent's tree at BASE; 0 ok, 1 stop
#   exec_run PROMPT TICKET  run the agent; payload on stdout, agent's status returned
#   exec_collect BASE       set EXEC_AGENT_HEAD and EXEC_DIRTY, and bring any commits
#                           back to this repo; 0 ok, 1 the work is stranded
#   exec_show_dirty         say where the uncommitted changes are (stderr)
#   exec_recovery_note BASE how to rescue work exec_collect could not bring back
#   exec_dirty_recovery_note BASE TICKET BATCH
#                           how to rescue work a stop found still uncommitted. Distinct
#                           from exec_recovery_note: that one covers work that WAS
#                           committed but could not be brought back — two different
#                           failures, never printed for one another.
#
# Files in lib/exec/ whose name starts with `_` are shared implementation, not modes.
#
# The adapters that really invoke `claude` also splice in RALPH_EXEC_FORMAT_ARGS (below).
# That is the ONLY thing that differs between a plain run and a watched one: there is one
# exec_run per adapter, never a second code path per mode.

RALPH_EXEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/exec" 2>/dev/null && pwd)"

# The adapters print through these. ralph-loop.sh defines its own first; anything else
# sourcing an adapter (ralph-prompt.sh, ralph-doctor.sh) gets these.
if ! declare -F say >/dev/null 2>&1; then
  say() { printf '%s\n' "$*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf '%s\n' "$*" >&2; }
fi

# Every mode that exists, one per line.
ralph_exec_modes() {
  local file name
  for file in "$RALPH_EXEC_DIR"/*.sh; do
    [ -e "$file" ] || continue
    name="${file##*/}"
    name="${name%.sh}"
    case "$name" in _*) continue ;; esac
    printf '%s\n' "$name"
  done
}

ralph_exec_is_mode() {
  [ -n "${1:-}" ] || return 1
  case "$1" in _*|*/*) return 1 ;; esac
  [ -f "$RALPH_EXEC_DIR/$1.sh" ]
}

# Load the adapter for $1 (default: $RALPH_EXEC). Returns 1 and warns if there is none.
ralph_exec_load() {
  local mode="${1:-${RALPH_EXEC:-}}"
  if ! ralph_exec_is_mode "$mode"; then
    warn "ralph: RALPH_EXEC must be one of: $(ralph_exec_modes | tr '\n' ' ')(got '${mode:-}')"
    return 1
  fi
  # shellcheck source=/dev/null
  source "$RALPH_EXEC_DIR/$mode.sh" || {
    warn "ralph: cannot load the '$mode' exec adapter"
    return 1
  }
}

# Which command a mode needs on PATH, without disturbing the caller's own adapter. This
# is how `ralph doctor` asks about a batch it is not running: it has several batches, each
# possibly in a different mode, and no ralph-config.sh loaded.
ralph_exec_required_tool() {
  ( ralph_exec_load "$1" >/dev/null 2>&1 && exec_required_tool ) || return 1
}

# Which --permission-mode a mode wants when the user has not chosen one. Same subshell
# pattern as ralph_exec_required_tool, and for the same reason: ralph-config.sh has to ask
# this before it has loaded an adapter, and must not acquire one by asking.
#
# The answer differs because the thing a permission gate protects differs. Inside a sandbox
# the container IS the boundary, so the gate buys nothing — and it costs a paid iteration
# every time it fires, because `claude --print` has nobody to approve a denied Bash call and
# denies it outright. On a machine with real repositories on it that is not true, so `local`
# keeps its gate: "no isolation" and "no permission check at all" are different things.
ralph_exec_default_permission_mode() {
  ( ralph_exec_load "$1" >/dev/null 2>&1 && exec_default_permission_mode ) || return 1
}

# The dirty-tree recovery note for mode $1, without running it — same subshell pattern, so
# each adapter's wording can be asserted directly rather than only by triggering a real
# stall under that mode.
ralph_exec_dirty_recovery_note() {
  local mode="$1"; shift
  ( ralph_exec_load "$mode" >/dev/null 2>&1 && exec_dirty_recovery_note "$@" ) || return 1
}

# How the agent is asked to report, into RALPH_EXEC_FORMAT_ARGS for an adapter to splice in.
#
# `json` normally: one object, printed when the turn ends. `stream-json` when the run is
# being watched, so ralph-stream.cjs has events to draw as they happen. --verbose is not
# optional there — `claude --print --output-format=stream-json` refuses to start without it,
# and says so.
ralph_exec_format_args() {
  if [ "${RALPH_STREAM:-0}" = "1" ]; then
    RALPH_EXEC_FORMAT_ARGS=(--output-format stream-json --verbose)
  else
    RALPH_EXEC_FORMAT_ARGS=(--output-format json)
  fi
}
