#!/bin/bash
# Where is the repository, and where is the batch inside it?
# Sourced by foreman-config.sh, foreman-init.sh and foreman-doctor.sh — never run.
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

# legacy: compatibility with batches from before the rename from ralph. Everything that
# sources this file needs it, so it is loaded here rather than by each of them.
# shellcheck source=foreman-legacy.sh
source "${BASH_SOURCE[0]%/*}/foreman-legacy.sh" || return 1

# `basename` and `dirname` without the process, and without the subshell a caller needs to
# read what a command prints: each sets the variable named by its first argument. They answer
# as the commands do — trailing separators are ignored, a name with none has the directory `.`,
# and a lone separator is its own base name and directory — so they can stand in anywhere. On
# Windows the commands cut at a backslash as well as a slash (a FOREMAN_RUN_LOG may be `C:\x\y`),
# so these do too.
#   _foreman_basename VAR PATH      VAR = PATH without its directory
#   _foreman_dirname  VAR PATH      VAR = PATH without its last component
case "${OSTYPE:-}" in
  msys*|cygwin*|win32*) _foreman_seps='\/' ;;
  *)                    _foreman_seps='/' ;;
esac
_foreman_trim_seps() {    # _foreman_trim_seps VAR VALUE: VAR = VALUE without trailing separators, bar a lone one
  local _rt="$2"
  while [ "${#_rt}" -gt 1 ] && [ "${_rt%["$_foreman_seps"]}" != "$_rt" ]; do _rt="${_rt%["$_foreman_seps"]}"; done
  printf -v "$1" '%s' "$_rt"
}
_foreman_basename() {
  local _rp
  _foreman_trim_seps _rp "$2"
  case "$_rp" in ["$_foreman_seps"]) ;; *) _rp="${_rp##*["$_foreman_seps"]}" ;; esac
  printf -v "$1" '%s' "$_rp"
}
_foreman_dirname() {
  local _rp
  _foreman_trim_seps _rp "$2"
  case "$_rp" in
    ["$_foreman_seps"]) ;;
    *["$_foreman_seps"]*) _foreman_trim_seps _rp "${_rp%["$_foreman_seps"]*}"
                        [ -n "$_rp" ] || _rp="${2:0:1}" ;;
    *)                  _rp=. ;;
  esac
  printf -v "$1" '%s' "$_rp"
}

# Where the repository is, and where the batch is inside it, are each asked of git once per
# command, and what git answered is kept: in the variable the caller names, which it then uses
# for the rest of the command. Both functions set that variable rather than print, because a
# function that prints is read through a command substitution, which forks; and both move
# through directories with the shell's own `cd` (restoring where they started) rather than in
# a subshell. Git itself still takes a `$( )` to be read, so each answer costs one fork.

# foreman_repo_root VAR
# VAR = absolute path of the repository containing the current directory, normalised through
# cd+pwd so it is in the shell's own path syntax. Returns 1, setting nothing, if there is no
# repository here.
foreman_repo_root() {
  local _rr_top _rr_here="$PWD"
  _rr_top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  cd "$_rr_top" 2>/dev/null || return 1
  _rr_top="$PWD"
  cd "$_rr_here" || return 1
  printf -v "$1" '%s' "$_rr_top"
}

# foreman_batch_relpath VAR GIVEN ROOT
# VAR = the repo-relative path of GIVEN, or "." for the repo root itself.
#
# Returns 1, setting nothing, when GIVEN is not a directory, 2 when it is not inside the
# repository whose root is ROOT. The caller writes the error message, because foreman-init and
# foreman-config want to say different things about it.
#
# `--show-toplevel` is asked from two places, because they are two questions: of
# foreman_repo_root, from where the command stands (which repository are we working in?), and
# here, from inside the batch (which repository is the batch in?). Answering the second from
# the first would lose the check that a batch in a different repository is refused. What this
# function asks is one git process: the batch's `--show-toplevel` and `--show-prefix` together.
foreman_batch_relpath() {
  local _rb_given="$2" _rb_root="$3" _rb_here="$PWD" _rb_answer _rb_top _rb_prefix="" _rb_rc=0
  [ -d "$_rb_given" ] || return 1

  # Both answers are asked from INSIDE the batch directory, so git resolves the alias, the
  # symlink and the drive-letter spelling for us. (`git` prints the prefix as an empty line
  # at the top of the repository, which the `$( )` trims away.)
  CDPATH= cd "$_rb_given" 2>/dev/null || return 2
  if _rb_answer="$(git rev-parse --show-toplevel --show-prefix 2>/dev/null)"; then
    case "$_rb_answer" in
      *$'\n'*) _rb_top="${_rb_answer%%$'\n'*}"; _rb_prefix="${_rb_answer#*$'\n'}" ;;
      *)       _rb_top="$_rb_answer" ;;
    esac
    # A directory inside a *different* repository would also yield a prefix, so check that
    # the repository git found is the one we are working in. Both sides go through the same
    # cd+pwd normalisation, which is what makes the comparison meaningful.
    if cd "$_rb_top" 2>/dev/null; then _rb_top="$PWD"; else _rb_rc=2; fi
    [ "$_rb_top" = "$_rb_root" ] || _rb_rc=2
  else
    _rb_rc=2
  fi
  cd "$_rb_here" || return 2
  [ "$_rb_rc" = 0 ] || return "$_rb_rc"

  _rb_prefix="${_rb_prefix%/}"
  printf -v "$1" '%s' "${_rb_prefix:-.}"
}

# Every directory under $1 (default: the current directory) that has a foreman.conf in it,
# one per line, relative to $1 and sorted. This is "which directories are foreman batches" —
# the one answer both foreman-config.sh (bash) and foreman-report.cjs (shelling out to this
# function) use, so an omitted batch means the same thing everywhere.
#
# Skips dependency trees, git internals, and the worktrees Claude Code creates (each of
# which contains a full copy of every batch). Also skips finished batches — directories
# the loop renamed with FOREMAN_DONE_PREFIX (DONE_foo) — so a batch left lying around after
# it finished cannot make an omitted <batch> ambiguous. Name one explicitly to still use it.
# The prefix is read from the environment only: this runs before any batch's foreman.conf is
# known, so a prefix set there cannot apply.
#
# legacy: a ralph.conf makes a batch too, from before the rename (see foreman-legacy.sh).
foreman_find_batches() {
  local root="${1:-.}" prefix="${FOREMAN_DONE_PREFIX-DONE_}"
  local -a skip_done=()
  [ -z "$prefix" ] || skip_done=( -o -type d -name "${prefix//[\\*?[]/\\&}*" )
  (
    cd "$root" 2>/dev/null || return 1
    find . \
      \( -name node_modules -o -name .git -o -path './.claude/worktrees' -o -name .svelte-kit "${skip_done[@]}" \) -prune \
      -o \( -name foreman.conf -o -name ralph.conf \) -print 2>/dev/null |
      sed 's|^\./||; s|/foreman\.conf$||; s|/ralph\.conf$||' | sort -u
  )
}
