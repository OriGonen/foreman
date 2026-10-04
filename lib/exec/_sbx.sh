#!/bin/bash
# Shared implementation for the two `sbx` adapters. Not a mode — the leading underscore
# keeps it out of `ralph_exec_modes`.
#
# What differs between them is the arrangement of the workspace (a private clone versus a
# bind mount of this working tree) and therefore how commits come back. Creating the
# sandbox, running the agent in it, and the readiness probe are identical.

# The credentials reader, in lib/ (from the shell, not `dirname`; see
# ralph-config.sh).
_sbx_dir="${BASH_SOURCE[0]%/*}"; [ "$_sbx_dir" != "${BASH_SOURCE[0]}" ] || _sbx_dir=.
# shellcheck source=../ralph-credentials.sh
source "$_sbx_dir/../ralph-credentials.sh" || return 1

# Never the terminal on stdin: nothing run this way reads it, and a `sbx exec` that forwarded
# it could swallow a key meant for ralph-keys.sh between iterations.
_sbx_sh() { sbx exec "$RALPH_SANDBOX" sh -c "$1" </dev/null; }

_SBX_SOURCE_MOUNT=/run/sandbox/source

# `--clone` mounts the host repo read-only at $_SBX_SOURCE_MOUNT and clones it. The MOUNT is
# the invariant; origin is not — sbx only adds origin=$_SBX_SOURCE_MOUNT when the host repo
# has no origin of its own, so a repo with a real GitHub remote keeps that URL in the clone
# and this check used to reject a correctly-created clone sandbox.
_sbx_is_clone_mode() {
  [ "$(_sbx_sh "[ -d $_SBX_SOURCE_MOUNT ] && echo clone" 2>/dev/null | tr -d '\r' | head -1)" = clone ]
}

# Point the clone's origin at the read-only host mount. exec_sync_down fetches through
# `origin` every iteration, and this is also what keeps a stray `git push` inside the sandbox
# rather than on the real upstream. Idempotent; verified rather than assumed, because a
# silent failure here would surface as an unexplained reset failure mid-iteration.
_sbx_point_origin_at_source() {
  _sbx_sh "git remote set-url origin $_SBX_SOURCE_MOUNT 2>/dev/null ||
           git remote add origin $_SBX_SOURCE_MOUNT" >/dev/null 2>&1
  [ "$(_sbx_sh 'git remote get-url origin 2>/dev/null' 2>/dev/null | tr -d '\r' | head -1)" \
    = "$_SBX_SOURCE_MOUNT" ]
}

# `sbx create` acts on the repository at REPO_ROOT. In a linked worktree that path has a
# `.git` *file* pointing elsewhere rather than a repository, so neither the clone nor the
# mount is the thing anyone means.
_sbx_preflight() {
  [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ] || return 0
  warn_preflight "this is a linked worktree ($REPO_ROOT)."
  warn "           The sandbox acts on the repository at this path, and a worktree's .git"
  warn "           is a file pointing outside it. Run the loop from the primary checkout,"
  warn "           on whichever branch you want the batch to land on — or set"
  warn "           RALPH_EXEC=local in $RALPH_CONF."
  return 1
}

# Create the sandbox up front (idempotent — fine if a prior run left it) so every agent
# call reattaches to it instead of creating it: a fresh-create prints a setup banner on
# stdout that would corrupt the --output-format json we parse for usage.
_sbx_create() {
  if [ "$1" = clone ]; then
    sbx create --clone --name "$RALPH_SANDBOX" claude "$REPO_ROOT" >&2 || true
  else
    sbx create --name "$RALPH_SANDBOX" claude "$REPO_ROOT" >&2 || true
  fi
}

# The batch's readiness probe: one command that must succeed inside the sandbox before any
# money is spent. A clone starts with no gitignored dependency directories, so the first
# run of a batch is normally where RALPH_SANDBOX_SETUP earns its place.
_sbx_probe() {
  if [ -z "$RALPH_SANDBOX_PROBE" ] || [ "$RALPH_SKIP_SANDBOX_PROBE" = "1" ]; then
    return 0
  fi
  _sbx_sh "$RALPH_SANDBOX_PROBE" >/dev/null 2>&1 && return 0

  if [ -n "$RALPH_SANDBOX_SETUP" ]; then
    say "Sandbox setup (the readiness probe failed — this is normal on a fresh clone)…"
    _sbx_sh "$RALPH_SANDBOX_SETUP" >&2 || true
  fi
  _sbx_sh "$RALPH_SANDBOX_PROBE" >/dev/null 2>&1 && return 0

  warn_preflight "the sandbox is not ready — this probe still fails:"
  warn "             $RALPH_SANDBOX_PROBE"
  warn "           Every iteration's verification step would fail the same way, so"
  warn "           nothing has been spent. Diagnose with:"
  [ -n "$RALPH_SANDBOX_SETUP" ] && warn "             sbx exec $RALPH_SANDBOX sh -c '$RALPH_SANDBOX_SETUP'"
  warn "             sbx exec $RALPH_SANDBOX sh -c '$RALPH_SANDBOX_PROBE'"
  warn "           Override with RALPH_SKIP_SANDBOX_PROBE=1 if you know better."
  return 1
}

exec_required_tool() { printf 'sbx'; }

# The container is the boundary, so the permission gate protects nothing that the sandbox
# does not already protect — and under `claude --print` there is no approver, so a
# non-allowlisted `git commit` is denied outright, after the ticket's work is done and paid
# for. Both sbx modes; an explicit RALPH_PERMISSION_MODE still wins.
exec_default_permission_mode() { printf 'bypassPermissions'; }

# Verified against a real sandbox, not assumed: `sbx run … -- <flags>` delivers them to
# claude verbatim — omitting --verbose gets the CLI's own refusal of stream-json, which is a
# rule only claude knows — and under stream-json sbx prefixes its OSC title sequence to the
# FIRST JSON object rather than putting it on a line of its own. ralph-stream.cjs strips per
# line before testing for `{`, so that line parses; the banner's other lines are dropped.
#
# What sbx does NOT forward is the agent's own error text: a claude that fails to start
# yields sbx's banner and `ERROR: agent exited with code 1` and nothing else. That is why
# the filter keeps a tail when no result object ever arrives.
exec_run() {
  ralph_exec_format_args
  sbx run claude --name "$RALPH_SANDBOX" -- \
    --model "$RALPH_MODEL" --effort "$RALPH_EFFORT" --permission-mode "$RALPH_PERMISSION_MODE" \
    ${RALPH_CLAUDE_ARGS+"${RALPH_CLAUDE_ARGS[@]}"} \
    --print "${RALPH_EXEC_FORMAT_ARGS[@]}" -p "$1"
}

# Sign in to Docker without a browser, when asked to. `sbx` signs out on its own schedule and
# its first command after that starts an interactive device-code flow — which, run unattended,
# is a stall rather than a prompt. With RALPH_DOCKER_USERNAME and RALPH_DOCKER_PAT to hand,
# log in with a Docker access token first; `sbx login` is idempotent, so doing it every run
# costs one call and removes the question of whether the session is still live.
#
# Both come from the credentials file (~/.config/ralph/env; see ralph-credentials.sh) or,
# winning over it, the environment — never ralph.conf: that file is checked into the batch's
# repository, and the token is a credential. They are read into locals and ralph never
# exports them, and the token travels on stdin, so it is on no command line and in no process
# listing. Either missing means nothing changes from before.
_sbx_login() {
  local user pat out
  user="$(ralph_credential RALPH_DOCKER_USERNAME)"
  pat="$(ralph_credential RALPH_DOCKER_PAT)"
  [ -n "$user" ] && [ -n "$pat" ] || return 0
  if out=$(printf '%s' "$pat" | sbx login --username "$user" --password-stdin 2>&1); then
    return 0
  fi
  warn_preflight "could not sign in to Docker as '$user' with RALPH_DOCKER_PAT."
  warn "           The token may be revoked or mistyped. sbx said:"
  printf '%s\n' "$out" | sed 's/^/             /' >&2
  return 1
}

exec_preflight() { _sbx_login && _sbx_preflight; }

# The commands that get a range of commits out of the sandbox's clone and onto this
# branch — one source of truth for the two recovery notes that both need it (stranded
# commits in sandbox.sh's exec_recovery_note, and an uncommitted stall in its
# exec_dirty_recovery_note), so the transport steps cannot drift apart between them.
_sbx_recover_bundle_lines() {
  local base="$1"
  printf '%s\n' \
    "  sbx exec $RALPH_SANDBOX git bundle create /tmp/recover.bundle $base..HEAD" \
    "  sbx cp $RALPH_SANDBOX:/tmp/recover.bundle ./recover.bundle" \
    "  git fetch ./recover.bundle HEAD:refs/ralph/recovered && git merge --ff-only refs/ralph/recovered"
}
