#!/bin/bash
# Resolves one ralph batch into a fully-populated set of RALPH_* variables.
# Sourced by ralph-loop.sh, ralph-next.sh and ralph-report's shell callers — never run.
#
# THE TOOLKIT HOLDS NO STATE. Everything that differs between batches — the order, the
# progress notes, the run logs, the config — lives in the batch directory. This file only
# works out where that directory is and fills in defaults for whatever it did not set.
#
# Precedence, highest first:
#   1. environment variables       RALPH_MAX_COST_USD=25 bash ralph-loop.sh <batch>
#   2. the batch's ralph.conf      <batch>/ralph.conf
#   3. the defaults below
#
# Inputs:  RALPH_BATCH   path to the batch directory (the caller sets this from its
#                        positional argument, or the user exports it). If unset, and
#                        exactly one directory in the repo has a ralph.conf, that one is
#                        used; otherwise this errors with the candidates listed.
#
# Outputs (all repo-relative unless noted, because the agent's working directory is the
# repo root and every path it is handed must resolve there):
#   REPO_ROOT            absolute path to the repository
#   RALPH_TOOL_DIR       absolute path to this toolkit directory
#   BATCH_DIR            repo-relative path to the batch directory
#   BATCH_NAME           its basename, unless ralph.conf overrides it
#   ORDER_FILE PROGRESS_FILE RUN_JSONL RUN_LOG BUNDLE_FILE PROMPT_EXTRA_FILE
#   plus every RALPH_* knob documented in ralph.conf.template

RALPH_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# `git rev-parse --show-toplevel` answers in the platform's own path syntax — on Windows
# that is `C:/Projects/x` while `pwd` says `/c/Projects/x`. Round-tripping it through
# cd+pwd puts both in the same form, without which every path comparison below quietly
# decides the batch is not inside the repo.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ralph: not inside a git repository" >&2
  return 1 2>/dev/null || exit 1
}
cd "$REPO_ROOT" || { echo "ralph: cannot cd to $REPO_ROOT" >&2; return 1 2>/dev/null || exit 1; }
REPO_ROOT="$(pwd)"

# ---------------------------------------------------------------------------
# Which batch?
# ---------------------------------------------------------------------------

# Directories that are never worth searching: dependency trees, git internals, and the
# worktrees Claude Code creates (each of which contains a full copy of every batch).
_ralph_find_batches() {
  find . \
    \( -name node_modules -o -name .git -o -path './.claude/worktrees' -o -name .svelte-kit \) -prune \
    -o -name ralph.conf -print 2>/dev/null |
    sed 's|^\./||; s|/ralph\.conf$||' | sort
}

if [ -z "${RALPH_BATCH:-}" ]; then
  _ralph_candidates=$(_ralph_find_batches)
  _ralph_count=$(printf '%s' "$_ralph_candidates" | grep -c . || true)
  if [ "$_ralph_count" = "1" ]; then
    RALPH_BATCH="$_ralph_candidates"
  elif [ "$_ralph_count" = "0" ]; then
    echo "ralph: no batch given and no ralph.conf found anywhere in $REPO_ROOT." >&2
    echo "       Pass one:      bash ${BASH_SOURCE[1]:-ralph-loop.sh} <batch-dir>" >&2
    echo "       Or create one: bash tools/ralph/ralph-init.sh <batch-dir>" >&2
    return 1 2>/dev/null || exit 1
  else
    echo "ralph: no batch given, and $_ralph_count directories have a ralph.conf:" >&2
    printf '         %s\n' $_ralph_candidates >&2
    echo "       Name the one you mean." >&2
    return 1 2>/dev/null || exit 1
  fi
fi

# Accept an absolute path, a Windows-style path, or a path relative to the repo root or
# to the caller's own directory — and normalise all of them to repo-relative.
_ralph_abs="$(cd "$RALPH_BATCH" 2>/dev/null && pwd)" || {
  echo "ralph: no such directory: $RALPH_BATCH" >&2
  return 1 2>/dev/null || exit 1
}

if command -v realpath >/dev/null 2>&1; then
  BATCH_DIR="$(realpath --relative-to="$REPO_ROOT" "$_ralph_abs" 2>/dev/null)" || BATCH_DIR=""
  # A realpath that could not relate the two paths hands back the absolute one rather
  # than failing. Reject that and fall through to plain prefix stripping.
  case "$BATCH_DIR" in /*|[A-Za-z]:[/\\]*) BATCH_DIR="" ;; esac
fi
if [ -z "${BATCH_DIR:-}" ]; then
  case "$_ralph_abs" in
    "$REPO_ROOT") BATCH_DIR="." ;;
    "$REPO_ROOT"/*) BATCH_DIR="${_ralph_abs#"$REPO_ROOT"/}" ;;
    *) BATCH_DIR="" ;;
  esac
fi

case "$BATCH_DIR" in
  ''|..|../*)
    echo "ralph: the batch directory must be inside the repository." >&2
    echo "       batch: $_ralph_abs" >&2
    echo "       repo:  $REPO_ROOT" >&2
    echo "       The agent runs with the repo root as its working directory, so a batch" >&2
    echo "       outside it has no path the agent could open." >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Load ralph.conf, with the environment winning over it
#
# Every RALPH_* variable that exists right now came from the environment: no ralph script
# sets one before sourcing this file. Snapshot them, source the conf, put them back.
# ---------------------------------------------------------------------------
declare -A _RALPH_FROM_ENV=()
for _ralph_name in $(compgen -v RALPH_ 2>/dev/null); do
  _RALPH_FROM_ENV["$_ralph_name"]="${!_ralph_name}"
done

RALPH_CONF="$BATCH_DIR/ralph.conf"
if [ -f "$RALPH_CONF" ]; then
  # A CRLF checkout would put a trailing \r on the end of every value this file sets —
  # RALPH_EXEC would become "sandbox<CR>" and fail validation with a message that looks
  # like a lie. `.gitattributes` pins ralph.conf to LF, but a file copied in from
  # elsewhere or edited in a CRLF editor would not be covered, so source a stripped copy
  # rather than trust it.
  if grep -qU $'\r' "$RALPH_CONF" 2>/dev/null; then
    _ralph_conf_lf="$(mktemp)"
    tr -d '\r' < "$RALPH_CONF" > "$_ralph_conf_lf"
    # shellcheck source=/dev/null
    source "$_ralph_conf_lf" || { rm -f "$_ralph_conf_lf"; echo "ralph: $RALPH_CONF could not be sourced" >&2; return 1 2>/dev/null || exit 1; }
    rm -f "$_ralph_conf_lf"
    unset _ralph_conf_lf
  else
    # shellcheck source=/dev/null
    source "$RALPH_CONF" || {
      echo "ralph: $RALPH_CONF could not be sourced" >&2
      return 1 2>/dev/null || exit 1
    }
  fi
fi

for _ralph_name in "${!_RALPH_FROM_ENV[@]}"; do
  printf -v "$_ralph_name" '%s' "${_RALPH_FROM_ENV[$_ralph_name]}"
done
unset _RALPH_FROM_ENV _ralph_name _ralph_abs _ralph_candidates _ralph_count

# ---------------------------------------------------------------------------
# Defaults for everything ralph.conf and the environment left unset
# ---------------------------------------------------------------------------
BATCH_NAME="${RALPH_BATCH_NAME:-$(basename "$BATCH_DIR")}"

# --- tickets ---------------------------------------------------------------
# A ticket counts as done when this grep pattern (a BRE) matches a line in its file.
RALPH_DONE_PATTERN="${RALPH_DONE_PATTERN:-^\*\*Status:\*\* *implemented}"
# The word the prompt tells the agent to write. Keep the two in step.
RALPH_DONE_WORD="${RALPH_DONE_WORD:-implemented}"
RALPH_STATUS_LINE="${RALPH_STATUS_LINE:-**Status:**}"

# Every path knob accepts three spellings, so `order.md` in a conf means the batch's own
# order file and `.scratch/shared/order.md` still means what it says:
#   absolute            used as given
#   repo-relative       used as given, if something is already there
#   batch-relative      otherwise — and this is what a bare filename means
_ralph_path() {
  local given="$1" fallback="$2"
  [ -n "$given" ] || { printf '%s/%s' "$BATCH_DIR" "$fallback"; return; }
  case "$given" in
    /*|[A-Za-z]:[/\\]*) printf '%s' "$given"; return ;;
  esac
  if [ -e "$given" ]; then printf '%s' "$given"; else printf '%s/%s' "$BATCH_DIR" "$given"; fi
}

# Where the run order comes from. If the order file is missing, ralph-next.sh falls back
# to every *.md under RALPH_ISSUES_DIRS in filename order.
ORDER_FILE="$(_ralph_path "${RALPH_ORDER_FILE:-}" order.md)"
RALPH_ISSUES_DIRS="${RALPH_ISSUES_DIRS:-issues}"
RALPH_ISSUES_EXCLUDE="${RALPH_ISSUES_EXCLUDE:-README.md spec.md order.md}"

# --- the agent's notes -----------------------------------------------------
PROGRESS_FILE="$(_ralph_path "${RALPH_PROGRESS_FILE:-}" progress.txt)"
RALPH_PROGRESS_TAIL_BYTES="${RALPH_PROGRESS_TAIL_BYTES:-6000}"
PROMPT_EXTRA_FILE="$(_ralph_path "${RALPH_PROMPT_EXTRA:-}" prompt-extra.md)"

# --- telemetry (append-only, never read back by the loop) ------------------
RUN_JSONL="$(_ralph_path "${RALPH_RUN_JSONL:-}" ralph-runs.jsonl)"
RUN_LOG="$(_ralph_path "${RALPH_RUN_LOG:-}" ralph-runs.log)"
BUNDLE_FILE="$(_ralph_path "${RALPH_BUNDLE_FILE:-}" .ralph-iter.bundle)"

# --- how the agent is executed --------------------------------------------
#   sandbox        sbx on a private clone; commits come back as a git bundle  (default)
#   sandbox-mount  sbx bind-mounting this working tree; commits land directly
#   local          `claude` in this working tree; no sandbox at all
RALPH_EXEC="${RALPH_EXEC:-sandbox}"
RALPH_SANDBOX="${RALPH_SANDBOX:-ralph-$(basename "$REPO_ROOT")}"
RALPH_SANDBOX_SETUP="${RALPH_SANDBOX_SETUP:-}"
RALPH_SANDBOX_PROBE="${RALPH_SANDBOX_PROBE:-}"
RALPH_SKIP_SANDBOX_PROBE="${RALPH_SKIP_SANDBOX_PROBE:-0}"

# --- the agent -------------------------------------------------------------
RALPH_MODEL="${RALPH_MODEL:-claude-sonnet-5}"
RALPH_EFFORT="${RALPH_EFFORT:-high}"
RALPH_PERMISSION_MODE="${RALPH_PERMISSION_MODE:-acceptEdits}"
declare -p RALPH_CLAUDE_ARGS >/dev/null 2>&1 || RALPH_CLAUDE_ARGS=()

# --- prompt slots ----------------------------------------------------------
RALPH_CHECK_CMD="${RALPH_CHECK_CMD:-}"
RALPH_TEST_CMD="${RALPH_TEST_CMD:-}"
RALPH_FOCUSED_TEST_CMD="${RALPH_FOCUSED_TEST_CMD:-}"
RALPH_TDD_SKILL="${RALPH_TDD_SKILL:-}"
RALPH_REVIEW_SKILL="${RALPH_REVIEW_SKILL:-}"

# --- budgets ---------------------------------------------------------------
RALPH_MAX_COST_USD="${RALPH_MAX_COST_USD:-0}"
RALPH_MAX_MINUTES="${RALPH_MAX_MINUTES:-0}"
RALPH_TICKET_ATTEMPTS="${RALPH_TICKET_ATTEMPTS:-2}"
RALPH_ALLOW_DIRTY="${RALPH_ALLOW_DIRTY:-0}"

# --- validation ------------------------------------------------------------
case "$RALPH_EXEC" in
  sandbox|sandbox-mount|local) ;;
  *)
    echo "ralph: RALPH_EXEC must be 'sandbox', 'sandbox-mount' or 'local' (got '$RALPH_EXEC')" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

for _ralph_int in RALPH_TICKET_ATTEMPTS RALPH_MAX_MINUTES RALPH_PROGRESS_TAIL_BYTES; do
  if ! [[ "${!_ralph_int}" =~ ^[0-9]+$ ]]; then
    echo "ralph: $_ralph_int must be a whole number (got '${!_ralph_int}')" >&2
    return 1 2>/dev/null || exit 1
  fi
done
unset _ralph_int

export RALPH_BATCH="$BATCH_DIR"
