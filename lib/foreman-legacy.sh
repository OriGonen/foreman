#!/bin/bash
# Compatibility with batches, installs and environments from before the project was renamed
# from ralph to Foreman. Sourced by foreman-repo.sh — never run.
#
# What the rename left behind, and what happens to it:
#
#   <batch>/ralph.conf     read when the batch has no foreman.conf, with a warning to rename it
#   RALPH_<knob>           accepted, from the environment or a conf, when FOREMAN_<knob> is
#                          unset — with one deprecation warning naming them
#   ralph-runs.jsonl/.log  moved to foreman-runs.* (untracked telemetry), so history continues
#   .ralph-stall-marker    moved to .foreman-stall-marker, so a rerun still salvages the stall
#   .ralph-iter.bundle     deleted: it never outlives an iteration on purpose
#
# Everything here is temporary. Removing the compatibility is deleting this file and every
# line that says "legacy:" (grep for it): the credentials lookup, doctor, install.sh and
# foreman-report.cjs each carry a small hook of their own, because they cannot source this.

# The knobs a user could have set as RALPH_*: everything foreman.conf.template documents, and
# the few the README documents as environment-only. Internal and test-only variables were
# renamed outright and have no fallback.
FOREMAN_LEGACY_KNOBS=(
  CHECK_CMD CLAUDE_ARGS COLOR COMMAND_TIMEOUT_MINUTES CONTEXT_BUDGET_TOKENS DONE_PATTERN
  DONE_PREFIX DONE_WORD EFFORT EXEC FOCUSED_TEST_CMD HUMAN_PATTERN HUMAN_WORD ISSUES_DIRS
  ISSUES_EXCLUDE MAX_CONTINUATIONS MAX_COST_USD MAX_MINUTES MODEL ORDERING_MODEL ORDER_FILE
  PERMISSION_MODE PROGRESS_FILE PROGRESS_TAIL_BYTES PROMPT_EXTRA REVIEW_SKILL SANDBOX
  SANDBOX_PROBE SANDBOX_SETUP STATUS_LINE STREAM TDD_SKILL TEST_CMD TICKET_ATTEMPTS
  ALLOW_DIRTY BATCH BATCH_NAME CREDENTIALS_FILE DOCKER_PAT DOCKER_USERNAME RUN_JSONL RUN_LOG
  SKIP_SANDBOX_PROBE
)

# One process starts others (foreman-loop.sh runs foreman-next.sh, which loads the config
# again), so each warning is said once per run: the first process to say it exports a flag.
_foreman_legacy_say() {
  local flag="$1"; shift
  [ -z "${!flag:-}" ] || return 0
  export "$flag=1"
  printf 'foreman: %s\n' "$1" >&2
  shift
  [ $# -eq 0 ] || printf '         %s\n' "$@" >&2
}

# Copy every RALPH_<knob> that is set onto FOREMAN_<knob>, unless that is set already, then
# unset the RALPH_ name — so a later call (after the conf is sourced) sees only what the conf
# set, and a child process inherits the FOREMAN_ copy instead of warning again.
#   foreman_legacy_knobs WHERE      WHERE names the source in the warning ("the environment")
# A copy is exported when the RALPH_ name was, so a child process sees the same value.
foreman_legacy_knobs() {
  local where="$1" knob old new decl flags copied=()
  for knob in "${FOREMAN_LEGACY_KNOBS[@]}"; do
    old="RALPH_$knob" new="FOREMAN_$knob"
    decl=$(declare -p "$old" 2>/dev/null) || continue
    flags="${decl#declare -}"; flags="${flags%% *}"
    if ! declare -p "$new" >/dev/null 2>&1; then
      if [[ "$flags" == *a* ]]; then
        # An array knob (FOREMAN_CLAUDE_ARGS): copy the elements, not the first one.
        eval "$new=(\"\${$old[@]}\")"
      else
        printf -v "$new" '%s' "${!old}"
        [[ "$flags" != *x* ]] || export "$new"
      fi
    fi
    unset "$old"
    copied+=("$old")
  done
  [ ${#copied[@]} -gt 0 ] || return 0
  _foreman_legacy_say "_FOREMAN_LEGACY_SAID_KNOBS_${where//[^A-Za-z]/_}" \
    "$where sets RALPH_* names, from before the rename to Foreman:" \
    "${copied[*]}" \
    "They still work for now. Rename each to FOREMAN_* — the same name, new prefix."
}

# The conf file of the batch in BATCH_DIR: foreman.conf, or ralph.conf when that is the only
# one it has. Sets the variable named by the first argument.
#   foreman_legacy_conf_path VAR BATCH_DIR
foreman_legacy_conf_path() {
  local batch="$2"
  printf -v "$1" '%s' "$batch/foreman.conf"
  if [ -f "$batch/ralph.conf" ]; then
    if [ -f "$batch/foreman.conf" ]; then
      _foreman_legacy_say _FOREMAN_LEGACY_SAID_BOTH \
        "$batch has both foreman.conf and ralph.conf; using foreman.conf." \
        "Delete ralph.conf once you have moved anything you still need into foreman.conf."
    else
      printf -v "$1" '%s' "$batch/ralph.conf"
      _foreman_legacy_say _FOREMAN_LEGACY_SAID_CONF \
        "$batch/ralph.conf is from before the rename to Foreman. It still works for now;" \
        "rename it:  git mv \"$batch/ralph.conf\" \"$batch/foreman.conf\""
    fi
  fi
}

# Move a batch's untracked run files to their new names. Only the default names are touched:
# a batch that set FOREMAN_RUN_JSONL or FOREMAN_RUN_LOG chose its own, and keeps it.
#   foreman_legacy_batch_files BATCH_DIR
foreman_legacy_batch_files() {
  local batch="$1" old new moved=()
  for old in ralph-runs.jsonl ralph-runs.log .ralph-stall-marker; do
    [ -e "$batch/$old" ] || continue
    new="${old/ralph/foreman}"
    case "$new" in
      foreman-runs.jsonl) [ "${RUN_JSONL:-}" = "$batch/$new" ] || continue ;;
      foreman-runs.log)   [ "${RUN_LOG:-}" = "$batch/$new" ] || continue ;;
    esac
    # Never overwrite: if both exist, the new one is what this version has been writing to.
    [ -e "$batch/$new" ] && continue
    mv "$batch/$old" "$batch/$new" 2>/dev/null && moved+=("$old -> $new")
  done
  rm -f "$batch/.ralph-iter.bundle"
  [ ${#moved[@]} -gt 0 ] || return 0
  printf 'foreman: renamed run files in %s, from before the rename to Foreman:\n' "$batch" >&2
  printf '         %s\n' "${moved[@]}" >&2
  printf '         If `foreman doctor` reports missing .gitignore lines, `foreman doctor --fix` adds them.\n' >&2
}
