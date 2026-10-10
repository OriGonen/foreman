#!/bin/bash
# RALPH_EXEC=sandbox — the default. The agent runs on a PRIVATE CLONE inside the sandbox
# (`sbx create --clone`), not on this working tree.
#
# That is not a preference. A bind-mounted Windows workspace hands a Linux container the
# host's native modules, which it cannot load, and the container cannot install its own
# because npm needs symlinks for node_modules/.bin and the Windows mount refuses them. A
# clone on the container's own filesystem has neither problem, and the host repo is
# mounted read-only so it cannot be clobbered.
#
# The cost is that commits no longer appear here by themselves. Each iteration:
#
#   sync down   sandbox fetches this repo (read-only at /run/sandbox/source) and resets
#               to our HEAD, so it starts from exactly what we have
#   run         the agent works and commits, in the clone
#   collect     sandbox bundles BASE..HEAD, we copy the bundle out and fast-forward
#
# The transport is a git bundle over `sbx cp` rather than the `sandbox-<name>` git remote
# `sbx` sets up. That remote is served by a daemon that only lives while the sandbox is
# running, and `sbx` stops the sandbox after every command — so a fetch issued after a run
# is a race. `sbx cp` starts the sandbox itself and finishes in one command.

# shellcheck source=_sbx.sh
source "$RALPH_EXEC_DIR/_sbx.sh"

exec_describe() { printf 'sandbox (sandbox %s)' "$RALPH_SANDBOX"; }

exec_prepare() {
  _sbx_create clone || return 1

  # A sandbox left over from the other arrangement is the single most expensive mistake
  # available here: it looks fine and fails every iteration *after* paying for the work.
  if ! _sbx_is_clone_mode; then
    warn_preflight "sandbox '$RALPH_SANDBOX' exists but has no $_SBX_SOURCE_MOUNT in it —"
    warn "           it is not a clone sandbox. Recreate it:"
    warn "             sbx rm --force $RALPH_SANDBOX"
    warn "           (If \`sbx\` is signed out, run \`sbx login\` first.)"
    return 1
  fi

  # exec_sync_down fetches through `origin` every iteration and resets to our HEAD. A clone
  # of a repo that already has a GitHub (or other) origin keeps that URL, so left alone this
  # would fetch GitHub and reset to a commit that may never have been pushed there.
  if ! _sbx_point_origin_at_source; then
    warn_preflight "could not point '$RALPH_SANDBOX''s origin at $_SBX_SOURCE_MOUNT."
    warn "           Its origin is currently:"
    warn "             $(_sbx_sh 'git remote get-url origin 2>/dev/null' 2>/dev/null | tr -d '\r')"
    warn "           and exec_sync_down fetches from origin every iteration, so this must"
    warn "           point at the host mount, not some other remote. Inspect with:"
    warn "             sbx exec $RALPH_SANDBOX git remote -v"
    return 1
  fi

  _sbx_probe
}

# Start the agent from exactly what we have. Cheap when already in sync, and it is what
# makes a retry after a failed iteration a genuinely clean second attempt rather than a
# second pass over the first one's leftovers.
#
# `git clean -fd` without -x deliberately: dependency directories are gitignored, and
# wiping them every iteration would mean a fresh install every iteration.
exec_sync_down() {
  if ! _sbx_sh "git fetch --quiet origin && git reset --quiet --hard $1 && git clean -qfd" >/dev/null 2>&1; then
    warn "   could not sync the sandbox to $1 — stopping before spending anything."
    return 1
  fi
}

# Read-only: is the sandbox's clone dirty right now? No side effects — unlike exec_collect,
# it never bundles or brings commits back. What the loop asks before every exec_sync_down,
# so a hard reset never runs over work nobody has looked at yet.
exec_tree_dirty() {
  [ -n "$(_sbx_sh 'git status --porcelain 2>/dev/null' 2>/dev/null | tr -d '\r')" ]
}

exec_collect() {
  local base="$1"

  EXEC_AGENT_HEAD="$(_sbx_sh 'git rev-parse HEAD 2>/dev/null' 2>/dev/null | tr -d '\r' | head -1)"
  EXEC_DIRTY=0
  [ -z "$(_sbx_sh 'git status --porcelain 2>/dev/null' 2>/dev/null | tr -d '\r' | head -1)" ] || EXEC_DIRTY=1

  if [ -z "$EXEC_AGENT_HEAD" ] || [ "$EXEC_AGENT_HEAD" = "$base" ]; then
    return 0    # the agent committed nothing; there is nothing to bring back
  fi
  _sbx_sync_up "$base" "$EXEC_AGENT_HEAD"
}

# Brings base..sandbox-HEAD onto the current branch. Returns 1 if anything went wrong, so
# the caller can stop rather than silently losing an iteration's work.
_sbx_sync_up() {
  local base="$1" sb_head="$2"

  rm -f "$BUNDLE_FILE"
  if ! _sbx_sh "rm -f /tmp/ralph-iter.bundle && git bundle create /tmp/ralph-iter.bundle ${base}..HEAD" >/dev/null 2>&1; then
    warn "   could not bundle the sandbox's commits"
    return 1
  fi
  if ! sbx cp "$RALPH_SANDBOX:/tmp/ralph-iter.bundle" "$BUNDLE_FILE" </dev/null >/dev/null 2>&1; then
    warn "   could not copy the bundle out of the sandbox"
    return 1
  fi
  if ! git fetch --quiet "$BUNDLE_FILE" "HEAD:refs/ralph/incoming" 2>/dev/null; then
    warn "   bundle did not contain a fetchable ref"
    return 1
  fi
  if ! git merge --quiet --ff-only refs/ralph/incoming >/dev/null 2>&1; then
    warn "   could not fast-forward onto the sandbox's commits (diverged?)"
    return 1
  fi
  git update-ref -d refs/ralph/incoming 2>/dev/null || true
  rm -f "$BUNDLE_FILE"

  [ "$(git rev-parse HEAD)" = "$sb_head" ]
}

exec_show_dirty() {
  _sbx_sh 'git status --short' >&2
  warn ""
  warn "They are in the sandbox's clone, not in this repo, and rerunning would reset"
  warn "the clone over them. Inspect with: sbx exec $RALPH_SANDBOX git diff"
}

exec_recovery_note() {
  warn "The sandbox committed $EXEC_AGENT_HEAD but it could not be brought back to this repo."
  warn "That work exists ONLY in the sandbox. Do not rerun until it is recovered:"
  _sbx_recover_bundle_lines "$1" >&2
}

# A different failure from exec_recovery_note above: here nothing was ever committed, so
# there is nothing yet for the bundle transport to move. Commit it in the sandbox first,
# then bring it out the same way _sbx_sync_up does for commits the agent made itself.
exec_dirty_recovery_note() {
  local base="$1" ticket="$2" batch="$3"
  printf '%s\n' \
    "  sbx exec $RALPH_SANDBOX git add -A" \
    "  sbx exec $RALPH_SANDBOX git commit -m 'wip: $ticket — remaining: <what is left>'"
  _sbx_recover_bundle_lines "$base"
  printf '  %s run %s\n' "$RALPH_INVOKE" "$batch"
}

# Only this arrangement makes an uncommitted change a *lost* change.
exec_commit_note() {
  printf '%s' "Commit everything. You are on a private clone of the repository; committing to the
   current branch is how the work gets back to the host, so an uncommitted change is a
   lost change. Do not push."
}
