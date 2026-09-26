#!/bin/bash
# Resolves one ralph batch into a fully-populated set of RALPH_* variables.
# Sourced by ralph-loop.sh, ralph-next.sh and ralph-doctor.sh — never run directly.
#
# THE TOOLKIT HOLDS NO STATE. Everything that differs between batches — the order, the
# progress notes, the run logs, the config — lives in the batch directory. This file only
# works out where that directory is and fills in defaults for whatever it did not set.
#
# The toolkit is installed once per machine and is NOT inside the repository it operates
# on: RALPH_TOOL_DIR comes from BASH_SOURCE, REPO_ROOT from `git rev-parse` in the caller's
# working directory. The two are unrelated paths, and nothing here may assume otherwise.
#
# Precedence, highest first:
#   1. environment variables       RALPH_MAX_COST_USD=25 ralph run <batch>
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
#   REPO_ROOT            absolute path to the repository being worked on
#   RALPH_TOOL_DIR       absolute path to this toolkit's lib directory
#   RALPH_HOME           absolute path to the toolkit install (lib's parent)
#   RALPH_INVOKE         how to spell the command in a message to the user
#   BATCH_DIR            repo-relative path to the batch directory
#   BATCH_NAME           its basename, unless ralph.conf overrides it
#   ORDER_FILE PROGRESS_FILE RUN_JSONL RUN_LOG BUNDLE_FILE STALL_MARKER_FILE
#   PROMPT_EXTRA_FILE
#   plus every RALPH_* knob documented in ralph.conf.template

RALPH_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_HOME="${RALPH_HOME:-$(cd "$RALPH_TOOL_DIR/.." && pwd)}"

# How every "here is what to type next" message should name this toolkit. The `ralph`
# dispatcher exports it; a direct `bash lib/ralph-loop.sh` call falls back to the install's
# own path, which is still copy-pasteable.
RALPH_INVOKE="${RALPH_INVOKE:-$RALPH_HOME/bin/ralph}"

# Path resolution — repo root, and a batch's repo-relative path — lives in ralph-repo.sh,
# because on Windows it is a minefield and ralph-init.sh and ralph-doctor.sh have to cross
# it exactly the same way.
# shellcheck source=ralph-repo.sh
source "$RALPH_TOOL_DIR/ralph-repo.sh" || {
  echo "ralph: cannot load $RALPH_TOOL_DIR/ralph-repo.sh" >&2
  return 1 2>/dev/null || exit 1
}

REPO_ROOT="$(ralph_repo_root)" || {
  echo "ralph: not inside a git repository" >&2
  return 1 2>/dev/null || exit 1
}
# Every path this file produces is repo-relative, because the repo root is the agent's
# working directory. Standing there is what makes that the natural spelling.
cd "$REPO_ROOT" || { echo "ralph: cannot cd to $REPO_ROOT" >&2; return 1 2>/dev/null || exit 1; }

# ---------------------------------------------------------------------------
# Which batch?
# ---------------------------------------------------------------------------

if [ -z "${RALPH_BATCH:-}" ]; then
  # ralph_find_batches (ralph-repo.sh) is the one answer to "which directories are ralph
  # batches" — ralph-report.cjs shells out to the same function rather than keeping its own.
  _ralph_candidates=$(ralph_find_batches)
  _ralph_count=$(printf '%s' "$_ralph_candidates" | grep -c . || true)
  if [ "$_ralph_count" = "1" ]; then
    RALPH_BATCH="$_ralph_candidates"
  elif [ "$_ralph_count" = "0" ]; then
    echo "ralph: no batch given and no ralph.conf found anywhere in $REPO_ROOT." >&2
    echo "       Pass one:      $RALPH_INVOKE status <batch-dir>" >&2
    echo "       Or create one: $RALPH_INVOKE init <batch-dir>" >&2
    return 1 2>/dev/null || exit 1
  else
    echo "ralph: no batch given, and $_ralph_count directories have a ralph.conf:" >&2
    printf '         %s\n' $_ralph_candidates >&2
    echo "       Name the one you mean." >&2
    return 1 2>/dev/null || exit 1
  fi
fi

# Accept an absolute path, a Windows-style path, or a path relative to the repo root or to
# the caller's own directory — and let git normalise all of them to repo-relative.
BATCH_DIR="$(ralph_batch_relpath "$RALPH_BATCH" "$REPO_ROOT")"
case "$?" in
  1)
    echo "ralph: no such directory: $RALPH_BATCH" >&2
    return 1 2>/dev/null || exit 1
    ;;
  2)
    echo "ralph: the batch directory must be inside the repository." >&2
    echo "       batch: $RALPH_BATCH" >&2
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
unset _RALPH_FROM_ENV _ralph_name _ralph_candidates _ralph_count

# ---------------------------------------------------------------------------
# Defaults for everything ralph.conf and the environment left unset
# ---------------------------------------------------------------------------
BATCH_NAME="${RALPH_BATCH_NAME:-$(basename "$BATCH_DIR")}"

# --- tickets ---------------------------------------------------------------
RALPH_STATUS_LINE="${RALPH_STATUS_LINE:-**Status:**}"
# The word the prompt tells the agent to write.
RALPH_DONE_WORD="${RALPH_DONE_WORD:-implemented}"
# The status line as a BRE fragment: what the done and the human patterns both start with.
_ralph_status_line_re() { printf '%s' "$RALPH_STATUS_LINE" | sed -e 's/\\/\\\\/g' -e 's/[.[*^$]/\\&/g'; }

# A ticket counts as done when this grep pattern (a BRE) matches a line in its file.
# Derived from the two settings above by default, so they cannot drift out of sync — set
# RALPH_DONE_PATTERN directly only if a ticket's status line isn't a simple
# "$RALPH_STATUS_LINE $RALPH_DONE_WORD" prefix.
if [ -z "${RALPH_DONE_PATTERN:-}" ]; then
  # The tracker convention in docs/agents/issue-tracker.md marks a finished ticket `done`,
  # while the prompt asks the agent for `implemented`; with the default word, accept both.
  _ralph_done_words="$RALPH_DONE_WORD"
  [ "$RALPH_DONE_WORD" = implemented ] && _ralph_done_words='\(implemented\|done\)'
  RALPH_DONE_PATTERN="^$(_ralph_status_line_re) *$_ralph_done_words"
fi

# A HUMAN TICKET is one only a person can do (see ralph-human.sh): the loop stops before it
# instead of handing it to an agent. `${VAR-default}`, not `:-`, so an empty word sticks and
# switches the feature off — the pattern is then empty, and callers must not hand an empty
# pattern to grep, which matches every line.
RALPH_HUMAN_WORD="${RALPH_HUMAN_WORD-ready-for-human}"
if [ -z "${RALPH_HUMAN_PATTERN:-}" ] && [ -n "$RALPH_HUMAN_WORD" ]; then
  RALPH_HUMAN_PATTERN="^$(_ralph_status_line_re) *$RALPH_HUMAN_WORD"
fi
RALPH_HUMAN_PATTERN="${RALPH_HUMAN_PATTERN:-}"

# A ticket that has landed with every checklist box ticked is renamed to ${prefix}<name> by
# the loop (see mark_ticket_done_on_disk), so a directory listing shows what is finished.
# Set it empty to leave ticket files alone. `${VAR-default}`, not `:-`, so empty sticks.
RALPH_DONE_PREFIX="${RALPH_DONE_PREFIX-DONE_}"

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

# Resolve RALPH_ISSUES_DIRS. Absolute paths are used as given; a relative entry is
# BATCH-relative first, because every ralph command stands at the repo root and trying the
# repo first made "." mean the repo root — quietly turning the repo's own top-level *.md
# into this batch's tickets. A genuinely repo-relative entry ("docs/tickets") still
# resolves, since nothing of that name exists under the batch.
ralph_issues_dirs() {            # one resolved path per line, existing or not
  local dir
  for dir in $RALPH_ISSUES_DIRS; do
    case "$dir" in
      /*|[A-Za-z]:[/\\]*)                   printf '%s\n' "$dir" ;;
      *) if [ -d "$BATCH_DIR/$dir" ]; then  printf '%s\n' "$BATCH_DIR/$dir"
         else                               printf '%s\n' "$dir"; fi ;;
    esac
  done
}

# Explains a batch that looks empty: which directories RALPH_ISSUES_DIRS actually resolved
# to, and — the thing that costs a whole debugging detour without it — whether the tickets
# are sitting directly in the batch directory instead. The default RALPH_ISSUES_DIRS="issues"
# looks in <batch>/issues, so a batch directory that is itself named issues/ looks in
# issues/issues and quietly finds nothing.
ralph_issues_hint() {
  local dir shown base excluded n=0
  for dir in $RALPH_ISSUES_DIRS; do
    case "$dir" in
      /*|[A-Za-z]:[/\\]*) shown="$dir" ;;
      *)                  shown="$BATCH_DIR/$dir" ;;
    esac
    if [ -d "$shown" ]; then printf '  looked in: %s\n' "$shown"
    else                     printf '  looked in: %s   (missing)\n' "$shown"
    fi
  done
  printf '  from RALPH_ISSUES_DIRS="%s", resolved against the batch directory.\n' "$RALPH_ISSUES_DIRS"

  for f in "$BATCH_DIR"/*.md; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    local skip=0
    for excluded in $RALPH_ISSUES_EXCLUDE; do
      [ "$base" = "$excluded" ] && skip=1 && break
    done
    [ "$skip" -eq 1 ] || n=$((n + 1))
  done
  if [ "$n" -gt 0 ]; then
    printf '  But %s itself holds %s *.md file(s). If the tickets live\n' "$BATCH_DIR" "$n"
    printf '  directly in the batch directory, set  RALPH_ISSUES_DIRS="."\n'
    printf '  in %s\n' "$RALPH_CONF"
  fi
}

# --- the agent's notes -----------------------------------------------------
PROGRESS_FILE="$(_ralph_path "${RALPH_PROGRESS_FILE:-}" progress.txt)"
RALPH_PROGRESS_TAIL_BYTES="${RALPH_PROGRESS_TAIL_BYTES:-6000}"
PROMPT_EXTRA_FILE="$(_ralph_path "${RALPH_PROMPT_EXTRA:-}" prompt-extra.md)"

# --- telemetry (append-only, never read back by the loop) ------------------
RUN_JSONL="$(_ralph_path "${RALPH_RUN_JSONL:-}" ralph-runs.jsonl)"
RUN_LOG="$(_ralph_path "${RALPH_RUN_LOG:-}" ralph-runs.log)"
BUNDLE_FILE="$(_ralph_path "${RALPH_BUNDLE_FILE:-}" .ralph-iter.bundle)"

# The one thing a run leaves behind for the next one: written only when a stall could not be
# salvaged, and it is what lets a rerun salvage it instead of refusing. Disposable — see
# ralph-loop.sh's "The stall marker". Not a knob: there is nothing about it worth choosing.
STALL_MARKER_FILE="$BATCH_DIR/.ralph-stall-marker"

# --- how the agent is executed --------------------------------------------
# The name of an adapter in lib/exec/ — see ralph-exec.sh. sandbox (the default) runs the
# agent on a private clone inside sbx; sandbox-mount bind-mounts this tree; local runs
# `claude` here with no sandbox; fake runs no agent at all.
RALPH_EXEC="${RALPH_EXEC:-sandbox}"
RALPH_SANDBOX="${RALPH_SANDBOX:-ralph-$(basename "$REPO_ROOT")}"
RALPH_SANDBOX_SETUP="${RALPH_SANDBOX_SETUP:-}"
RALPH_SANDBOX_PROBE="${RALPH_SANDBOX_PROBE:-}"
RALPH_SKIP_SANDBOX_PROBE="${RALPH_SKIP_SANDBOX_PROBE:-0}"

# --- the agent -------------------------------------------------------------
RALPH_MODEL="${RALPH_MODEL:-claude-sonnet-5}"
RALPH_EFFORT="${RALPH_EFFORT:-high}"
# RALPH_PERMISSION_MODE is deliberately NOT defaulted here: the default depends on where the
# agent runs, and the adapter that knows is not loaded until the validation section below.
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
# Watch the iteration as it happens (`ralph run --live` sets this). Off by default, so the
# default path — the agent's own --output-format included — stays exactly as it was.
RALPH_STREAM="${RALPH_STREAM:-0}"
# How much context a ticket is expected to fit well inside. A prompt slot, not a limit
# anything enforces — the CLI has no such flag, and --autocompact is the real backstop. It
# lives here rather than as a literal in the shared template because it is model- and
# version-specific, and a number written into the template would age badly there.
RALPH_CONTEXT_BUDGET_TOKENS="${RALPH_CONTEXT_BUDGET_TOKENS:-200000}"
# Consecutive iterations that may commit progress on one ticket without landing it before
# the loop stops for a human. Five chunks is not a retry problem; it is a mis-sized ticket,
# and splitting it is a decision only a human can make.
RALPH_MAX_CONTINUATIONS="${RALPH_MAX_CONTINUATIONS:-5}"

# --- validation ------------------------------------------------------------
# A valid RALPH_EXEC is one with an adapter file in lib/exec/. There is deliberately no
# list of modes here: adding a mode is adding a file, and this check follows.
# shellcheck source=ralph-exec.sh
source "$RALPH_TOOL_DIR/ralph-exec.sh" || {
  echo "ralph: cannot load $RALPH_TOOL_DIR/ralph-exec.sh" >&2
  return 1 2>/dev/null || exit 1
}
if ! ralph_exec_is_mode "$RALPH_EXEC"; then
  echo "ralph: RALPH_EXEC must be one of: $(ralph_exec_modes | tr '\n' ' ')(got '$RALPH_EXEC')" >&2
  return 1 2>/dev/null || exit 1
fi

# The permission mode, now that there is an adapter to ask. This has to come after the block
# above rather than beside RALPH_MODEL, because the default is a property of where the agent
# runs — see exec_default_permission_mode in ralph-exec.sh. A value from the environment or
# from ralph.conf always wins; the adapter is only consulted when there is none.
if [ -z "${RALPH_PERMISSION_MODE:-}" ]; then
  RALPH_PERMISSION_MODE="$(ralph_exec_default_permission_mode "$RALPH_EXEC")" ||
    RALPH_PERMISSION_MODE=acceptEdits
fi

for _ralph_int in RALPH_TICKET_ATTEMPTS RALPH_MAX_MINUTES RALPH_PROGRESS_TAIL_BYTES \
                  RALPH_CONTEXT_BUDGET_TOKENS RALPH_MAX_CONTINUATIONS; do
  if ! [[ "${!_ralph_int}" =~ ^[0-9]+$ ]]; then
    echo "ralph: $_ralph_int must be a whole number (got '${!_ralph_int}')" >&2
    return 1 2>/dev/null || exit 1
  fi
done
unset _ralph_int

export RALPH_BATCH="$BATCH_DIR"
