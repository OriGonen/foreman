#!/bin/bash
# Benchmark for `ralph status` — a measuring instrument, not a test: it asserts nothing and
# is not part of the smoke suite. It builds its own 3-ticket batch on the `fake` adapter,
# times `ralph status` on it over several runs, then traces one call and breaks its spawns
# down by command, so a change that removes a spawn can be shown to have done so.
#
#   bash test/bench.sh            5 timed runs, then the spawn breakdown
#   bash test/bench.sh 10         10 timed runs
#
# Under Git Bash a run of `ralph status` takes tens of seconds, so the default takes a few
# minutes. There is no warm-up: the first run includes any cold-cache cost, and is shown.
#
# Output is plain text, for pasting into a ticket: each run's seconds and the median, then
# the spawns of one traced call — external commands by name, and a count of subshells and
# command substitutions — sorted by count, with a total. An external command inside a
# subshell counts in both rows (`$(grep …)` is one subshell and one grep), so the total is
# spawn events, not distinct processes. Builtins and functions are not spawns; a subshell
# that runs no traced command of its own is not seen, so the count is a floor. ralph is run
# as `bash bin/ralph`, so the numbers do not depend on its executable bit.
#
# The fixture lives under $TMPDIR and is removed on exit, on Ctrl-C, and when the run is
# terminated or its terminal closes. Runs under Git Bash and under WSL alike (bash 4+; the
# timing uses EPOCHREALTIME where bash has it and `date` where it does not).
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_HOME="$(cd "$TEST_DIR/.." && pwd)"
RALPH="$RALPH_HOME/bin/ralph"

RUNS=5
case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,/^set /p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) if [[ $1 =~ ^[1-9][0-9]*$ ]]; then RUNS="$1"
     else printf 'usage: bash test/bench.sh [runs]\n' >&2; exit 2; fi ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ralph-bench-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# --- fixture ----------------------------------------------------------------
# The same repository as the smoke suite's `make_repo 3`, built by the same code
# (test/fixture.sh), so these numbers compare with the suite's and with report.md.
. "$TEST_DIR/fixture.sh"
REPO="$WORK/bench-repo"
build_fixture_template "$WORK/template"
copy_fixture "$WORK/template" "$REPO" 3

# --- clock ------------------------------------------------------------------
# Sets NOW_MS to milliseconds since some fixed point. No process where bash 5 has its clock.
now_ms() {
  local t
  if [ -n "${EPOCHREALTIME:-}" ]; then t="${EPOCHREALTIME/[.,]/}"; NOW_MS=$((t / 1000))
  else NOW_MS=$(( $(date +%s%N) / 1000000 )); fi
}

# Sets SECS_TEXT to $1 milliseconds as seconds with two decimals.
secs_text() { printf -v SECS_TEXT '%d.%02d' $(($1 / 1000)) $(( ($1 % 1000) / 10 )); }

# --- timing -----------------------------------------------------------------
platform="$OSTYPE"
[ -n "${WSL_DISTRO_NAME:-}" ] && platform="$platform (WSL: $WSL_DISTRO_NAME)"
printf 'Benchmark: ralph status on a 3-ticket batch (fake adapter)\n'
printf 'Platform:  %s, bash %s\n\n' "$platform" "$BASH_VERSION"

# Standing in the repo, and sending output to a file, keep the timed span to the call itself:
# no subshell or command substitution of the benchmark's own.
cd "$REPO" || exit 1
TIMES=()
printf 'Timing, %d runs:\n' "$RUNS"
for ((n = 1; n <= RUNS; n++)); do
  now_ms; start=$NOW_MS
  bash "$RALPH" status batch > "$WORK/out" 2>&1
  st=$?
  now_ms
  ms=$((NOW_MS - start))
  TIMES+=("$ms")
  secs_text "$ms"
  note=""
  [ "$st" = 0 ] || note="  (exit $st — the numbers are for a failing call)"
  printf '  run %d:  %7s s%s\n' "$n" "$SECS_TEXT" "$note"
done
mapfile -t SORTED < <(printf '%s\n' "${TIMES[@]}" | sort -n)
mid=$((RUNS / 2))
if [ $((RUNS % 2)) = 1 ]; then median=${SORTED[$mid]}
else median=$(( (SORTED[mid - 1] + SORTED[mid]) / 2 )); fi
secs_text "$median"
printf '  median: %7s s\n' "$SECS_TEXT"

# --- spawn trace ------------------------------------------------------------
# One more call with xtrace on, every line stamped with the PID and subshell depth of the
# shell that ran it, sent to its own file so no redirection inside ralph can swallow it.
TRACE="$WORK/trace"
env SHELLOPTS=xtrace BASH_XTRACEFD=9 PS4='+ ${BASHPID} ${BASH_SUBSHELL} ' \
  bash "$RALPH" status batch 9> "$TRACE" > /dev/null 2>&1

# What is not a spawn: builtins, keywords, and the functions ralph itself defines.
declare -A NOT_SPAWN=()
for w in $(compgen -b) $(compgen -k) '((' '[[' ']]'; do NOT_SPAWN[$w]=1; done
fn_re='^[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_:.-]*)[[:space:]]*\(\)'
for f in "$RALPH" "$RALPH_HOME"/lib/*.sh "$RALPH_HOME"/lib/exec/*.sh; do
  while IFS= read -r line; do
    [[ $line =~ $fn_re ]] && NOT_SPAWN[${BASH_REMATCH[2]}]=1
  done < "$f"
done

declare -A BY_CMD=()
declare -A SEEN=()
subshells=0
line_re='^\++ ([0-9]+) ([0-9]+) (.*)$'
# A `VAR=value` prefix on a command (the value bare, or in quotes), or a whole assignment
# with no command word: an array `VAR=(…)`, or a quoted value that runs on to the next line.
q="'"
name_re='^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?='
array_re="${name_re}\\("
sq_val="$q[^$q]*$q"
open_re="${name_re}($q[^$q]*|\"[^\"]*)$"   # a value that runs on to the next line
ansi_val='\$'"$sq_val"
assign_re="${name_re}(${ansi_val}|${sq_val}|\"[^\"]*\"|[^ $q\"(]*) ?(.*)\$"
lines=0
while IFS= read -r line; do
  [[ $line =~ $line_re ]] || continue
  lines=$((lines + 1))
  pid="${BASH_REMATCH[1]}"; depth="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"

  # A shell first seen below the top level is a subshell or a command substitution; a new
  # shell at depth 0 is a script started by name, already counted as the `bash` that ran it.
  if [ -z "${SEEN[$pid]:-}" ]; then
    SEEN[$pid]=1
    [ "$depth" -gt 0 ] && subshells=$((subshells + 1))
  fi

  # The command word: past any `VAR=x` prefixes, and past `exec` (which runs a program only
  # when it is given one, not when it just opens a file descriptor).
  [[ $rest =~ $array_re || $rest =~ $open_re ]] && continue
  while [[ $rest =~ $assign_re ]]; do rest="${BASH_REMATCH[3]}"; done
  [ -n "$rest" ] || continue
  cmd="${rest%% *}"
  if [ "$cmd" = exec ]; then
    [ "$rest" = exec ] && continue
    rest="${rest#exec }"; cmd="${rest%% *}"
    [[ $cmd =~ ^([0-9]|[<>{&]) ]] && continue
  fi
  cmd="${cmd#$q}"; cmd="${cmd%$q}"   # xtrace quotes `[` as '['
  cmd="${cmd##*/}"
  [ -n "${NOT_SPAWN[$cmd]:-}" ] && continue
  BY_CMD[$cmd]=$(( ${BY_CMD[$cmd]:-0} + 1 ))
done < "$TRACE"

printf '\nSpawns in one `ralph status batch` call (traced):\n'
if [ "$lines" = 0 ]; then
  printf '  no trace captured — this bash did not honour BASH_XTRACEFD for the child shells\n'
  exit 0
fi
total=$subshells
{
  for cmd in "${!BY_CMD[@]}"; do
    printf '%d\t%s\n' "${BY_CMD[$cmd]}" "$cmd"
    total=$((total + BY_CMD[$cmd]))
  done
  printf '%d\t%s\n' "$subshells" '(subshells and command substitutions)'
} > "$WORK/counts"
sort -t$'\t' -k1,1nr -k2,2 "$WORK/counts" | while IFS=$'\t' read -r count name; do
  printf '  %5d  %s\n' "$count" "$name"
done
printf '  %5s  %s\n' "-----" ""
printf '  %5d  total\n' "$total"
