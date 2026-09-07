#!/bin/bash
# Shared implementation for the two `sbx` adapters. Not a mode — the leading underscore
# keeps it out of `ralph_exec_modes`.
#
# What differs between them is the arrangement of the workspace (a private clone versus a
# bind mount of this working tree) and therefore how commits come back. Creating the
# sandbox, running the agent in it, and the readiness probe are identical.

_sbx_sh() { sbx exec "$RALPH_SANDBOX" sh -c "$1"; }

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
  warn "preflight: this is a linked worktree ($REPO_ROOT)."
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

  warn "preflight: the sandbox is not ready — this probe still fails:"
  warn "             $RALPH_SANDBOX_PROBE"
  warn "           Every iteration's verification step would fail the same way, so"
  warn "           nothing has been spent. Diagnose with:"
  [ -n "$RALPH_SANDBOX_SETUP" ] && warn "             sbx exec $RALPH_SANDBOX sh -c '$RALPH_SANDBOX_SETUP'"
  warn "             sbx exec $RALPH_SANDBOX sh -c '$RALPH_SANDBOX_PROBE'"
  warn "           Override with RALPH_SKIP_SANDBOX_PROBE=1 if you know better."
  return 1
}

exec_required_tool() { printf 'sbx'; }

exec_run() {
  sbx run claude --name "$RALPH_SANDBOX" -- \
    --model "$RALPH_MODEL" --effort "$RALPH_EFFORT" --permission-mode "$RALPH_PERMISSION_MODE" \
    ${RALPH_CLAUDE_ARGS+"${RALPH_CLAUDE_ARGS[@]}"} \
    --print --output-format json -p "$1"
}

exec_preflight() { _sbx_preflight; }
