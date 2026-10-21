#!/bin/bash
# Resolves one foreman batch into a fully-populated set of FOREMAN_* variables.
# Sourced by foreman-loop.sh, foreman-next.sh and foreman-doctor.sh — never run directly.
#
# THE TOOLKIT HOLDS NO STATE. Everything that differs between batches — the order, the
# progress notes, the run logs, the config — lives in the batch directory. This file only
# works out where that directory is and fills in defaults for whatever it did not set.
#
# The toolkit is installed once per machine and is NOT inside the repository it operates
# on: FOREMAN_TOOL_DIR comes from BASH_SOURCE, REPO_ROOT from `git rev-parse` in the caller's
# working directory. The two are unrelated paths, and nothing here may assume otherwise.
#
# Precedence, highest first:
#   1. environment variables       FOREMAN_MAX_COST_USD=25 foreman run <batch>
#   2. the batch's foreman.conf      <batch>/foreman.conf
#   3. the defaults below
#
# Inputs:  FOREMAN_BATCH   path to the batch directory (the caller sets this from its
#                        positional argument, or the user exports it). If unset, and
#                        exactly one directory in the repo has a foreman.conf, that one is
#                        used; otherwise this errors with the candidates listed.
#
# Outputs (all repo-relative unless noted, because the agent's working directory is the
# repo root and every path it is handed must resolve there):
#   REPO_ROOT            absolute path to the repository being worked on
#   FOREMAN_TOOL_DIR       absolute path to this toolkit's lib directory
#   FOREMAN_HOME           absolute path to the toolkit install (lib's parent)
#   FOREMAN_INVOKE         how to spell the command in a message to the user
#   BATCH_DIR            repo-relative path to the batch directory
#   BATCH_NAME           its basename, unless foreman.conf overrides it
#   ORDER_FILE PROGRESS_FILE RUN_JSONL RUN_LOG BUNDLE_FILE STALL_MARKER_FILE
#   PROMPT_EXTRA_FILE
#   plus every FOREMAN_* knob documented in foreman.conf.template

# This file's directory, from the shell: `dirname` would be a process, and `${x%/*}` alone is
# wrong for a bare name (`bash script.sh`) and for a file in `/`.
FOREMAN_TOOL_DIR="${BASH_SOURCE[0]%/*}"; [ "$FOREMAN_TOOL_DIR" != "${BASH_SOURCE[0]}" ] || FOREMAN_TOOL_DIR=.
FOREMAN_TOOL_DIR="$(cd "${FOREMAN_TOOL_DIR:-/}" && pwd)"
FOREMAN_HOME="${FOREMAN_HOME:-$(cd "$FOREMAN_TOOL_DIR/.." && pwd)}"

# How every "here is what to type next" message should name this toolkit. The `foreman`
# dispatcher exports it; a direct `bash lib/foreman-loop.sh` call falls back to the install's
# own path, which is still copy-pasteable.
FOREMAN_INVOKE="${FOREMAN_INVOKE:-$FOREMAN_HOME/bin/foreman}"

# Path resolution — repo root, and a batch's repo-relative path — lives in foreman-repo.sh,
# because on Windows it is a minefield and foreman-init.sh and foreman-doctor.sh have to cross
# it exactly the same way.
# shellcheck source=foreman-repo.sh
source "$FOREMAN_TOOL_DIR/foreman-repo.sh" || {
  echo "foreman: cannot load $FOREMAN_TOOL_DIR/foreman-repo.sh" >&2
  return 1 2>/dev/null || exit 1
}

foreman_repo_root REPO_ROOT || {
  echo "foreman: not inside a git repository" >&2
  return 1 2>/dev/null || exit 1
}
# Every path this file produces is repo-relative, because the repo root is the agent's
# working directory. Standing there is what makes that the natural spelling.
cd "$REPO_ROOT" || { echo "foreman: cannot cd to $REPO_ROOT" >&2; return 1 2>/dev/null || exit 1; }

# legacy: RALPH_* knobs from the environment, from before the rename (foreman-legacy.sh).
foreman_legacy_knobs "the environment"

# ---------------------------------------------------------------------------
# Which batch?
# ---------------------------------------------------------------------------

if [ -z "${FOREMAN_BATCH:-}" ]; then
  # foreman_find_batches (foreman-repo.sh) is the one answer to "which directories are foreman
  # batches" — foreman-report.cjs shells out to the same function rather than keeping its own.
  _foreman_candidates=$(foreman_find_batches)
  _foreman_count=$(printf '%s' "$_foreman_candidates" | grep -c . || true)
  if [ "$_foreman_count" = "1" ]; then
    FOREMAN_BATCH="$_foreman_candidates"
  elif [ "$_foreman_count" = "0" ]; then
    echo "foreman: no batch given and no unfinished foreman.conf batch found anywhere in $REPO_ROOT." >&2
    echo "       (Finished batches, renamed ${FOREMAN_DONE_PREFIX-DONE_}<name>, are skipped; name one to use it.)" >&2
    echo "       Pass one:      $FOREMAN_INVOKE status <batch-dir>" >&2
    echo "       Or create one: $FOREMAN_INVOKE init <batch-dir>" >&2
    return 1 2>/dev/null || exit 1
  else
    echo "foreman: no batch given, and $_foreman_count directories have a foreman.conf:" >&2
    printf '         %s\n' $_foreman_candidates >&2
    echo "       Name the one you mean." >&2
    return 1 2>/dev/null || exit 1
  fi
fi

# Accept an absolute path, a Windows-style path, or a path relative to the repo root or to
# the caller's own directory — and let git normalise all of them to repo-relative.
foreman_batch_relpath BATCH_DIR "$FOREMAN_BATCH" "$REPO_ROOT"
case "$?" in
  1)
    echo "foreman: no such directory: $FOREMAN_BATCH" >&2
    return 1 2>/dev/null || exit 1
    ;;
  2)
    echo "foreman: the batch directory must be inside the repository." >&2
    echo "       batch: $FOREMAN_BATCH" >&2
    echo "       repo:  $REPO_ROOT" >&2
    echo "       The agent runs with the repo root as its working directory, so a batch" >&2
    echo "       outside it has no path the agent could open." >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Load foreman.conf, with the environment winning over it
#
# Every FOREMAN_* variable that exists right now came from the environment: no foreman script
# sets one before sourcing this file. Snapshot them, source the conf, put them back.
# ---------------------------------------------------------------------------
declare -A _FOREMAN_FROM_ENV=()
for _foreman_name in $(compgen -v FOREMAN_ 2>/dev/null); do
  _FOREMAN_FROM_ENV["$_foreman_name"]="${!_foreman_name}"
done

# legacy: a batch from before the rename may only have a ralph.conf (foreman-legacy.sh).
foreman_legacy_conf_path FOREMAN_CONF "$BATCH_DIR"
if [ -f "$FOREMAN_CONF" ]; then
  # A CRLF checkout would put a trailing \r on the end of every value this file sets —
  # FOREMAN_EXEC would become "sandbox<CR>" and fail validation with a message that looks
  # like a lie. `.gitattributes` pins foreman.conf to LF, but a file copied in from
  # elsewhere or edited in a CRLF editor would not be covered, so source a stripped copy
  # rather than trust it.
  if grep -qU $'\r' "$FOREMAN_CONF" 2>/dev/null; then
    _foreman_conf_lf="$(mktemp)"
    tr -d '\r' < "$FOREMAN_CONF" > "$_foreman_conf_lf"
    # shellcheck source=/dev/null
    source "$_foreman_conf_lf" || { rm -f "$_foreman_conf_lf"; echo "foreman: $FOREMAN_CONF could not be sourced" >&2; return 1 2>/dev/null || exit 1; }
    rm -f "$_foreman_conf_lf"
    unset _foreman_conf_lf
  else
    # shellcheck source=/dev/null
    source "$FOREMAN_CONF" || {
      echo "foreman: $FOREMAN_CONF could not be sourced" >&2
      return 1 2>/dev/null || exit 1
    }
  fi
  # legacy: an old conf sets RALPH_* names. Before the environment is put back, so it still wins.
  foreman_legacy_knobs "$FOREMAN_CONF"
fi

for _foreman_name in "${!_FOREMAN_FROM_ENV[@]}"; do
  printf -v "$_foreman_name" '%s' "${_FOREMAN_FROM_ENV[$_foreman_name]}"
done
unset _FOREMAN_FROM_ENV _foreman_name _foreman_candidates _foreman_count

# ---------------------------------------------------------------------------
# Defaults for everything foreman.conf and the environment left unset
# ---------------------------------------------------------------------------
_foreman_basename BATCH_NAME "$BATCH_DIR"
BATCH_NAME="${FOREMAN_BATCH_NAME:-$BATCH_NAME}"

# --- tickets ---------------------------------------------------------------
FOREMAN_STATUS_LINE="${FOREMAN_STATUS_LINE:-**Status:**}"
# The word the prompt tells the agent to write.
FOREMAN_DONE_WORD="${FOREMAN_DONE_WORD:-implemented}"
# The status line as a BRE fragment, which the done and the human patterns both start with:
# every character that means something in a BRE is escaped, so it matches itself only. Done in
# the shell, once, with no `sed`; the backslash goes first so it does not double the others.
_foreman_bs='\'
_foreman_status_line_re="${FOREMAN_STATUS_LINE//"$_foreman_bs"/"$_foreman_bs$_foreman_bs"}"
for _foreman_c in . '[' '*' '^' '$'; do
  _foreman_status_line_re="${_foreman_status_line_re//"$_foreman_c"/"$_foreman_bs$_foreman_c"}"
done
unset _foreman_c _foreman_bs

# A ticket counts as done when this grep pattern (a BRE) matches a line in its file.
# Derived from the two settings above by default, so they cannot drift out of sync — set
# FOREMAN_DONE_PATTERN directly only if a ticket's status line isn't a simple
# "$FOREMAN_STATUS_LINE $FOREMAN_DONE_WORD" prefix.
if [ -z "${FOREMAN_DONE_PATTERN:-}" ]; then
  # The tracker convention in docs/agents/issue-tracker.md marks a finished ticket `done`,
  # while the prompt asks the agent for `implemented`; with the default word, accept both.
  _foreman_done_words="$FOREMAN_DONE_WORD"
  [ "$FOREMAN_DONE_WORD" = implemented ] && _foreman_done_words='\(implemented\|done\)'
  FOREMAN_DONE_PATTERN="^$_foreman_status_line_re *$_foreman_done_words"
fi

# A HUMAN TICKET is one only a person can do (see foreman-human.sh): the loop stops before it
# instead of handing it to an agent. `${VAR-default}`, not `:-`, so an empty word sticks and
# switches the feature off — the pattern is then empty, and callers must not hand an empty
# pattern to grep, which matches every line.
FOREMAN_HUMAN_WORD="${FOREMAN_HUMAN_WORD-ready-for-human}"
if [ -z "${FOREMAN_HUMAN_PATTERN:-}" ] && [ -n "$FOREMAN_HUMAN_WORD" ]; then
  FOREMAN_HUMAN_PATTERN="^$_foreman_status_line_re *$FOREMAN_HUMAN_WORD"
fi
FOREMAN_HUMAN_PATTERN="${FOREMAN_HUMAN_PATTERN:-}"

# The two patterns above are grep BREs; a ticket's status line is read in-process (see
# foreman-tickets.sh), where bash matches EREs. Set _FOREMAN_ERE to an ERE that matches what the BRE
# does, or return 1 for a BRE this does not translate (a backreference, a GNU word escape, an
# unclosed bracket) — the caller then falls back to grep, so a pattern is never read differently.
# Literal ( ) { } | + ? and a leading * are escaped; \( \) \{ \} \| \+ \? lose their backslash.
# `start` is 1 where a ^ is still an anchor and a * still literal, 2 just after the anchor (a
# second ^ is then a literal), 0 once something has been matched.
_foreman_bre_to_ere() {    # _foreman_bre_to_ere BRE
  local bre="$1" out="" c next i=0 n=${#1} start=1 j
  while [ "$i" -lt "$n" ]; do
    c="${bre:i:1}"
    case "$c" in
      \\)
        next="${bre:i+1:1}"
        case "$next" in
          '') return 1 ;;
          '('|'|') out+="$next"; start=1 ;;
          '{') [[ "${bre:i+2:1}" == [0-9] ]] || return 1    # \{,n\} is grep's, not bash's
               out+="$next"; start=0 ;;
          ')'|'}'|'+'|'?') out+="$next"; start=0 ;;
          [1-9\<\>bBwWsS\`\']) return 1 ;;
          *) out+="\\$next"; start=0 ;;
        esac
        i=$((i + 2)) ;;
      '[')    # a bracket expression is the same in both, [:classes:] and a leading ] included
        j=$((i + 1))
        [ "${bre:j:1}" = '^' ] && j=$((j + 1))
        [ "${bre:j:1}" = ']' ] && j=$((j + 1))
        while [ "$j" -lt "$n" ] && [ "${bre:j:1}" != ']' ]; do
          if [ "${bre:j:1}" = '[' ] && [[ "${bre:j+1:1}" == [:.=] ]]; then
            next="${bre:j+1:1}"
            j=$((j + 2))
            while [ "$j" -lt "$n" ] && ! { [ "${bre:j:1}" = "$next" ] && [ "${bre:j+1:1}" = ']' ]; }; do j=$((j + 1)); done
            j=$((j + 2))
          else
            j=$((j + 1))
          fi
        done
        [ "$j" -lt "$n" ] || return 1
        out+="${bre:i:j-i+1}"; i=$((j + 1)); start=0 ;;
      '*') if [ "$start" != 0 ]; then out+='\*'; else out+='*'; fi; i=$((i + 1)); start=0 ;;
      '^') if [ "$start" = 1 ]; then out+='^'; start=2; else out+='\^'; start=0; fi; i=$((i + 1)) ;;
      '$')
        next="${bre:i+1:2}"
        if [ "$((i + 1))" -eq "$n" ] || [ "$next" = '\)' ] || [ "$next" = '\|' ]; then out+='$'; else out+='\$'; fi
        i=$((i + 1)); start=0 ;;
      '('|')'|'{'|'}'|'|'|'+'|'?') out+="\\$c"; i=$((i + 1)); start=0 ;;
      *) out+="$c"; i=$((i + 1)); start=0 ;;
    esac
  done
  _FOREMAN_ERE="$out"
  [[ "" =~ $_FOREMAN_ERE ]]; [ "$?" -ne 2 ]    # bash itself has the last word on whether it compiles
}

# Empty means "ask grep": the pattern did not translate. An empty human pattern is the feature
# switched off, and never reaches either.
_FOREMAN_DONE_ERE=""
_FOREMAN_HUMAN_ERE=""
_foreman_bre_to_ere "$FOREMAN_DONE_PATTERN" && _FOREMAN_DONE_ERE="$_FOREMAN_ERE"
if [ -n "$FOREMAN_HUMAN_PATTERN" ]; then
  _foreman_bre_to_ere "$FOREMAN_HUMAN_PATTERN" && _FOREMAN_HUMAN_ERE="$_FOREMAN_ERE"
fi

# A ticket that has landed with every checklist box ticked is renamed to ${prefix}<name> by
# the loop (see mark_ticket_done_on_disk), so a directory listing shows what is finished.
# Set it empty to leave ticket files alone. `${VAR-default}`, not `:-`, so empty sticks.
FOREMAN_DONE_PREFIX="${FOREMAN_DONE_PREFIX-DONE_}"

# Every path knob accepts three spellings, so `order.md` in a conf means the batch's own
# order file and `.scratch/shared/order.md` still means what it says:
#   absolute            used as given
#   repo-relative       used as given, if something is already there
#   batch-relative      otherwise — and this is what a bare filename means
#
# Sets the variable it is told to, the convention _foreman_basename uses, because a helper that
# prints its answer has to be called in a command substitution, and that forks.
_foreman_path() {                  # _foreman_path VAR GIVEN FALLBACK
  local _rp_given="$2"
  if [ -z "$_rp_given" ]; then printf -v "$1" '%s/%s' "$BATCH_DIR" "$3"; return; fi
  case "$_rp_given" in
    /*|[A-Za-z]:[/\\]*) printf -v "$1" '%s' "$_rp_given"; return ;;
  esac
  if [ -e "$_rp_given" ]; then printf -v "$1" '%s' "$_rp_given"; else printf -v "$1" '%s/%s' "$BATCH_DIR" "$_rp_given"; fi
}

# Where the run order comes from. If the order file is missing, foreman-next.sh falls back
# to every *.md under FOREMAN_ISSUES_DIRS in filename order.
_foreman_path ORDER_FILE "${FOREMAN_ORDER_FILE:-}" order.md
FOREMAN_ISSUES_DIRS="${FOREMAN_ISSUES_DIRS:-issues}"
FOREMAN_ISSUES_EXCLUDE="${FOREMAN_ISSUES_EXCLUDE:-README.md spec.md order.md}"

# Resolve FOREMAN_ISSUES_DIRS. Absolute paths are used as given; a relative entry is
# BATCH-relative first, because every foreman command stands at the repo root and trying the
# repo first made "." mean the repo root — quietly turning the repo's own top-level *.md
# into this batch's tickets. A genuinely repo-relative entry ("docs/tickets") still
# resolves, since nothing of that name exists under the batch.
foreman_issues_dirs() {            # one resolved path per line, existing or not
  local dir
  for dir in $FOREMAN_ISSUES_DIRS; do
    case "$dir" in
      /*|[A-Za-z]:[/\\]*)                   printf '%s\n' "$dir" ;;
      *) if [ -d "$BATCH_DIR/$dir" ]; then  printf '%s\n' "$BATCH_DIR/$dir"
         else                               printf '%s\n' "$dir"; fi ;;
    esac
  done
}

# Explains a batch that looks empty: which directories FOREMAN_ISSUES_DIRS actually resolved
# to, and — the thing that costs a whole debugging detour without it — whether the tickets
# are sitting directly in the batch directory instead. The default FOREMAN_ISSUES_DIRS="issues"
# looks in <batch>/issues, so a batch directory that is itself named issues/ looks in
# issues/issues and quietly finds nothing.
foreman_issues_hint() {
  local dir shown base excluded n=0
  for dir in $FOREMAN_ISSUES_DIRS; do
    case "$dir" in
      /*|[A-Za-z]:[/\\]*) shown="$dir" ;;
      *)                  shown="$BATCH_DIR/$dir" ;;
    esac
    if [ -d "$shown" ]; then printf '  looked in: %s\n' "$shown"
    else                     printf '  looked in: %s   (missing)\n' "$shown"
    fi
  done
  printf '  from FOREMAN_ISSUES_DIRS="%s", resolved against the batch directory.\n' "$FOREMAN_ISSUES_DIRS"

  for f in "$BATCH_DIR"/*.md; do
    [ -f "$f" ] || continue
    _foreman_basename base "$f"
    local skip=0
    for excluded in $FOREMAN_ISSUES_EXCLUDE; do
      [ "$base" = "$excluded" ] && skip=1 && break
    done
    [ "$skip" -eq 1 ] || n=$((n + 1))
  done
  if [ "$n" -gt 0 ]; then
    printf '  But %s itself holds %s *.md file(s). If the tickets live\n' "$BATCH_DIR" "$n"
    printf '  directly in the batch directory, set  FOREMAN_ISSUES_DIRS="."\n'
    printf '  in %s\n' "$FOREMAN_CONF"
  fi
}

# --- the agent's notes -----------------------------------------------------
_foreman_path PROGRESS_FILE "${FOREMAN_PROGRESS_FILE:-}" progress.txt
FOREMAN_PROGRESS_TAIL_BYTES="${FOREMAN_PROGRESS_TAIL_BYTES:-6000}"
_foreman_path PROMPT_EXTRA_FILE "${FOREMAN_PROMPT_EXTRA:-}" prompt-extra.md

# --- telemetry (append-only, never read back by the loop) ------------------
_foreman_path RUN_JSONL "${FOREMAN_RUN_JSONL:-}" foreman-runs.jsonl
_foreman_path RUN_LOG "${FOREMAN_RUN_LOG:-}" foreman-runs.log
_foreman_path BUNDLE_FILE "${FOREMAN_BUNDLE_FILE:-}" .foreman-iter.bundle

# The one thing a run leaves behind for the next one: written only when a stall could not be
# salvaged, and it is what lets a rerun salvage it instead of refusing. Disposable — see
# foreman-loop.sh's "The stall marker". Not a knob: there is nothing about it worth choosing.
STALL_MARKER_FILE="$BATCH_DIR/.foreman-stall-marker"

# legacy: move ralph-runs.*, .ralph-stall-marker and .ralph-iter.bundle to their new names.
foreman_legacy_batch_files "$BATCH_DIR"

# --- how the agent is executed --------------------------------------------
# The name of an adapter in lib/exec/ — see foreman-exec.sh. sandbox (the default) runs the
# agent on a private clone inside sbx; sandbox-mount bind-mounts this tree; local runs
# `claude` here with no sandbox; fake runs no agent at all.
FOREMAN_EXEC="${FOREMAN_EXEC:-sandbox}"
_foreman_basename _foreman_repo_name "$REPO_ROOT"
FOREMAN_SANDBOX="${FOREMAN_SANDBOX:-foreman-$_foreman_repo_name}"
unset _foreman_repo_name
FOREMAN_SANDBOX_SETUP="${FOREMAN_SANDBOX_SETUP:-}"
FOREMAN_SANDBOX_PROBE="${FOREMAN_SANDBOX_PROBE:-}"
FOREMAN_SKIP_SANDBOX_PROBE="${FOREMAN_SKIP_SANDBOX_PROBE:-0}"

# --- the agent -------------------------------------------------------------
# The default is a full model id, not the `sonnet` alias: the alias is resolved by whichever
# claude CLI runs the call, and the CLI inside the sandbox can be older than the host's and
# resolve it to an older Sonnet. Bumping the id is a deliberate edit here.
FOREMAN_MODEL="${FOREMAN_MODEL:-claude-sonnet-5-5}"
FOREMAN_EFFORT="${FOREMAN_EFFORT:-high}"
# FOREMAN_PERMISSION_MODE is deliberately NOT defaulted here: the default depends on where the
# agent runs, and the adapter that knows is not loaded until the validation section below.
declare -p FOREMAN_CLAUDE_ARGS >/dev/null 2>&1 || FOREMAN_CLAUDE_ARGS=()

# --- prompt slots ----------------------------------------------------------
FOREMAN_CHECK_CMD="${FOREMAN_CHECK_CMD:-}"
FOREMAN_TEST_CMD="${FOREMAN_TEST_CMD:-}"
FOREMAN_FOCUSED_TEST_CMD="${FOREMAN_FOCUSED_TEST_CMD:-}"
FOREMAN_TDD_SKILL="${FOREMAN_TDD_SKILL:-}"
FOREMAN_REVIEW_SKILL="${FOREMAN_REVIEW_SKILL:-}"

# --- budgets ---------------------------------------------------------------
FOREMAN_MAX_COST_USD="${FOREMAN_MAX_COST_USD:-0}"
FOREMAN_MAX_MINUTES="${FOREMAN_MAX_MINUTES:-0}"
FOREMAN_TICKET_ATTEMPTS="${FOREMAN_TICKET_ATTEMPTS:-2}"
FOREMAN_ALLOW_DIRTY="${FOREMAN_ALLOW_DIRTY:-0}"
# Watch the iteration as it happens (`foreman run --live` sets this). Off by default, so the
# default path — the agent's own --output-format included — stays exactly as it was.
FOREMAN_STREAM="${FOREMAN_STREAM:-0}"
# Colour on glyphs and prefixes — see foreman-ui.sh. auto: only on a terminal, and not with
# NO_COLOR set; always / never force it. Piped and logged output is never coloured under auto.
FOREMAN_COLOR="${FOREMAN_COLOR:-auto}"
# How much context a ticket is expected to fit well inside. A prompt slot, not a limit
# anything enforces — the CLI has no such flag, and --autocompact is the real backstop. It
# lives here rather than as a literal in the shared template because it is model- and
# version-specific, and a number written into the template would age badly there.
FOREMAN_CONTEXT_BUDGET_TOKENS="${FOREMAN_CONTEXT_BUDGET_TOKENS:-200000}"
# Consecutive iterations that may commit progress on one ticket without landing it before
# the loop stops for a human. Five chunks is not a retry problem; it is a mis-sized ticket,
# and splitting it is a decision only a human can make.
FOREMAN_MAX_CONTINUATIONS="${FOREMAN_MAX_CONTINUATIONS:-5}"
# How long one shell command the agent runs may take. Claude Code's Bash tool caps a call at
# 10 minutes by default, and a full test suite that outgrows that cannot be run in the
# foreground at all — so the agent backgrounds it, and in a one-shot --print turn nothing
# ever wakes it when the result is ready. The adapters raise the cap (BASH_MAX_TIMEOUT_MS)
# to this, and the prompt tells the agent the number.
FOREMAN_COMMAND_TIMEOUT_MINUTES="${FOREMAN_COMMAND_TIMEOUT_MINUTES:-60}"

# --- validation ------------------------------------------------------------
# A valid FOREMAN_EXEC is one with an adapter file in lib/exec/. There is deliberately no
# list of modes here: adding a mode is adding a file, and this check follows.
# shellcheck source=foreman-exec.sh
source "$FOREMAN_TOOL_DIR/foreman-exec.sh" || {
  echo "foreman: cannot load $FOREMAN_TOOL_DIR/foreman-exec.sh" >&2
  return 1 2>/dev/null || exit 1
}
if ! foreman_exec_is_mode "$FOREMAN_EXEC"; then
  echo "foreman: FOREMAN_EXEC must be one of: $(foreman_exec_modes | tr '\n' ' ')(got '$FOREMAN_EXEC')" >&2
  return 1 2>/dev/null || exit 1
fi

# The permission mode, now that there is an adapter to ask. This has to come after the block
# above rather than beside FOREMAN_MODEL, because the default is a property of where the agent
# runs — see exec_default_permission_mode in foreman-exec.sh. A value from the environment or
# from foreman.conf always wins; the adapter is only consulted when there is none.
if [ -z "${FOREMAN_PERMISSION_MODE:-}" ]; then
  FOREMAN_PERMISSION_MODE="$(foreman_exec_default_permission_mode "$FOREMAN_EXEC")" ||
    FOREMAN_PERMISSION_MODE=acceptEdits
fi

case "$FOREMAN_COLOR" in
  auto|always|never) ;;
  *)
    echo "foreman: FOREMAN_COLOR must be auto, always or never (got '$FOREMAN_COLOR')" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

for _foreman_int in FOREMAN_TICKET_ATTEMPTS FOREMAN_MAX_MINUTES FOREMAN_PROGRESS_TAIL_BYTES \
                  FOREMAN_CONTEXT_BUDGET_TOKENS FOREMAN_MAX_CONTINUATIONS; do
  if ! [[ "${!_foreman_int}" =~ ^[0-9]+$ ]]; then
    echo "foreman: $_foreman_int must be a whole number (got '${!_foreman_int}')" >&2
    return 1 2>/dev/null || exit 1
  fi
done
unset _foreman_int
# Not 0 = "no limit" like the budgets: a zero cap would leave the agent no command at all.
if ! [[ "$FOREMAN_COMMAND_TIMEOUT_MINUTES" =~ ^[1-9][0-9]*$ ]]; then
  echo "foreman: FOREMAN_COMMAND_TIMEOUT_MINUTES must be a whole number of minutes, at least 1 (got '$FOREMAN_COMMAND_TIMEOUT_MINUTES')" >&2
  return 1 2>/dev/null || exit 1
fi

export FOREMAN_BATCH="$BATCH_DIR"
