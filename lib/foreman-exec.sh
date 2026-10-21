#!/bin/bash
# The seam between the loop and wherever the agent actually runs.
# Sourced by foreman-loop.sh, foreman-prompt.sh, foreman-config.sh and foreman-doctor.sh —
# never run directly.
#
# FOREMAN_EXEC names an adapter file in lib/exec/. ADDING AN EXECUTION MODE IS ADDING A
# FILE THERE: nothing else in the toolkit holds a list of the modes that exist, and
# nothing else asks which mode is in force. Before this file, that question was asked at
# eleven points across four scripts, in three different spellings.
#
# Every adapter defines exactly these functions. Callers use nothing else. Adapters read
# only FOREMAN_* variables (foreman-config.sh's outputs) and REPO_ROOT — never a caller's
# locals, so an adapter can be loaded and asked a question without the loop present.
#
#   exec_required_tool      the command that must be on PATH, or nothing
#   exec_default_permission_mode  the --permission-mode to use when the user named none
#   exec_preflight          cheap checks; 0 ready, 1 stop. Warns for itself.
#   exec_prepare            expensive setup, once per run, before any money is spent
#   exec_describe           one line naming the arrangement, for status and dry-run
#   exec_commit_note        the prompt's paragraph about committing
#   exec_tree_dirty [TARGET] is the agent's tree dirty right now? 0 no, 1 yes. Read-only —
#                           unlike exec_collect, it never moves commits. Given TARGET, a
#                           file TARGET's .gitignore ignores does not count (only the
#                           clone can be behind on that; the others ignore TARGET).
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
# The adapters that really invoke `claude` also splice in FOREMAN_EXEC_FORMAT_ARGS (below).
# That is the ONLY thing that differs between a plain run and a watched one: there is one
# exec_run per adapter, never a second code path per mode.

# Beside this file, from the shell and not `dirname` (see foreman-config.sh).
FOREMAN_EXEC_DIR="${BASH_SOURCE[0]%/*}"; [ "$FOREMAN_EXEC_DIR" != "${BASH_SOURCE[0]}" ] || FOREMAN_EXEC_DIR=.
FOREMAN_EXEC_DIR="$(cd "${FOREMAN_EXEC_DIR:-/}/exec" 2>/dev/null && pwd)"

# The adapters' preflight lines use warn_preflight, so anything that loads an adapter needs
# the output helpers (guarded: foreman-loop.sh sources the same file).
# shellcheck source=foreman-ui.sh
source "$FOREMAN_EXEC_DIR/../foreman-ui.sh" || return 1

# The adapters print through these. foreman-loop.sh defines its own first; anything else
# sourcing an adapter (foreman-prompt.sh, foreman-doctor.sh) gets these.
if ! declare -F say >/dev/null 2>&1; then
  say() { printf '%s\n' "$*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { printf '%s\n' "$*" >&2; }
fi

# Every mode that exists, one per line.
foreman_exec_modes() {
  local file name
  for file in "$FOREMAN_EXEC_DIR"/*.sh; do
    [ -e "$file" ] || continue
    name="${file##*/}"
    name="${name%.sh}"
    case "$name" in _*) continue ;; esac
    printf '%s\n' "$name"
  done
}

foreman_exec_is_mode() {
  [ -n "${1:-}" ] || return 1
  case "$1" in _*|*/*) return 1 ;; esac
  [ -f "$FOREMAN_EXEC_DIR/$1.sh" ]
}

# Load the adapter for $1 (default: $FOREMAN_EXEC). Returns 1 and warns if there is none.
foreman_exec_load() {
  local mode="${1:-${FOREMAN_EXEC:-}}"
  if ! foreman_exec_is_mode "$mode"; then
    warn "foreman: FOREMAN_EXEC must be one of: $(foreman_exec_modes | tr '\n' ' ')(got '${mode:-}')"
    return 1
  fi
  # shellcheck source=/dev/null
  source "$FOREMAN_EXEC_DIR/$mode.sh" || {
    warn "foreman: cannot load the '$mode' exec adapter"
    return 1
  }
}

# Which command a mode needs on PATH, without disturbing the caller's own adapter. This
# is how `foreman doctor` asks about a batch it is not running: it has several batches, each
# possibly in a different mode, and no foreman-config.sh loaded.
foreman_exec_required_tool() {
  ( foreman_exec_load "$1" >/dev/null 2>&1 && exec_required_tool ) || return 1
}

# Which --permission-mode a mode wants when the user has not chosen one. Same subshell
# pattern as foreman_exec_required_tool, and for the same reason: foreman-config.sh has to ask
# this before it has loaded an adapter, and must not acquire one by asking.
#
# The answer differs because the thing a permission gate protects differs. Inside a sandbox
# the container IS the boundary, so the gate buys nothing — and it costs a paid iteration
# every time it fires, because `claude --print` has nobody to approve a denied Bash call and
# denies it outright. On a machine with real repositories on it that is not true, so `local`
# keeps its gate: "no isolation" and "no permission check at all" are different things.
foreman_exec_default_permission_mode() {
  ( foreman_exec_load "$1" >/dev/null 2>&1 && exec_default_permission_mode ) || return 1
}

# The dirty-tree recovery note for mode $1, without running it — same subshell pattern, so
# each adapter's wording can be asserted directly rather than only by triggering a real
# stall under that mode.
foreman_exec_dirty_recovery_note() {
  local mode="$1"; shift
  ( foreman_exec_load "$mode" >/dev/null 2>&1 && exec_dirty_recovery_note "$@" ) || return 1
}

# How the agent is asked to report, into FOREMAN_EXEC_FORMAT_ARGS for an adapter to splice in.
#
# `json` normally: one object, printed when the turn ends. `stream-json` when the run is
# being watched, so foreman-stream.cjs has events to draw as they happen. --verbose is not
# optional there — `claude --print --output-format=stream-json` refuses to start without it,
# and says so. FOREMAN_LIVE_KEY=1 (set by foreman-loop.sh when the L key is live) asks for
# stream-json too: the view may be turned on mid-iteration, and by then it is too late to ask.
foreman_exec_format_args() {
  if [ "${FOREMAN_STREAM:-0}" = "1" ] || [ "${FOREMAN_LIVE_KEY:-0}" = "1" ]; then
    FOREMAN_EXEC_FORMAT_ARGS=(--output-format stream-json --verbose)
  else
    FOREMAN_EXEC_FORMAT_ARGS=(--output-format json)
  fi
}

# The environment the agent's `claude` runs with, as a NAME=value word for an adapter to put
# after `env`. `env` rather than an exported variable because under the sbx adapters the
# claude process is inside the container, where nothing exported here reaches.
#
# BASH_MAX_TIMEOUT_MS lifts the Bash tool's own 10-minute cap on one call to
# FOREMAN_COMMAND_TIMEOUT_MINUTES, so a check that outgrows ten minutes can still run in the
# foreground — the only place a one-shot turn ever sees its result. It only raises the
# ceiling; the agent still asks for a long timeout per call, as the prompt tells it to.
foreman_exec_agent_env() {
  printf 'BASH_MAX_TIMEOUT_MS=%s\n' "$(( ${FOREMAN_COMMAND_TIMEOUT_MINUTES:-60} * 60000 ))"
}
