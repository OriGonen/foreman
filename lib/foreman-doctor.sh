#!/bin/bash
# Is this repository — and this machine — ready to run foreman?
#
#   foreman doctor          report; exit 0 if ready, 1 if something must be fixed
#   foreman doctor --fix    also append the .gitignore / .gitattributes lines this repo needs
#
# Costs nothing and starts no sandbox. What it finds is drawn as a box, "the site inspection":
# MACHINE and REPOSITORY side by side, then SKILL (when a copy is installed), BATCHES, and
# FROM BEFORE THE RENAME (when something is left), and at the bottom the verdict. On a terminal
# an inspector runs across the top while the checks run, the box filling in as each one completes,
# then he blows a whistle and plants a red sign, or hops and gives a thumbs up beside a check.
# Anywhere else (a pipe, CI, NO_COLOR, a terminal under 80 columns) it is the box alone, once, in
# plain text. The closing advice and what --fix wrote come after the box. It reports on three things:
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
# one of foreman's skills has drifted from this checkout's — silent whenever there is
# nothing installed, or it still matches.
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

# Nothing is printed as it is found. Each check is recorded, as a `key<TAB>value` fact for the
# renderer (foreman-draw.cjs, scene `doctor`), in the order it completes: `check`, its section,
# its state and its words, and for a batch the detail after its name. On the show path each fact
# is also written to the renderer, on file descriptor 3, the moment it exists, so the box fills
# in while the rest are still being checked. SECTION is the section the next checks belong to.
_facts=()
_live=0
SECTION=machine
_fact() {    # _fact LINE
  _facts+=("$1")
  [ "$_live" -eq 0 ] || printf '%s\n' "$1" >&3 2>/dev/null || true
}
_check() {   # _check STATE TEXT [DETAIL]
  _fact "check"$'\t'"$SECTION"$'\t'"$1"$'\t'"$2${3:+$'\t'$3}"
}
ok()   { _check ok "$@"; }
bad()  { _check miss "$*"; problems=$((problems + 1)); }
# A miss that `doctor --fix` writes: it counts the same, and the box says so.
fix()  { _check fix "$*"; problems=$((problems + 1)); }
# More words for the check before it.
note() { _fact "check"$'\t'"$SECTION"$'\tnote\t'"$*"; }
# A line under its section with no mark of its own.
info() { _check info "$*"; }
# Like bad(), but never touches $problems — for something worth flagging that is not a
# reason to fail the exit code (the skill-copy staleness check is the one user of this).
warn() { _check stale "$@"; }

# The facts as lines, one to a check, for when there is nothing to draw them with (no node, or a
# renderer that failed): the headings, then `ok`, `MISS`, `STALE` and the notes, as doctor has
# always printed them.
_doctor_lines() {
  local fact kind section state text detail last="" head
  for fact in "${_facts[@]}"; do
    IFS=$'\t' read -r kind section state text detail <<< "$fact"
    [ "$kind" = check ] || continue
    if [ "$section" != "$last" ]; then
      [ -z "$last" ] || echo
      case "$section" in
        machine) head=Machine ;; repository) head=Repository ;; skill) head=Skill ;;
        batches) head=Batches ;; rename) head="From before the rename to Foreman" ;; *) head="$section" ;;
      esac
      echo "$head"; last="$section"
    fi
    case "$state" in
      ok)         printf '  ok    %s\n' "$text" ;;
      miss|fix)   printf '  MISS  %s\n' "$text" ;;
      stale)      printf '  STALE %s\n' "$text${detail:+  $detail}" ;;
      note)       printf '        %s\n' "$text" ;;
      *)          printf '  %s\n' "$text${detail:+  $detail}" ;;
    esac
    [ "$state" != ok ] || [ -z "$detail" ] || printf '        %s\n' "$detail"
  done
  echo
}

# On the show path the renderer starts first and is written to as the checks complete; the show
# is wanted on a terminal wide enough for the box, not in CI, with node to draw it, and a bash
# that can wait for a process substitution (4.4). Otherwise the box is drawn at the end, plain.
# shellcheck source=foreman-ui.sh
source "$FOREMAN_TOOL_DIR/foreman-ui.sh" 2>/dev/null || true
_doctor_min_cols=80
_doctor_draw="$FOREMAN_TOOL_DIR/foreman-draw.cjs"
_doctor_pid=""
_doctor_restore_cursor() { printf '\033[?25h'; }
if command -v ui_show >/dev/null 2>&1 && ui_show 1 _doctor_tier && ui_cols _doctor_cols 1 &&
   [ "$_doctor_cols" -ge "$_doctor_min_cols" ] && command -v node >/dev/null 2>&1 &&
   { [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; }; then
  # The renderer shows the cursor again on every way out it can take; this is for the ones it
  # cannot (killed, or never started). The writes to a renderer that has gone must fail quietly.
  trap _doctor_restore_cursor EXIT
  trap '' PIPE
  exec 3> >(exec node "$_doctor_draw" doctor --stream --tier "$_doctor_tier" --cols "$_doctor_cols" 2>/dev/null)
  _doctor_pid=$!
  _live=1
fi

_doctor_rev="$(git -C "$FOREMAN_HOME" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
printf -v _doctor_date '%(%-d %b %Y)T' -1
_fact "repo"$'\t'"$REPO_ROOT"
_fact "home"$'\t'"${HOME:-}"
_fact "date"$'\t'"$_doctor_date"
_fact "rev"$'\t'"$_doctor_rev"

# ---------------------------------------------------------------------------
# The machine
# ---------------------------------------------------------------------------
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

# How many checks there will be, as near as is known now, for the box's bar: the machine's four and
# a runner, the repository's five, the batches (one line each, or the one saying there are none),
# and a copy of each skill that is installed. The runner and the notes are not counted exactly, and
# the bar is only as full as the share of this that is done.
_foreman_skill_marker=".foreman-installed-from"
_expect=10
if [ -z "$batches" ]; then _expect=$((_expect + 1)); else _expect=$((_expect + 1 + ${#batches} - ${#batches//$'\n'/})); fi
for _foreman_skill_md in "$FOREMAN_HOME"/skills/*/SKILL.md; do
  [ -f "$_foreman_skill_md" ] || continue
  _foreman_skill_name="${_foreman_skill_md%/SKILL.md}"; _foreman_skill_name="${_foreman_skill_name##*/}"
  [ ! -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/$_foreman_skill_name/$_foreman_skill_marker" ] || _expect=$((_expect + 1))
done
_fact "expect"$'\t'"$_expect"

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

# ---------------------------------------------------------------------------
# The installed skill copies, one per skill install.sh put on this machine. Free (no
# exit-code change); each is said to be current, or a warning that it has drifted from this
# checkout — install.sh always replaces a marked copy wholesale, so drift only means the
# checkout moved on since. Nothing is said about a skill that is not installed. Matches
# install.sh's own marker file, skill list and CLAUDE_CONFIG_DIR default exactly.
# ---------------------------------------------------------------------------
SECTION=skill
_foreman_skill_drifted=0
for _foreman_skill_md in "$FOREMAN_HOME"/skills/*/SKILL.md; do
  [ -f "$_foreman_skill_md" ] || continue
  _foreman_skill_src="${_foreman_skill_md%/SKILL.md}"
  _foreman_skill_name="${_foreman_skill_src##*/}"
  _foreman_skill_copy="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/$_foreman_skill_name"
  [ -f "$_foreman_skill_copy/$_foreman_skill_marker" ] || continue
  if diff -rq -x "$_foreman_skill_marker" "$_foreman_skill_src" "$_foreman_skill_copy" >/dev/null 2>&1; then
    ok "$_foreman_skill_name copy is current"
  else
    _foreman_skill_drifted=1
    warn "$_foreman_skill_name — installed copy differs from $_foreman_skill_src"
  fi
done
if [ "$_foreman_skill_drifted" -eq 1 ]; then
  note "run: bash $FOREMAN_HOME/install.sh"
fi

# ---------------------------------------------------------------------------
# The two files a consuming repo has to provide itself. A .gitignore pattern is said as the file it
# keeps untracked (`foreman-runs.log ignored`), which is also what fits a column of the box.
# ---------------------------------------------------------------------------
SECTION=repository

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
    ok "${pat#\*\*/} ignored"
  else
    missing_ignore=$((missing_ignore + 1))
    fix "${pat#\*\*/} not ignored"
  fi
done

# The attribute only matters where git rewrites line endings in the first place.
needs_attr=0
grep -qE '^\*[[:space:]]+text=auto' .gitattributes 2>/dev/null && needs_attr=1
[ "$(git config --get core.autocrlf 2>/dev/null)" = "true" ] && needs_attr=1

if [ "$needs_attr" -eq 1 ]; then
  if grep -qE '^foreman\.conf[[:space:]]+text[[:space:]]+eol=lf' .gitattributes 2>/dev/null; then
    ok ".gitattributes keeps foreman.conf LF"
  else
    fix ".gitattributes does not keep foreman.conf LF"
    note "this repo rewrites line endings, so a tracked foreman.conf would come back CRLF"
    needs_attr=2
  fi
else
  ok ".gitattributes not needed: this repo keeps its line endings"
fi

if [ "$missing_ignore" -gt 0 ] || [ "$needs_attr" -eq 2 ]; then fixable=1; fi

# What `--fix` writes. It is done after the box is drawn, not in the middle of it: the box says what
# was found, and what was written to put it right follows.
_doctor_fix() {
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
  echo
}

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

SECTION=batches
if [ -z "$batches" ]; then
  info "none — no directory here has a foreman.conf."
  info "Create one:  $FOREMAN_INVOKE init <batch-dir>"
else
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    # Read as numbers, so never the picture `--count` draws when the show is forced.
    if counts=$(FOREMAN_SHOW=never bash "$FOREMAN_TOOL_DIR/foreman-next.sh" "$b" --count 2>/dev/null); then
      ok "$b" "${counts% *} of ${counts#* } done"
    else
      warn "$b" "order unreadable — run: $FOREMAN_INVOKE status $b"
    fi
    foreman_legacy_conf_path conf "$b" 2>/dev/null
    _check_can_commit "$conf" "$(_conf_value "$conf" FOREMAN_EXEC)"
  done <<< "$batches"
fi

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
  SECTION=rename
  for _l in "${_legacy_lines[@]}"; do warn "$_l"; done
  case "$runners" in *sbx*)
    _foreman_basename _legacy_repo "$PWD"
    note "the default sandbox is now foreman-$_legacy_repo; an old one can go:  sbx rm ralph-$_legacy_repo"
  ;; esac
fi

# ---------------------------------------------------------------------------
# The verdict. What to do next goes in the box; the renderer works out the rest from the checks.
# ---------------------------------------------------------------------------
if [ "$problems" -gt 0 ]; then
  if [ "$fixable" -eq 1 ] && [ "$FIX" -eq 0 ]; then _fact "advice"$'\t'"fix:"$'\t'"$FOREMAN_INVOKE doctor --fix"; fi
elif [ -n "$batches" ]; then
  _fact "advice"$'\t'"next:"$'\t'"$FOREMAN_INVOKE run ${batches%%$'\n'*}"
else
  _fact "advice"$'\t'"next:"$'\t'"$FOREMAN_INVOKE init <batch-dir>"
fi

# On the show path the renderer has been drawing all along: closing its input is what tells it that
# was the last check, and it plays the verdict, so wait for it. Anywhere else the box is drawn now,
# whole or not at all (what a renderer prints before it fails is not kept), and if it cannot be
# drawn the checks are listed as they always were.
if [ "$_live" -eq 1 ]; then
  exec 3>&-
  _live=0
  wait "$_doctor_pid" 2>/dev/null || { _doctor_lines; }
  trap - EXIT PIPE
  _doctor_restore_cursor
elif command -v node >/dev/null 2>&1 &&
     _doctor_box="$(printf '%s\n' "${_facts[@]}" | node "$_doctor_draw" doctor --plain --cols "$_doctor_min_cols" 2>/dev/null)"; then
  printf '%s\n\n' "$_doctor_box"
else
  _doctor_lines
fi

[ "$fixable" -eq 1 ] && [ "$FIX" -eq 1 ] && _doctor_fix

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
