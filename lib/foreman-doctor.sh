#!/bin/bash
# Is this repository — and this machine — ready to run foreman?
#
#   foreman doctor          report; exit 0 if ready, 1 if something must be fixed
#   foreman doctor --fix    also append the .gitignore / .gitattributes lines this repo needs
#
# Costs nothing and starts no sandbox. It reports on three things:
#
#   the machine   git, node, awk, bash 4+, and either `sbx` or `claude` depending on the
#                 execution mode the batches here ask for
#   this repo     the two files a repo must add itself: .gitignore, so a batch's run logs
#                 and its transient bundle stay untracked, and .gitattributes, so a
#                 foreman.conf sourced as bash is not checked out with CRLF
#   the batches   every directory here with a foreman.conf, and how far each one has got
#
# --fix only ever APPENDS to .gitignore and .gitattributes. It never touches a batch, a
# ticket, or anything already in those files.
#
# It also warns, for free and without affecting the exit code, when install.sh's copy of
# the foreman-human-followup-tickets skill has drifted from this checkout's — silent
# whenever there is nothing installed, or it still matches.
set -uo pipefail

# This file's directory, from the shell and not `dirname` (see foreman-config.sh).
FOREMAN_TOOL_DIR="${BASH_SOURCE[0]%/*}"; [ "$FOREMAN_TOOL_DIR" != "${BASH_SOURCE[0]}" ] || FOREMAN_TOOL_DIR=.
FOREMAN_TOOL_DIR="$(cd "${FOREMAN_TOOL_DIR:-/}" && pwd)"

FIX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fix)     FIX=1 ;;
    --help|-h) awk 'NR==1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *)         echo "Usage: foreman doctor [--fix]" >&2; exit 1 ;;
  esac
  shift
done

# doctor has to work in a repo with no batch at all — that is the point of running it
# before `foreman init`. So it does NOT source foreman-config.sh, which resolves a batch and
# fails without one. It shares the path resolution instead, which is the part that has to
# agree.
# shellcheck source=foreman-repo.sh
source "$FOREMAN_TOOL_DIR/foreman-repo.sh" || {
  echo "foreman doctor: cannot load $FOREMAN_TOOL_DIR/foreman-repo.sh" >&2; exit 1; }

# Which command a batch's execution mode needs is the adapter's business, not doctor's.
# shellcheck source=foreman-exec.sh
source "$FOREMAN_TOOL_DIR/foreman-exec.sh" || {
  echo "foreman doctor: cannot load $FOREMAN_TOOL_DIR/foreman-exec.sh" >&2; exit 1; }

foreman_repo_root REPO_ROOT || {
  echo "foreman doctor: not inside a git repository." >&2
  echo "              A batch lives in a repo, because each iteration commits its work." >&2
  exit 1
}
cd "$REPO_ROOT" || exit 1
FOREMAN_HOME="${FOREMAN_HOME:-$(cd "$FOREMAN_TOOL_DIR/.." && pwd)}"
FOREMAN_INVOKE="${FOREMAN_INVOKE:-$FOREMAN_HOME/bin/foreman}"

problems=0
fixable=0

ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  MISS  %s\n' "$*"; problems=$((problems + 1)); }
note() { printf '        %s\n' "$*"; }
# Like bad(), but never touches $problems — for something worth flagging that is not a
# reason to fail the exit code (the skill-copy staleness check is the one user of this).
warn() { printf '  STALE %s\n' "$*"; }

echo "foreman doctor"
echo "  toolkit  $FOREMAN_HOME ($(git -C "$FOREMAN_HOME" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout'))"
echo "  repo     $REPO_ROOT"
echo

# ---------------------------------------------------------------------------
# The machine
# ---------------------------------------------------------------------------
echo "Machine"
for tool in git node awk; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool"; else bad "$tool is not on PATH"; fi
done

# foreman-config.sh uses associative arrays and `compgen -v`, both of which need bash 4.
if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
  ok "bash ${BASH_VERSION%%(*} (4+ required)"
else
  bad "bash ${BASH_VERSION:-?} is too old — 4+ is required for associative arrays"
fi

# ---------------------------------------------------------------------------
# Which batches are here, and therefore which agent runner matters.
# Same prune list as foreman-config.sh: .claude/worktrees holds full copies of the repo, so
# without it every batch would be reported once per worktree.
# ---------------------------------------------------------------------------
batches=$(find . \
  \( -name node_modules -o -name .git -o -path './.claude/worktrees' -o -name .svelte-kit \) -prune \
  -o \( -name foreman.conf -o -name ralph.conf \) -print 2>/dev/null |
  sed 's|^\./||; s|/foreman\.conf$||; s|/ralph\.conf$||' | sort -u)   # legacy: ralph.conf

# The last assignment of a scalar FOREMAN_* in a conf, unquoted. doctor deliberately does not
# source foreman-config.sh (it has to work in a repo with no batch at all), and it must not
# source a batch's foreman.conf either — that file is arbitrary bash. Reading it as text is
# the compromise: enough to spot a misconfiguration, never enough to be affected by one.
# legacy: a conf from before the rename spells the knob RALPH_*, and that still counts.
_conf_value() {
  grep -E "^[[:space:]]*(FOREMAN|RALPH)_${2#FOREMAN_}=" "$1" 2>/dev/null | tail -1 | sed 's/[^=]*=//' | tr -d '"'"'"'\r'
}

# Ask each batch's adapter what it needs on PATH, and check the union. One line per tool,
# "<tool> <the mode that asked for it>". A batch in a mode that needs nothing (fake)
# contributes nothing; a repo with no batch at all is judged on the default mode.
runners=""
_want_runner() {
  local mode="$1" tool
  if ! tool=$(foreman_exec_required_tool "$mode"); then
    bad "FOREMAN_EXEC=$mode in ${2:-this repo} — no such execution mode"
    note "valid modes: $(foreman_exec_modes | tr '\n' ' ')"
    return
  fi
  [ -n "$tool" ] || return
  case $'\n'"$runners" in *$'\n'"$tool "*) return ;; esac
  runners="$runners$tool $mode"$'\n'
}

if [ -n "$batches" ]; then
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    foreman_legacy_conf_path conf "$b" 2>/dev/null
    mode=$(_conf_value "$conf" FOREMAN_EXEC)
    _want_runner "${mode:-sandbox}" "$conf"
  done <<< "$batches"
else
  _want_runner sandbox
fi

while IFS=' ' read -r tool mode; do
  [ -n "$tool" ] || continue
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool (required by FOREMAN_EXEC=$mode)"
  else
    bad "$tool is not on PATH, and FOREMAN_EXEC=$mode needs it"
    [ "$tool" = sbx ] && note "set FOREMAN_EXEC=local in that batch's foreman.conf to run without one"
  fi
done <<< "$runners"
echo

# ---------------------------------------------------------------------------
# The installed skill copy, if install.sh put one on this machine. Free (no exit-code
# change) and silent unless it has drifted from this checkout — install.sh always
# replaces a marked copy wholesale, so drift only means the checkout moved on since.
# Matches install.sh's own marker file and CLAUDE_CONFIG_DIR default exactly.
# ---------------------------------------------------------------------------
_foreman_skill_name="foreman-human-followup-tickets"
_foreman_skill_marker=".foreman-installed-from"
_foreman_skill_copy="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/$_foreman_skill_name"
_foreman_skill_src="$FOREMAN_HOME/skills/$_foreman_skill_name"
if [ -f "$_foreman_skill_copy/$_foreman_skill_marker" ] &&
   ! diff -rq -x "$_foreman_skill_marker" "$_foreman_skill_src" "$_foreman_skill_copy" >/dev/null 2>&1; then
  echo "Skill"
  warn "$_foreman_skill_name — installed copy differs from $_foreman_skill_src"
  note "run: bash $FOREMAN_HOME/install.sh"
  echo
fi

# ---------------------------------------------------------------------------
# The two files a consuming repo has to provide itself
# ---------------------------------------------------------------------------
echo "Repository"

# `read -d ''` returns non-zero when it hits EOF without finding the delimiter, which is
# every time here. That is expected; the variable is still set. `set -e` is deliberately
# not in force in this toolkit, so it does not abort.
read -r -d '' GITIGNORE_BLOCK <<'BLOCK'

# Foreman: per-batch run state. Every one of these lives in the batch directory, which is
# why the patterns match anywhere rather than under one directory — a batch is any
# directory with a foreman.conf.
#
# The git bundle an iteration's commits travel in, from the sandbox's clone back to this
# repo. Written and deleted within one iteration.
**/.foreman-iter.bundle

# The marker a run leaves when a stall could not be salvaged, so that a rerun may rescue the
# tree instead of refusing it. Disposable: deleting it only costs the automatic rescue. It
# has to stay untracked, or the checkpoint commit that rescues the work would sweep it in.
**/.foreman-stall-marker

# Append-only run telemetry. Untracked deliberately — the loop appends to these after each
# iteration, so tracking them would put unrelated churn in every ticket's commit.
# Inspect with `foreman report <batch>`.
**/foreman-runs.jsonl
**/foreman-runs.log
BLOCK

read -r -d '' GITATTRIBUTES_BLOCK <<'BLOCK'

# Foreman: foreman.conf is sourced by bash, so a CRLF checkout would append a carriage return
# to every value it sets — FOREMAN_EXEC would become "sandbox<CR>" and fail validation with
# a message that looks like a lie.
foreman.conf text eol=lf
BLOCK

missing_ignore=0
for pat in '**/.foreman-iter.bundle' '**/.foreman-stall-marker' '**/foreman-runs.jsonl' '**/foreman-runs.log'; do
  if grep -qxF "$pat" .gitignore 2>/dev/null; then
    ok ".gitignore  $pat"
  else
    missing_ignore=$((missing_ignore + 1))
    bad ".gitignore  $pat"
  fi
done

# The attribute only matters where git rewrites line endings in the first place.
needs_attr=0
grep -qE '^\*[[:space:]]+text=auto' .gitattributes 2>/dev/null && needs_attr=1
[ "$(git config --get core.autocrlf 2>/dev/null)" = "true" ] && needs_attr=1

if [ "$needs_attr" -eq 1 ]; then
  if grep -qE '^foreman\.conf[[:space:]]+text[[:space:]]+eol=lf' .gitattributes 2>/dev/null; then
    ok ".gitattributes  foreman.conf text eol=lf"
  else
    bad ".gitattributes  foreman.conf text eol=lf"
    note "this repo rewrites line endings, so a tracked foreman.conf would come back CRLF"
    needs_attr=2
  fi
else
  ok ".gitattributes  not needed (this repo does not rewrite line endings)"
fi

if [ "$missing_ignore" -gt 0 ] || [ "$needs_attr" -eq 2 ]; then fixable=1; fi

if [ "$fixable" -eq 1 ] && [ "$FIX" -eq 1 ]; then
  echo
  if [ "$missing_ignore" -gt 0 ]; then
    printf '%s\n' "$GITIGNORE_BLOCK" >> .gitignore
    echo "  wrote  .gitignore  (+$missing_ignore pattern(s))"
    problems=$((problems - missing_ignore))
  fi
  if [ "$needs_attr" -eq 2 ]; then
    printf '%s\n' "$GITATTRIBUTES_BLOCK" >> .gitattributes
    echo "  wrote  .gitattributes"
    problems=$((problems - 1))
  fi
  echo "  Review the diff and commit it — these are the only files foreman asks a repo for."
fi
echo

# ---------------------------------------------------------------------------
# The batches
# ---------------------------------------------------------------------------
# Can this batch's agent commit at all?
#
# Only `local` is asked. The sandbox modes default to bypassPermissions, where the question
# does not arise, and `fake` runs no agent. In `local` the default is acceptEdits, which
# covers Edit and Write but leaves Bash to the settings allowlist — and `claude --print` has
# no approver, so a `git commit` that is not allowlisted is denied outright. The ticket's
# work still happens, and still costs; only the landing fails. This check is the difference
# between finding that out here at $0 and finding it out after three tickets.
_check_can_commit() {
  local conf="$1" mode="$2" perm args
  [ "$mode" = local ] || return 0

  perm="$(_conf_value "$conf" FOREMAN_PERMISSION_MODE)"
  case "$perm" in bypassPermissions|dontAsk|auto) return 0 ;; esac

  args="$(grep -E '^[[:space:]]*FOREMAN_CLAUDE_ARGS=' "$conf" 2>/dev/null | tail -1)"
  case "$args" in *"git commit"*|*"--dangerously-skip-permissions"*) return 0 ;; esac

  bad "$conf — FOREMAN_EXEC=local with no way for the agent to commit"
  note "acceptEdits does not cover Bash, and \`claude --print\` cannot ask anyone."
  note "Add to that file:"
  note "  FOREMAN_CLAUDE_ARGS=(--allowed-tools \"Bash(git add:*)\" \"Bash(git commit:*)\")"
}

echo "Batches"
if [ -z "$batches" ]; then
  echo "  none — no directory here has a foreman.conf."
  echo "  Create one:  $FOREMAN_INVOKE init <batch-dir>"
else
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if counts=$(bash "$FOREMAN_TOOL_DIR/foreman-next.sh" "$b" --count 2>/dev/null); then
      printf '  %-40s %s of %s done\n' "$b" "${counts% *}" "${counts#* }"
    else
      printf '  %-40s (order unreadable — run: %s status %s)\n' "$b" "$FOREMAN_INVOKE" "$b"
    fi
    foreman_legacy_conf_path conf "$b" 2>/dev/null
    _check_can_commit "$conf" "$(_conf_value "$conf" FOREMAN_EXEC)"
  done <<< "$batches"
fi
echo

# ---------------------------------------------------------------------------
# legacy: what is left from before the rename from ralph. Warnings only — all of it still
# works for now (see foreman-legacy.sh) — and silent when there is nothing left.
# ---------------------------------------------------------------------------
_legacy_lines=()
while IFS= read -r b; do
  [ -n "$b" ] && [ -f "$b/ralph.conf" ] || continue
  if [ -f "$b/foreman.conf" ]; then
    _legacy_lines+=("$b has both foreman.conf and ralph.conf — foreman.conf is used; delete ralph.conf")
  else
    _legacy_lines+=("$b/ralph.conf — rename it:  git mv \"$b/ralph.conf\" \"$b/foreman.conf\"")
  fi
done <<< "$batches"
while IFS= read -r b; do
  [ -n "$b" ] || continue
  foreman_legacy_conf_path conf "$b" 2>/dev/null
  ! grep -qE '^[[:space:]]*RALPH_[A-Z_]+=' "$conf" 2>/dev/null ||
    _legacy_lines+=("$conf sets RALPH_* knobs — rename each to FOREMAN_* (same name, new prefix)")
done <<< "$batches"
_legacy_env=$(compgen -v RALPH_ 2>/dev/null | tr '\n' ' ')
[ -z "$_legacy_env" ] || _legacy_lines+=("the environment sets ${_legacy_env% } — rename each to FOREMAN_*")
_legacy_skill="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/ralph-human-followup-tickets"
[ ! -f "$_legacy_skill/.ralph-installed-from" ] ||
  _legacy_lines+=("old skill copy at $_legacy_skill — run: bash $FOREMAN_HOME/install.sh (it removes it)")
! grep -qE '(^|/)\.?ralph-' .gitignore 2>/dev/null ||
  _legacy_lines+=(".gitignore still lists ralph-* files; those lines can go once the foreman-* ones are in")
if [ ${#_legacy_lines[@]} -gt 0 ]; then
  echo "From before the rename to Foreman"
  for _l in "${_legacy_lines[@]}"; do warn "$_l"; done
  case "$runners" in *sbx*)
    _foreman_basename _legacy_repo "$PWD"
    note "the default sandbox is now foreman-$_legacy_repo; an old one can go:  sbx rm ralph-$_legacy_repo"
  ;; esac
  echo
fi

if [ "$problems" -gt 0 ]; then
  if [ "$fixable" -eq 1 ] && [ "$FIX" -eq 0 ]; then
    echo "$problems thing(s) to fix. The repo files can be written for you:"
    echo "  $FOREMAN_INVOKE doctor --fix"
  else
    echo "$problems thing(s) still need fixing by hand."
  fi
  exit 1
fi

echo "Ready."
exit 0
