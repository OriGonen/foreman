#!/bin/bash
# Where is the repository, and where is the batch inside it?
# Sourced by ralph-config.sh, ralph-init.sh and ralph-doctor.sh — never run.
#
# This exists because path syntax on Windows is a minefield and every tool here has to
# cross it identically:
#
#   git rev-parse --show-toplevel   answers C:/Projects/x
#   pwd                             answers /c/Projects/x
#   a Git Bash mount alias          makes /tmp/... and /c/Users/.../Temp/... the same
#                                   directory reached by two different-looking paths
#
# So string-comparing an absolute batch path against an absolute repo path is wrong, and
# `realpath --relative-to` between two of those spellings hands back the absolute path
# instead of failing. Both were real bugs.
#
# The fix is to stop doing arithmetic on paths and let git answer:
# `git rev-parse --show-prefix`, run from inside the batch, IS the repo-relative path.

# Absolute path of the repository containing the current directory, normalised through
# cd+pwd so it is in the shell's own path syntax. Prints nothing and returns 1 if there is
# no repository here.
ralph_repo_root() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  (cd "$top" 2>/dev/null && pwd) || return 1
}

# The repo-relative path of $1, or "." for the repo root itself.
#
# Returns 1 and prints nothing when $1 is not a directory, 2 when it is not inside the
# repository whose root is $2. The caller writes the error message, because ralph-init and
# ralph-config want to say different things about it.
ralph_batch_relpath() {
  local given="$1" repo_root="$2" prefix batch_top
  [ -d "$given" ] || return 1

  # Both of these are asked from INSIDE the batch directory, so git resolves the alias,
  # the symlink and the drive-letter spelling for us.
  prefix="$(cd "$given" 2>/dev/null && git rev-parse --show-prefix 2>/dev/null)" || return 2
  batch_top="$(cd "$given" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || return 2

  # A directory inside a *different* repository would also yield a prefix, so check that
  # the repository git found is the one we are working in. Both sides go through the same
  # cd+pwd normalisation, which is what makes the comparison meaningful.
  batch_top="$(cd "$batch_top" 2>/dev/null && pwd)" || return 2
  [ "$batch_top" = "$repo_root" ] || return 2

  prefix="${prefix%/}"
  printf '%s' "${prefix:-.}"
}

# Every directory under $1 (default: the current directory) that has a ralph.conf in it,
# one per line, relative to $1 and sorted. This is "which directories are ralph batches" —
# the one answer both ralph-config.sh (bash) and ralph-report.cjs (shelling out to this
# function) use, so an omitted batch means the same thing everywhere.
#
# Skips dependency trees, git internals, and the worktrees Claude Code creates (each of
# which contains a full copy of every batch).
ralph_find_batches() {
  local root="${1:-.}"
  (
    cd "$root" 2>/dev/null || return 1
    find . \
      \( -name node_modules -o -name .git -o -path './.claude/worktrees' -o -name .svelte-kit \) -prune \
      -o -name ralph.conf -print 2>/dev/null |
      sed 's|^\./||; s|/ralph\.conf$||' | sort
  )
}
