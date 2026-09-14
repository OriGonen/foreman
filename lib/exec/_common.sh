#!/bin/bash
# Shared implementation for the adapters whose agent commits into the working tree the
# loop is already watching: `local`, `sandbox-mount` and `fake`. Not a mode — the leading
# underscore is what keeps it out of `ralph_exec_modes`.
#
# For all three, "collect the iteration's work" is just "look at this repo", and nothing
# can be stranded anywhere, so there is never a recovery note.

exec_sync_down() { return 0; }

exec_collect() {
  EXEC_AGENT_HEAD="$(git rev-parse HEAD)"
  EXEC_DIRTY=0
  [ -z "$(git status --porcelain)" ] || EXEC_DIRTY=1
  return 0
}

exec_show_dirty() {
  git status --short >&2
  warn ""
  warn "Inspect with: git diff"
}

exec_recovery_note() { :; }

# The dirty tree a stop finds IS this repo (or, for sandbox-mount, bind-mounted onto it),
# so getting it committed is exactly the two lines it always was.
exec_dirty_recovery_note() {
  local ticket="$2" batch="$3"
  printf '%s\n' \
    "  git add -A && git commit -m 'wip: $ticket — remaining: <what is left>'" \
    "  $RALPH_INVOKE run $batch"
}

exec_commit_note() {
  printf '%s' "Commit everything to the current branch. Do not push."
}
