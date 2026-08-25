#!/bin/bash
# Is this repository — and this machine — ready to run ralph?
#
#   ralph doctor          report; exit 0 if ready, 1 if something must be fixed
#   ralph doctor --fix    also append the .gitignore / .gitattributes lines this repo needs
#
# Costs nothing and starts no sandbox. It reports on three things:
#
#   the machine   git, node, awk, bash 4+, and either `sbx` or `claude` depending on the
#                 execution mode the batches here ask for
#   this repo     the two files a repo must add itself: .gitignore, so a batch's run logs
#                 and its transient bundle stay untracked, and .gitattributes, so a
#                 ralph.conf sourced as bash is not checked out with CRLF
#   the batches   every directory here with a ralph.conf, and how far each one has got
#
# --fix only ever APPENDS to .gitignore and .gitattributes. It never touches a batch, a
# ticket, or anything already in those files.
set -uo pipefail

RALPH_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FIX=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fix)     FIX=1 ;;
    --help|-h) awk 'NR==1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *)         echo "Usage: ralph doctor [--fix]" >&2; exit 1 ;;
  esac
  shift
done

# doctor has to work in a repo with no batch at all — that is the point of running it
# before `ralph init`. So it does NOT source ralph-config.sh, which resolves a batch and
# fails without one. It shares the path resolution instead, which is the part that has to
# agree.
# shellcheck source=ralph-repo.sh
source "$RALPH_TOOL_DIR/ralph-repo.sh" || {
  echo "ralph doctor: cannot load $RALPH_TOOL_DIR/ralph-repo.sh" >&2; exit 1; }

REPO_ROOT="$(ralph_repo_root)" || {
  echo "ralph doctor: not inside a git repository." >&2
  echo "              A batch lives in a repo, because each iteration commits its work." >&2
  exit 1
}
cd "$REPO_ROOT" || exit 1
RALPH_HOME="${RALPH_HOME:-$(cd "$RALPH_TOOL_DIR/.." && pwd)}"
RALPH_INVOKE="${RALPH_INVOKE:-$RALPH_HOME/bin/ralph}"

problems=0
fixable=0

ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  MISS  %s\n' "$*"; problems=$((problems + 1)); }
note() { printf '        %s\n' "$*"; }

echo "ralph doctor"
echo "  toolkit  $RALPH_HOME ($(git -C "$RALPH_HOME" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout'))"
echo "  repo     $REPO_ROOT"
echo

# ---------------------------------------------------------------------------
# The machine
# ---------------------------------------------------------------------------
echo "Machine"
for tool in git node awk; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool"; else bad "$tool is not on PATH"; fi
done

# ralph-config.sh uses associative arrays and `compgen -v`, both of which need bash 4.
if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
  ok "bash ${BASH_VERSION%%(*} (4+ required)"
else
  bad "bash ${BASH_VERSION:-?} is too old — 4+ is required for associative arrays"
fi

# ---------------------------------------------------------------------------
# Which batches are here, and therefore which agent runner matters.
# Same prune list as ralph-config.sh: .claude/worktrees holds full copies of the repo, so
# without it every batch would be reported once per worktree.
# ---------------------------------------------------------------------------
batches=$(find . \
  \( -name node_modules -o -name .git -o -path './.claude/worktrees' -o -name .svelte-kit \) -prune \
  -o -name ralph.conf -print 2>/dev/null |
  sed 's|^\./||; s|/ralph\.conf$||' | sort)

# The default is sandbox, so sbx is what matters unless every batch here opts out of it.
wants_sbx=1
if [ -n "$batches" ]; then
  wants_sbx=0
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    mode=$(grep -E '^[[:space:]]*RALPH_EXEC=' "$b/ralph.conf" 2>/dev/null |
           tail -1 | sed 's/.*=//' | tr -d '"'"'"'\r')
    case "${mode:-sandbox}" in local) ;; *) wants_sbx=1 ;; esac
  done <<< "$batches"
fi

if [ "$wants_sbx" -eq 1 ]; then
  if command -v sbx >/dev/null 2>&1; then
    ok "sbx (a batch here uses a sandbox mode)"
  else
    bad "sbx is not on PATH, and a batch here uses a sandbox mode"
    note "set RALPH_EXEC=local in that batch's ralph.conf to run without one"
  fi
else
  if command -v claude >/dev/null 2>&1; then
    ok "claude (every batch here uses RALPH_EXEC=local)"
  else
    bad "claude is not on PATH, and every batch here uses RALPH_EXEC=local"
  fi
fi
echo

# ---------------------------------------------------------------------------
# The two files a consuming repo has to provide itself
# ---------------------------------------------------------------------------
echo "Repository"

# `read -d ''` returns non-zero when it hits EOF without finding the delimiter, which is
# every time here. That is expected; the variable is still set. `set -e` is deliberately
# not in force in this toolkit, so it does not abort.
read -r -d '' GITIGNORE_BLOCK <<'BLOCK'

# Ralph: per-batch run state. Every one of these lives in the batch directory, which is
# why the patterns match anywhere rather than under one directory — a batch is any
# directory with a ralph.conf.
#
# The git bundle an iteration's commits travel in, from the sandbox's clone back to this
# repo. Written and deleted within one iteration.
**/.ralph-iter.bundle

# Append-only run telemetry. Untracked deliberately — the loop appends to these after each
# iteration, so tracking them would put unrelated churn in every ticket's commit.
# Inspect with `ralph report <batch>`.
**/ralph-runs.jsonl
**/ralph-runs.log
BLOCK

read -r -d '' GITATTRIBUTES_BLOCK <<'BLOCK'

# Ralph: ralph.conf is sourced by bash, so a CRLF checkout would append a carriage return
# to every value it sets — RALPH_EXEC would become "sandbox<CR>" and fail validation with
# a message that looks like a lie.
ralph.conf text eol=lf
BLOCK

missing_ignore=0
for pat in '**/.ralph-iter.bundle' '**/ralph-runs.jsonl' '**/ralph-runs.log'; do
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
  if grep -qE '^ralph\.conf[[:space:]]+text[[:space:]]+eol=lf' .gitattributes 2>/dev/null; then
    ok ".gitattributes  ralph.conf text eol=lf"
  else
    bad ".gitattributes  ralph.conf text eol=lf"
    note "this repo rewrites line endings, so a tracked ralph.conf would come back CRLF"
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
  echo "  Review the diff and commit it — these are the only files ralph asks a repo for."
fi
echo

# ---------------------------------------------------------------------------
# The batches
# ---------------------------------------------------------------------------
echo "Batches"
if [ -z "$batches" ]; then
  echo "  none — no directory here has a ralph.conf."
  echo "  Create one:  $RALPH_INVOKE init <batch-dir>"
else
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if counts=$(bash "$RALPH_TOOL_DIR/ralph-next.sh" "$b" --count 2>/dev/null); then
      printf '  %-40s %s of %s done\n' "$b" "${counts% *}" "${counts#* }"
    else
      printf '  %-40s (order unreadable — run: %s status %s)\n' "$b" "$RALPH_INVOKE" "$b"
    fi
  done <<< "$batches"
fi
echo

if [ "$problems" -gt 0 ]; then
  if [ "$fixable" -eq 1 ] && [ "$FIX" -eq 0 ]; then
    echo "$problems thing(s) to fix. The repo files can be written for you:"
    echo "  $RALPH_INVOKE doctor --fix"
  else
    echo "$problems thing(s) still need fixing by hand."
  fi
  exit 1
fi

echo "Ready."
exit 0
