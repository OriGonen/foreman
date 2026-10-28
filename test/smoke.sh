#!/bin/bash
# End-to-end tests for the loop, driven by the `fake` exec adapter — no sandbox, no model,
# no money. Each case builds a throwaway repo with a batch of tickets in it, runs foreman
# against it, and asserts on the exit code, what landed, and what the run log says.
#
#   bash test/smoke.sh            run everything
#   bash test/smoke.sh dirty      run the cases whose name contains "dirty"
#   FOREMAN_SMOKE_JOBS=1 bash test/smoke.sh
#                                 one case at a time (the default is one per core; see below)
#   bash test/bench.sh            not a test: times `foreman status` and counts its spawns
#                                 (see the header of test/bench.sh)
#
# Output: each selected case announces itself as `[position/total] name` and ends with its
# elapsed seconds, so a slow run can be told from a hung one; with a filter, position and
# total count only the selected cases. The run ends with the slowest cases (up to 10), the
# `N passed, M failed` line, and `N passed in Mm Ss` for pasting into a ticket's closing
# note. Timing is bash's own clock — no processes per case. (Sub-second resolution needs
# bash 5's EPOCHREALTIME; older bash falls back to whole seconds.)
#
# Parallel cases: this file is two programs. Run by a person it is the runner: it builds the
# fixture template, then starts one case process per selected case — this same file, told
# which case to run — keeping at most FOREMAN_SMOKE_JOBS going at once (default: one per
# logical core; under Git Bash process creation stops scaling there). A case process writes
# its output to a buffer file and its counts to a result file, both under the run's work
# directory; the runner replays the buffers in case order, each whole, so the log reads as a
# serial run's does, and sums the counts. A case's header appears when every case before it
# has been printed, its lines when the case has finished (so a FAIL line, which a serial run
# sends to stderr, arrives with the rest of its case's output on stdout). A case that ends
# without finishing — its process died, or its name was not found — counts as a failure.
#
# Cases share nothing: each has repositories, logs and install directories of its own names,
# its own TMPDIR (so the fake adapter's per-PID call counter starts empty), and its own
# process. The runner builds the template before any case starts and nothing writes to it.
#
# The fixtures live under $TMPDIR and are removed on exit, on Ctrl-C, and when the run is
# terminated or its terminal closes — unless FOREMAN_KEEP_FIXTURES=1. Those signals stop the
# case processes too, with everything they started, before the directory goes. (A hard kill
# cannot be trapped.)
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOREMAN_HOME="$(cd "$TEST_DIR/.." && pwd)"
FOREMAN="$FOREMAN_HOME/bin/foreman"
SELF="$TEST_DIR/${BASH_SOURCE[0]##*/}"

# legacy: a machine set up before the rename may still export RALPH_* (a `setx` of
# RALPH_DOCKER_USERNAME, say). Foreman would honour it, and warn, in every case; no case
# expects that, so none inherits it.
_smoke_legacy=$(compgen -v RALPH_)
[ -z "$_smoke_legacy" ] || unset $_smoke_legacy

# The terminal this suite is started from must not decide how foreman colours: FOREMAN_COLOR=always
# paints at the tier it detects, 16 when it detects nothing, and the cases below that look for
# `ESC[32m` are about that 16-colour form. Windows Terminal (WT_SESSION), mintty (COLORTERM) and a
# 256color TERM would each raise the tier. The cases that are about the tier set what they need.
unset COLORTERM WT_SESSION NO_COLOR
case "${TERM:-}" in *256color*) TERM=xterm ;; esac

# Set only by the runner, on a case process: the case's name, its position, and the work
# directory it shares with the runner.
CASE_WANTED="${_SMOKE_CASE:-}"

if [ -n "$CASE_WANTED" ]; then
  FILTER=""
  WORK="$_SMOKE_WORK"
  CASE_IDX="$_SMOKE_IDX"
  mkdir -p "$WORK/.tmp/$CASE_IDX"
  export TMPDIR="$WORK/.tmp/$CASE_IDX"
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
else
  FILTER="${1:-}"
  JOBS="${FOREMAN_SMOKE_JOBS:-${NUMBER_OF_PROCESSORS:-$(nproc 2>/dev/null)}}"
  JOBS="${JOBS:-4}"
  if ! [[ $JOBS =~ ^[1-9][0-9]*$ ]]; then
    printf 'usage: FOREMAN_SMOKE_JOBS must be a positive number, not "%s"\n' "$JOBS" >&2
    exit 2
  fi
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/foreman-smoke-XXXXXX")"
  # No case may read the operator's real credentials file (~/.config/foreman/env): a case that
  # wants one points FOREMAN_CREDENTIALS_FILE at its own. Case processes inherit this.
  export FOREMAN_CREDENTIALS_FILE="$WORK/no-such-credentials-file"
  # Nor the operator's installed skills: `foreman init` runs `foreman commands`, which calls
  # whatever `claude` is on PATH once it finds the skill installed. Pointed at an empty
  # directory, a case that does not stub claude and install the skill gets a skip note, not a
  # model call. A case that wants either points CLAUDE_CONFIG_DIR at its own.
  export CLAUDE_CONFIG_DIR="$WORK/no-such-claude-config"
  JOB_PIDS=()
  # Stops the case processes still running — each leads a process group of its own, so the
  # signal reaches everything it started — then removes the directory. Windows keeps a
  # directory busy while a process that had it as its working directory is still dying, so
  # the removal is tried again, and the processes killed outright if they outlast the first
  # tries.
  stop_cases() {
    local i
    for i in "${!JOB_PIDS[@]}"; do
      [ -e "$WORK/.results/$i.rc" ] || kill "-$1" -- "-${JOB_PIDS[i]}" 2>/dev/null
    done
  }
  cleanup() {
    local try
    { stop_cases TERM; wait; } 2>/dev/null    # not the shell's "Terminated" notices
    [ "${FOREMAN_KEEP_FIXTURES:-0}" = 1 ] && return
    for try in 1 2 3 4 5 6; do
      rm -rf "$WORK" 2>/dev/null
      [ -e "$WORK" ] || return 0
      [ "$try" = 3 ] && stop_cases KILL
      sleep 1
    done
    printf 'smoke.sh: could not remove %s\n' "$WORK" >&2
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
fi

passed=0
failed=0
CASE=""

# --- progress and timing ----------------------------------------------------
# Sets NOW_US to microseconds since some fixed point, from bash's own clock.
now_us() {
  if [ -n "${EPOCHREALTIME:-}" ]; then NOW_US="${EPOCHREALTIME/[.,]/}"
  else NOW_US=$((SECONDS * 1000000)); fi
}

CASE_OPEN=0
CASE_START_US=0
CASE_MS=0

# Closes the case in progress, if any: prints its elapsed seconds and keeps them in CASE_MS.
case_end() {
  [ "$CASE_OPEN" = 1 ] || return 0
  local tenths
  now_us
  CASE_MS=$(( (NOW_US - CASE_START_US) / 1000 ))
  printf -v tenths '%d.%d' $((CASE_MS / 1000)) $(( (CASE_MS % 1000) / 100 ))
  printf '  (%ss)\n' "$tenths"
  CASE_OPEN=0
}

# --- assertions -------------------------------------------------------------
fail() { printf '  FAIL  %s\n' "$*" >&2; failed=$((failed + 1)); }
pass() { passed=$((passed + 1)); }

assert_eq() {
  if [ "$1" = "$2" ]; then pass; else fail "$3: expected '$2', got '$1'"; fi
}
assert_contains() {
  case "$1" in *"$2"*) pass ;; *) fail "$3: expected to find '$2'" ;; esac
}
assert_missing() {
  case "$1" in *"$2"*) fail "$3: did not expect '$2'" ;; *) pass ;; esac
}

# --- fixture ----------------------------------------------------------------
# Every fixture is a copy of one template, built once per run (test/fixture.sh, shared with
# test/bench.sh). It lives in $WORK, so it goes when the run's work directory does.
. "$TEST_DIR/fixture.sh"
FIXTURE_TEMPLATE="$WORK/.template"

# A repo with one batch of $1 tickets, none of them done. Prints its path.
make_repo() {
  local count="${1:-2}" name="${2:-repo}"
  copy_fixture "$FIXTURE_TEMPLATE" "$WORK/$name" "$count"
  printf '%s' "$WORK/$name"
}

# Run foreman in $1 with the rest as arguments. Captures stdout+stderr in $OUT, status in $ST.
run_foreman() {
  local repo="$1"; shift
  OUT="$(cd "$repo" && "$FOREMAN" "$@" 2>&1)"
  ST=$?
}

# Counts the implemented tickets, in the batch directory or in its DONE_ rename once finished.
done_count() { grep -l '^\*\*Status:\*\* implemented' "$1"/batch/issues/*.md "$1"/DONE_batch/issues/*.md 2>/dev/null | grep -c . ; }

# --- the case process -------------------------------------------------------
# Every `if case_is "name"; then` below runs its body only in the case process that was
# asked for that name; in every other it is false, and the process leaves at the first
# case_is after its own case's `fi` (or at the end of the file, for the last case).
case_is() {
  if [ "$CASE_OPEN" = 1 ]; then case_finish; exit 0; fi
  [ "$1" = "$CASE_WANTED" ] || return 1
  CASE="$1"
  CASE_OPEN=1
  now_us; CASE_START_US=$NOW_US
  return 0
}

# Ends the case: its elapsed seconds into the buffer, its counts into the result file the
# runner sums.
case_finish() {
  case_end
  printf '%s %s %s\n' "$passed" "$failed" "$CASE_MS" > "$WORK/.results/$CASE_IDX.counts"
}

# --- the runner -------------------------------------------------------------
# Runs the selected cases, at most $JOBS at a time, and prints them in order. Sets the
# totals the final lines report.
run_cases() {
  local line name i seen=$'\n' wait_n=1 inflight=0
  local case_line_re='^if case_is "(.*)"; then$'
  NAMES=()
  while IFS= read -r line; do
    [[ $line =~ $case_line_re ]] || continue
    name="${BASH_REMATCH[1]}"
    # A name must be told apart from every other by the case process, filter or no filter.
    case "$seen" in
      *$'\n'"$name"$'\n'*) printf 'smoke.sh: two cases are named "%s"\n' "$name" >&2; return 2 ;;
    esac
    seen+="$name"$'\n'
    case "$name" in *"$FILTER"*) NAMES+=("$name") ;; esac
  done < "$SELF"
  TOTAL=${#NAMES[@]}

  # Waiting for whichever case finishes first needs bash 4.3; without it, one at a time.
  if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 403 )); then wait_n=0; JOBS=1; fi

  mkdir -p "$WORK/.results" "$WORK/.out" "$WORK/.tmp"
  build_fixture_template "$FIXTURE_TEMPLATE"

  HEAD=0
  SHOWN=-1
  CASE_TIMES=()
  set -m    # a process group per case process, so an interrupt can stop all of its children

  for ((i = 1; i <= TOTAL; i++)); do
    while (( inflight >= JOBS )); do
      if (( wait_n )); then wait -n; else wait; fi
      inflight=$((inflight - 1))
      print_ready
    done
    start_case "$i"
    inflight=$((inflight + 1))
    print_ready
  done
  while (( HEAD < TOTAL && inflight > 0 )); do
    if (( wait_n )); then wait -n; else wait; fi
    inflight=$((inflight - 1))
    print_ready
  done
  return 0
}

# Starts the case process for the case at position $1 (1-based) in the background. It gets
# no stdin, as it would not under `$(...)` in a serial run, and its stdout and stderr go to
# one buffer file. The `.rc` file marks the process as over, whatever the way it ended.
start_case() {
  local n="$1"
  (
    _SMOKE_CASE="${NAMES[n - 1]}" _SMOKE_WORK="$WORK" _SMOKE_IDX="$n" \
      "$BASH" "$SELF" > "$WORK/.out/$n" 2>&1 < /dev/null
    echo $? > "$WORK/.results/$n.rc"
  ) &
  JOB_PIDS[n]=$!
}

# Prints, in case order, every case from the head of the queue that has finished: its
# header, its buffered lines, and the verdict of its counts. Stops at the first that has not,
# after showing its header — so the log always names the case being waited on.
print_ready() {
  local n line p f ms rc
  while (( HEAD < TOTAL )); do
    n=$((HEAD + 1))
    if (( SHOWN != HEAD )); then
      printf '\n[%d/%d] %s\n' "$n" "$TOTAL" "${NAMES[HEAD]}"
      SHOWN=$HEAD
    fi
    [ -e "$WORK/.results/$n.rc" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do printf '%s\n' "$line"; done < "$WORK/.out/$n"
    if read -r p f ms 2>/dev/null < "$WORK/.results/$n.counts"; then
      passed=$((passed + p)); failed=$((failed + f))
      CASE_TIMES+=("$ms ${NAMES[HEAD]}")
    else
      read -r rc < "$WORK/.results/$n.rc"
      printf '  FAIL  the case ended (exit status %s) without finishing\n' "$rc" >&2
      failed=$((failed + 1))
    fi
    HEAD=$((HEAD + 1))
  done
}

# After the last case: the slowest cases and the total, for the closing note.
timing_report() {
  local line ms total_s
  if [ "${#CASE_TIMES[@]}" -gt 0 ]; then
    printf '\nSlowest cases:\n'
    while IFS= read -r line; do
      ms="${line%% *}"
      printf '  %4d.%d s  %s\n' $((ms / 1000)) $(( (ms % 1000) / 100 )) "${line#* }"
    done < <(printf '%s\n' "${CASE_TIMES[@]}" | sort -rn | head -n 10)
  fi
  now_us
  total_s=$(( (NOW_US - RUN_START_US) / 1000000 ))
  TOTAL_TEXT="$((total_s / 60))m $((total_s % 60))s"
}

if [ -z "$CASE_WANTED" ]; then
  now_us; RUN_START_US=$NOW_US
  run_cases || exit $?
  timing_report
  printf '\n%s passed, %s failed\n' "$passed" "$failed"
  printf '%s passed in %s\n' "$passed" "$TOTAL_TEXT"
  [ "$failed" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

if case_is "status and dry-run spend nothing and need no runner"; then
  repo="$(make_repo 3 status-repo)"

  run_foreman "$repo" status batch
  assert_eq "$ST" 0 "status exits 0"
  assert_contains "$OUT" "Tickets done: 0 / 3" "status counts the tickets"
  assert_contains "$OUT" "Next: 01-ticket.md" "status names the next ticket"
  assert_missing "$OUT" "[HUMAN]" "no human tickets, so no marking"
  assert_missing "$OUT" "human tickets remaining" "and no human-ticket count"
  assert_missing "$OUT" "warning:" "and no warnings — this batch has neither kind of ticket"

  run_foreman "$repo" dry-run batch
  assert_eq "$ST" 0 "dry-run exits 0"
  assert_contains "$OUT" "Exec:    fake (no agent is run)" "dry-run describes the adapter"
  assert_contains "$OUT" "=== end prompt" "dry-run prints the prompt"
  assert_contains "$OUT" "Commit everything to the current branch" "the adapter supplies the commit note"
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "1" "dry-run committed nothing"
fi

if case_is "one iteration is the default, and it lands one ticket"; then
  repo="$(make_repo 3 default-repo)"
  run_foreman "$repo" run batch

  assert_eq "$ST" 10 "stops paused on the iteration budget"
  assert_contains "$OUT" "iteration budget reached (1)" "says why it paused"
  assert_eq "$(done_count "$repo")" "1" "exactly one ticket landed"
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "3" "the landing commit, plus the rename marking it done"
fi

if case_is "+ during a run adds an iteration"; then
  repo="$(make_repo 3 keys-plus-repo)"
  FOREMAN_FAKE_KEYS=+ run_foreman "$repo" run batch 1

  assert_eq "$ST" 10 "still stops paused on the iteration budget"
  assert_contains "$OUT" "iteration budget reached (2)" "the budget it stopped on is the new one"
  assert_eq "$(done_count "$repo")" "2" "two tickets landed, not one"
  assert_contains "$OUT" "── iteration 2 of 2" "the header shows the new budget"
  assert_contains "$OUT" "⌨ iterations: 1 of 2" "the key press is acknowledged"
  assert_contains "$OUT" "run batch 2" "the resume command carries the new budget"
  assert_contains "$(cat "$repo/batch/foreman-runs.log")" "# iteration budget changed: 1 → 2 (after iteration 1)" \
    "the run log records the change"
  # A run whose stdin is not a terminal starts no reader, and says nothing about keys.
  assert_missing "$OUT" "keys: +" "no key hint without a terminal"
fi

if case_is "- during a run removes an iteration, never below the one running"; then
  repo="$(make_repo 3 keys-minus-repo)"
  FOREMAN_FAKE_KEYS=- run_foreman "$repo" run batch 3
  assert_eq "$ST" 10 "stops paused on the iteration budget"
  assert_contains "$OUT" "iteration budget reached (2)" "one fewer than asked for"
  assert_eq "$(done_count "$repo")" "2" "two tickets landed"
  assert_contains "$OUT" "── iteration 1 of 3" "the first header shows the budget it started with"

  repo="$(make_repo 3 keys-floor-repo)"
  FOREMAN_FAKE_KEYS=--- run_foreman "$repo" run batch 3
  assert_contains "$OUT" "iteration budget reached (1)" "three presses floor at the iteration running"
  assert_eq "$(done_count "$repo")" "1" "that iteration still finishes"
  assert_contains "$OUT" "⌨ stops after this iteration (1 of 1)" "says the run stops after it"
fi

if case_is "- on an unlimited run stops it after the iteration running"; then
  repo="$(make_repo 3 keys-unlimited-repo)"
  FOREMAN_FAKE_KEYS=- run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 10 "pauses rather than finishing the batch"
  assert_eq "$(done_count "$repo")" "1" "one ticket landed"
  assert_contains "$OUT" "── iteration 1  ·" "an unlimited header has no 'of'"
  assert_contains "$OUT" "iteration budget reached (1)" "says why it paused"
  assert_contains "$OUT" "run batch 1" "the resume command names the budget it ended with"
  assert_contains "$(cat "$repo/batch/foreman-runs.log")" "# iteration budget changed: unlimited → 1" \
    "the run log records the change"
fi

if case_is "foreman-keys.sh --apply: the floor and unlimited"; then
  ctl="$WORK/keys-ctl"
  mkdir -p "$ctl"
  keys() { OUT="$(bash "$FOREMAN_HOME/lib/foreman-keys.sh" --apply "$1" "$ctl" 2>&1)"; read -r budget < "$ctl/budget"; }

  printf '0\n' > "$ctl/budget"; printf '2\n' > "$ctl/iteration"
  keys +
  assert_eq "$budget" 0 "+ leaves unlimited alone"
  assert_contains "$OUT" "already unlimited" "and says so"
  keys -
  assert_eq "$budget" 2 "- on unlimited stops after the iteration running"
  assert_contains "$OUT" "stops after this iteration (2 of 2)" "and says so"
  keys +=
  assert_eq "$budget" 4 "+ and = each add one"
  assert_contains "$OUT" "iterations: 2 of 4" "and say where the run now ends"
  keys -_-x
  assert_eq "$budget" 2 "- and _ each remove one, down to the floor; other keys do nothing"

  printf '5\n' > "$ctl/budget"; printf '0\n' > "$ctl/iteration"
  keys ------
  assert_eq "$budget" 1 "before the first iteration, the floor is 1"

  rm -f "$ctl/live"
  keys L
  assert_eq "$(cat "$ctl/live")" 1 "L turns the live view on from no file"
  assert_contains "$OUT" "live view on" "and says so"
  keys l
  assert_eq "$(cat "$ctl/live")" 0 "l turns it off again"
  assert_contains "$OUT" "live view off" "and says so"
  keys LL
  assert_eq "$(cat "$ctl/live")" 0 "two presses come back to where they started"
  assert_eq "$budget" 1 "L leaves the budget alone"
fi

if case_is "foreman-stream.cjs --live-file draws only while the file says on"; then
  # What L switches between: the agent reports in stream-json either way, the payload is the
  # result object either way, and only the drawing follows the file.
  live_file="$WORK/stream-live"
  events='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"src/drawn.js"}}]}}
{"type":"result","subtype":"success","total_cost_usd":0.01}'
  stream() {
    local err="$WORK/stream-err"
    OUT="$(printf '%s\n' "$events" | node "$FOREMAN_HOME/lib/foreman-stream.cjs" --live-file "$live_file" 2>"$err")"
    ERR="$(cat "$err")"
  }

  printf '0\n' > "$live_file"; stream
  assert_missing "$ERR" "src/drawn.js" "off: nothing is drawn"
  assert_eq "$OUT" '{"type":"result","subtype":"success","total_cost_usd":0.01}' "off: the payload is the result object"

  printf '1\n' > "$live_file"; stream
  assert_contains "$ERR" "Write src/drawn.js" "on: the write is drawn"
  assert_eq "$OUT" '{"type":"result","subtype":"success","total_cost_usd":0.01}' "on: the same payload"

  rm -f "$live_file"; stream
  assert_missing "$ERR" "src/drawn.js" "no file reads as off"
fi

if case_is "foreman-stream.cjs --activity-file writes down, never draws"; then
  # With a status bar the key reader draws the live view, so the filter must not touch the
  # terminal: two processes drawing on one screen is what left lines behind.
  activity="$WORK/stream-activity"
  err="$WORK/stream-activity-err"
  OUT="$(printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}' \
    '{"type":"result","subtype":"success","total_cost_usd":0.01}' |
    node "$FOREMAN_HOME/lib/foreman-stream.cjs" --activity-file "$activity" 2>"$err")"
  assert_eq "$(cat "$err")" "" "nothing on stderr"
  assert_eq "$OUT" '{"type":"result","subtype":"success","total_cost_usd":0.01}' "the payload is the result object"
  read -r epoch label < "$activity"
  assert_eq "$label" "Bash npm test" "the file has the latest label"
  if [[ "$epoch" =~ ^[0-9]{10}$ ]]; then pass; else fail "the start is in epoch seconds: got '$epoch'"; fi
fi

if case_is "foreman-keys.sh --text: the live view's line never wraps"; then
  ctl="$WORK/text-ctl"
  mkdir -p "$ctl"
  printf '3\n' > "$ctl/budget"; printf '1\n' > "$ctl/iteration"; printf '1\n' > "$ctl/live"
  long="Bash $(printf 'x%.0s' {1..120})"
  printf -v now '%(%s)T' -1
  printf '%s %s\n' "$((now - 75))" "$long" > "$ctl/activity"
  text() {
    OUT="$(FOREMAN_COLOR=never bash "$FOREMAN_HOME/lib/foreman-keys.sh" --text "$ctl" "$1")"
    BAR="${OUT%%$'\n'*}" TICKER=""
    [[ "$OUT" != *$'\n'* ]] || TICKER="${OUT#*$'\n'}"
  }
  # Widths in characters, not bytes: `·` and `…` are one column each.
  LC_ALL=C.UTF-8

  text 60
  assert_contains "$TICKER" "   01:1" "the clock runs from the epoch in the file"
  assert_eq "${#TICKER}" 59 "a long label is cut to one column short of the width"
  assert_contains "$BAR" "+ more  - fewer  L live" "the bar's hints fit in 60 columns"
  assert_contains "$TICKER" "…" "and says it was cut"
  assert_contains "$BAR" "iteration 1 of 3" "the bar comes first"
  text 200
  assert_contains "$TICKER" "$long" "a label that fits is whole"

  rm -f "$ctl/activity"
  text 60
  assert_eq "$TICKER" "" "no activity file, no line"
fi

if case_is "--unlimited runs the batch to completion"; then
  repo="$(make_repo 3 unlimited-repo)"
  run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 0 "exits 0 when every ticket is done"
  assert_contains "$OUT" "Every ticket in batch is done." "says the batch is finished"
  assert_eq "$(done_count "$repo")" "3" "all three landed"
  assert_contains "$OUT" "tickets landed:        3" "the footer counts them"
  assert_missing "$OUT" "overshot to salvage" "nothing stalled, so no such note"
fi

if case_is "resuming picks up at the first ticket that has not landed"; then
  repo="$(make_repo 3 resume-repo)"
  run_foreman "$repo" run batch 2
  assert_eq "$(done_count "$repo")" "2" "two landed in the first run"

  run_foreman "$repo" run batch --unlimited
  assert_contains "$OUT" "batch/issues/03-ticket.md" "the second run starts at ticket 3"
  assert_eq "$(done_count "$repo")" "3" "the batch finishes"
fi

if case_is "a ticket that does not land stops the run for a human"; then
  repo="$(make_repo 2 noop-repo)"
  FOREMAN_FAKE_BEHAVIOUR=noop run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "exits needs-a-human"
  assert_contains "$OUT" "is still not 'implemented'" "names the stuck ticket"
  assert_eq "$(done_count "$repo")" "0" "nothing landed"
fi

if case_is "a transient failure is retried within the run"; then
  repo="$(make_repo 2 retry-repo)"
  FOREMAN_FAKE_BEHAVIOUR=transient:land run_foreman "$repo" run batch --unlimited

  assert_contains "$OUT" "(attempt 2)" "the same ticket is attempted twice"
  assert_eq "$(done_count "$repo")" "2" "both tickets land in the end"
fi

if case_is "attempts are capped per ticket"; then
  repo="$(make_repo 2 attempts-repo)"
  FOREMAN_TICKET_ATTEMPTS=3 FOREMAN_FAKE_BEHAVIOUR=transient run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "gives up rather than looping"
  assert_contains "$OUT" "after 3 attempt(s)" "stops at FOREMAN_TICKET_ATTEMPTS"
  assert_missing "$OUT" "(attempt 4)" "never makes a fourth attempt"
fi

if case_is "a crash with no signal at all is not retried"; then
  # The narrowing that pays for itself: an unparseable failure carrying neither a transient
  # nor a context signal is indistinguishable from a logic failure, and a blind second
  # attempt at one of those costs a whole iteration to learn nothing.
  repo="$(make_repo 2 crash-repo)"
  FOREMAN_FAKE_BEHAVIOUR=crash run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "stops rather than retrying"
  assert_missing "$OUT" "(attempt 2)" "makes no second attempt"
  assert_eq "$(done_count "$repo")" "0" "nothing landed"
fi

if case_is "running out of context is retried even when no JSON came back"; then
  repo="$(make_repo 2 ctx-retry-repo)"
  log="$WORK/ctx-prompts.txt"
  FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=context:land \
    run_foreman "$repo" run batch --unlimited

  assert_contains "$OUT" "(attempt 2)" "retried despite the unparseable payload"
  assert_contains "$OUT" "out of context" "says what it saw"
  assert_eq "$(done_count "$repo")" "2" "both tickets land in the end"

  # And the retry is told, in one fixed sentence — the boolean crosses, the reply does not.
  p1="$(awk '/^===== fake prompt 1 /{f=1;next} /^===== fake prompt /{f=0} f' "$log")"
  p2="$(awk '/^===== fake prompt 2 /{f=1;next} /^===== fake prompt /{f=0} f' "$log")"
  assert_missing "$p1" "ran out of context" "the first attempt is not told"
  assert_contains "$p2" "ran out of context" "the second attempt is"
  assert_contains "$p2" "do not re-survey the repository" "and is told what to do about it"
fi

if case_is "a ticket too big for one context is diagnosed, not just failed"; then
  repo="$(make_repo 2 ctx-stuck-repo)"
  FOREMAN_TICKET_ATTEMPTS=2 FOREMAN_FAKE_BEHAVIOUR=context run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "gives up after the attempts"
  assert_contains "$OUT" "too large for one iteration" "says what is actually wrong"
  assert_missing "$OUT" "is still not 'implemented'" "not the generic message"
fi

if case_is "a real context payload is not mistaken for a transient one"; then
  # The real payload carries "api_error_status", whose field NAME contains the transient
  # pattern 'api_error'. Classification order is the only thing keeping these apart.
  repo="$(make_repo 2 ctx-json-repo)"
  FOREMAN_TICKET_ATTEMPTS=1 FOREMAN_FAKE_BEHAVIOUR=context-json run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "stops for a human"
  assert_contains "$OUT" "too large for one iteration" "diagnosed as a context failure"
  runlog="$(cat "$repo/batch/foreman-runs.log")"
  assert_contains "$runlog" "CONTEXT EXHAUSTED SIGNAL DETECTED" "recorded as context exhaustion"
  assert_missing "$runlog" "TRANSIENT ERROR SIGNAL DETECTED" "and not as a transient error"
fi

if case_is "an expired agent login stops the run at once, named, with no retry"; then
  # The payload carries "api_error_status": 401, which would read as transient and earn a
  # free second attempt. It must be classified as an auth failure instead.
  repo="$(make_repo 2 auth-repo)"
  FOREMAN_TICKET_ATTEMPTS=3 FOREMAN_FAKE_BEHAVIOUR=auth:land run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "stops for a human"
  assert_missing "$OUT" "(attempt 2)" "makes no second attempt"
  assert_contains "$OUT" "could not authenticate" "names the cause on the terminal"
  assert_eq "$(done_count "$repo")" "0" "nothing landed"
  runlog="$(cat "$repo/batch/foreman-runs.log")"
  assert_contains "$runlog" "AUTH FAILURE SIGNAL DETECTED" "recorded as an auth failure"
  assert_missing "$runlog" "TRANSIENT ERROR SIGNAL DETECTED" "and not as a transient error"
fi

if case_is "a dirty tree stops the run and is never auto-committed"; then
  # `dirty` is the loop's exact stall signature (see the "stall is salvaged" case below), so
  # a bare stall is normally rescued by a checkpoint turn rather than stopping here. Forcing
  # the checkpoint to fail too is what still exercises this stop — and the failure path is
  # the one an untested stop let rot before (ticket 01's wrong recovery text).
  repo="$(make_repo 2 dirty-repo)"
  FOREMAN_FAKE_BEHAVIOUR=dirty FOREMAN_FAKE_CHECKPOINT_BEHAVIOUR=fail \
    run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "exits needs-a-human"
  assert_contains "$OUT" "stalled" "the stall is named as such"
  assert_contains "$OUT" "checkpoint turn could not" "and so is the failed salvage attempt"
  assert_contains "$OUT" "Inspect with: git diff" "the adapter says where to look"
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "1" "committed nothing"

  # `fake` is a working-tree mode: the recovery advice is commit-and-rerun, printed once —
  # never alongside the sandbox's commit-inside-and-transport wording.
  assert_contains "$OUT" "git add -A && git commit -m 'wip:" "and how to recover it"
  assert_contains "$OUT" "run batch" "with the exact rerun command"
  assert_missing "$OUT" "sbx exec" "never the sandbox's advice"
fi

if case_is "a stall is salvaged by a checkpoint turn and the ticket continues"; then
  repo="$(make_repo 2 stall-repo)"
  log="$WORK/stall-prompts.txt"
  base="$(git -C "$repo" rev-parse HEAD)"
  FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=dirty:land \
    run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 0 "the batch still finishes"
  assert_contains "$OUT" "stalled" "the stall is named as such"
  assert_contains "$OUT" "salvaged by a checkpoint turn" "and so is the salvage"
  assert_eq "$(done_count "$repo")" "2" "both tickets land"
  assert_contains "$(git -C "$repo" log --format=%s)" "wip: batch/issues/01-ticket.md" \
    "the checkpoint's own commit is in the history"

  # The real checkpoint prompt is what the fake adapter saw — a sentinel phrase, not a side
  # channel — and it never consumed a slot of FOREMAN_FAKE_BEHAVIOUR's list.
  cp="$(awk '/^===== fake prompt checkpoint /{f=1;next} /^===== fake prompt /{f=0} f' "$log")"
  assert_contains "$cp" "CHECKPOINT TURN" "the checkpoint prompt is recognisable"
  assert_contains "$cp" "$base" "and diffs against the stalled turn's own base"
  assert_contains "$cp" "Remaining:" "and asks for the handoff note"
  assert_contains "$cp" "do not write, edit, or plan any more" "and not to continue the work"
  # A real one spent all its turns reading the diff a file at a time and never committed.
  assert_contains "$cp" "Your FIRST command is exactly:
   git add -A && git commit" "it commits on its first command, before reading anything"
  assert_contains "$cp" ".kotlin/" "and takes build output and caches back out"

  # The next real turn on this ticket is told it is continuing, same as a deliberate handoff
  # — but with the stall variant of the notice, not the deliberate one.
  p2="$(awk '/^===== fake prompt 2 /{f=1;next} /^===== fake prompt /{f=0} f' "$log")"
  assert_contains "$p2" "You are CONTINUING" "the following turn is told it is continuing"
  assert_contains "$p2" "reconstructed" "and that the handoff was reconstructed from the diff"
  assert_contains "$p2" "not of what was planned" "the Remaining: list is a description of what exists"
  assert_contains "$p2" "ran out of room" "and that the previous turn ran out of room"
  assert_missing "$p2" "A previous iteration did part of the work" \
    "not the deliberate-handoff wording"
fi

if case_is "a stall discovered after the cost budget was reached still gets salvaged, loudly"; then
  # Budget checks happen BEFORE an iteration starts; a stall is only discovered after one,
  # so the stalled turn's own cost is what pushes the run past its budget here — the
  # preflight check for this very iteration passed with $0 spent. The checkpoint turn runs
  # anyway (ticket 06): a budget limits what to commission, not whether to keep work already
  # paid for. --unlimited, so nothing but the budget stops the run.
  repo="$(make_repo 2 salvage-cost-repo)"
  FOREMAN_FAKE_COST=0.02 FOREMAN_MAX_COST_USD=0.01 FOREMAN_FAKE_BEHAVIOUR=dirty \
    run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 10 "still pauses — on the cost budget, not stopped for a human"
  assert_contains "$OUT" "stalled" "the stall is still named as such"
  assert_contains "$OUT" "salvaged by a checkpoint turn" "and still salvaged despite the budget"
  assert_contains "$OUT" "cost budget reached" "the eventual pause is still the cost budget"
  assert_eq "$(done_count "$repo")" "0" "the overshoot buys the checkpoint and nothing more"
  assert_contains "$OUT" "iterations run:        1" "no further iteration was commissioned"

  assert_contains "$OUT" "Note: a budget was overshot to salvage stalled work" \
    "the closing message owns the broken promise rather than staying silent"
  assert_contains "$OUT" "cost: \$0.040000 of \$0.01 budget (over by \$0.030000)" \
    "and says by how much"
fi

if case_is "a checkpoint turn that discards the diff is not mistaken for one that left it alone"; then
  # A clean tree with HEAD unmoved is ambiguous on its own — it is also what "did nothing"
  # looks like — but the tree WAS dirty going into this turn (that is how the stall was
  # detected), so coming back clean can only mean something discarded it. That is a worse
  # outcome than leaving it dirty, and deserves a message that does not imply the work is
  # still there to inspect.
  repo="$(make_repo 2 stall-discard-repo)"
  FOREMAN_FAKE_BEHAVIOUR=dirty FOREMAN_FAKE_CHECKPOINT_BEHAVIOUR=discard \
    run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "stops for a human"
  assert_contains "$OUT" "is gone" "says plainly that the work is gone"
  assert_missing "$OUT" "left uncommitted changes behind, and the checkpoint" \
    "not conflated with the still-dirty failure, which has something to inspect"
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "1" "nothing new was committed"
fi

if case_is "a turn that commits part of its work and then stalls is salvaged too"; then
  # The prompt asks for a wip: commit before the long checks, so a turn that stalls DURING
  # them has HEAD moved and its fixes uncommitted. That is still a stall, not a dirty stop.
  repo="$(make_repo 2 commit-stall-repo)"
  log="$WORK/commit-stall-prompts.txt"
  FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=commit-dirty:land \
    run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 0 "the batch still finishes"
  assert_contains "$OUT" "stalled" "the stall is named as such"
  assert_contains "$OUT" "salvaged by a checkpoint turn" "and salvaged"
  assert_missing "$OUT" "Stopping so you can look" "not stopped as a plain dirty tree"
  assert_eq "$(done_count "$repo")" "2" "both tickets land"
  subjects="$(git -C "$repo" log --format=%s)"
  assert_contains "$subjects" "verifying" "the turn's own wip commit is kept"
  assert_contains "$subjects" "remaining: the rest" "and the checkpoint's follows it"
  assert_contains "$(cat "$log")" "CHECKPOINT TURN" "a checkpoint turn ran"
fi

if case_is "a checkpoint that discards a partly committed stall is not mistaken for a salvage"; then
  # HEAD moved during the stalled turn, so HEAD != base after the checkpoint even though the
  # checkpoint itself committed nothing. Measured against HEAD before the checkpoint, it is
  # the discard it is.
  repo="$(make_repo 2 commit-stall-discard-repo)"
  FOREMAN_FAKE_BEHAVIOUR=commit-dirty FOREMAN_FAKE_CHECKPOINT_BEHAVIOUR=discard \
    run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "stops for a human"
  assert_contains "$OUT" "is gone" "says the uncommitted part is gone"
  assert_missing "$OUT" "salvaged by a checkpoint turn" "never reported as salvaged"
fi

if case_is "a partly committed stall the checkpoint cannot commit leaves a marker the rerun trusts"; then
  repo="$(make_repo 2 commit-stall-fail-repo)"
  marker="$repo/batch/.foreman-stall-marker"
  FOREMAN_FAKE_BEHAVIOUR=commit-dirty FOREMAN_FAKE_CHECKPOINT_BEHAVIOUR=fail \
    run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 20 "stops for a human"
  assert_contains "$(cat "$marker" 2>/dev/null)" "base_ref=$(git -C "$repo" rev-parse HEAD)" \
    "the marker vouches for HEAD as the stalled turn left it, past the base"

  FOREMAN_FAKE_BEHAVIOUR=land run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "a plain rerun reviews it and finishes"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "the tree ends clean"
fi

if case_is "the verify step gives the command time limit and forbids backgrounding"; then
  repo="$(make_repo 1 command-timeout-repo)"
  run_foreman "$repo" dry-run batch
  assert_contains "$OUT" "up to 60 minutes" "the default limit is named"
  assert_contains "$OUT" "at most 3600000 ms" "with the Bash tool's timeout in ms"
  assert_contains "$OUT" "Never background a check" "backgrounding is ruled out"
  assert_contains "$OUT" "wip: <ticket> — verifying" "and the work is committed before verifying"
  assert_missing "$OUT" "__COMMAND_TIMEOUT" "no marker is left behind"

  FOREMAN_COMMAND_TIMEOUT_MINUTES=90 run_foreman "$repo" dry-run batch
  assert_contains "$OUT" "up to 90 minutes" "the limit comes from the setting"
  assert_contains "$OUT" "at most 5400000 ms" "and so does the ms figure"

  for bad in 0 abc; do
    FOREMAN_COMMAND_TIMEOUT_MINUTES=$bad run_foreman "$repo" dry-run batch
    assert_eq "$ST" 1 "FOREMAN_COMMAND_TIMEOUT_MINUTES=$bad is refused"
    assert_contains "$OUT" "FOREMAN_COMMAND_TIMEOUT_MINUTES must be" "and says why ($bad)"
  done
fi

if case_is "both real adapters lift the agent's Bash time limit to the setting"; then
  # Neither can be run for real here, so each exec_run is called against a stub that prints
  # how it was invoked: `claude` for local, `sbx` for the two sandbox modes.
  stub="$WORK/agent-env-bin"; mkdir -p "$stub"
  printf '#!/bin/sh\necho "BASH_MAX_TIMEOUT_MS=$BASH_MAX_TIMEOUT_MS"\n' > "$stub/claude"
  printf '#!/bin/sh\necho "sbx $*"\n' > "$stub/sbx"
  chmod +x "$stub/claude" "$stub/sbx"
  run_for() {
    PATH="$stub:$PATH" FOREMAN_COMMAND_TIMEOUT_MINUTES=45 bash -c '
      FOREMAN_TOOL_DIR="$1/lib"
      source "$1/lib/foreman-exec.sh" && foreman_exec_load "$2" >/dev/null 2>&1 || exit 9
      FOREMAN_SANDBOX=foreman-env-test FOREMAN_MODEL=m FOREMAN_EFFORT=e FOREMAN_PERMISSION_MODE=p
      exec_run "the prompt" </dev/null
    ' _ "$FOREMAN_HOME" "$1"
  }
  assert_contains "$(run_for local)" "BASH_MAX_TIMEOUT_MS=2700000" "local: claude sees the raised limit"
  out="$(run_for sandbox)"
  assert_contains "$out" "sbx exec foreman-env-test env BASH_MAX_TIMEOUT_MS=2700000 claude" \
    "sandbox: claude inside the container is started with it"
fi

if case_is "the dirty-tree recovery note matches the mode actually in force"; then
  # Askable of a mode without running it, the same way foreman_exec_required_tool already is —
  # so this asserts each adapter's wording directly rather than only by triggering a real
  # stall under that mode (expensive or impossible for the two that need a real sandbox).
  note_for() {
    bash -c '
      source "$1/lib/foreman-exec.sh"
      FOREMAN_SANDBOX="foreman-note-test"
      FOREMAN_INVOKE="foreman"
      foreman_exec_dirty_recovery_note "$2" deadbeef batch/issues/01-ticket.md batch
    ' _ "$FOREMAN_HOME" "$1"
  }

  # sandbox-mount bind-mounts this working tree — the same filesystem, not a copy — so an
  # uncommitted change is already sitting right here; it needs the plain advice too, not a
  # bundle transport for something that never left.
  for mode in local fake sandbox-mount; do
    note="$(note_for "$mode")"
    assert_contains "$note" "git add -A && git commit -m 'wip:" "$mode: commit-and-rerun advice"
    assert_contains "$note" "run batch" "$mode: and the rerun command"
    assert_missing "$note" "sbx exec" "$mode: never mentions the sandbox"
  done

  note="$(note_for sandbox)"
  assert_contains "$note" "sbx exec foreman-note-test git commit" "sandbox: commit inside the sandbox"
  assert_contains "$note" "sbx cp foreman-note-test:" "sandbox: and transport the commit back out"
  assert_contains "$note" "run batch" "sandbox: then rerun"
  assert_missing "$note" "git add -A && git commit -m 'wip:" "sandbox: never the host-commit line"
fi

if case_is "the credentials reader finds a name in the file, and an environment variable beats it"; then
  # lookup NAME — the reader's answer, run the way every caller runs it: sourced, in a
  # subshell, so nothing it does can leak into this test.
  lookup() {
    bash -c 'source "$1/lib/foreman-credentials.sh"; foreman_credential "$2"' _ "$FOREMAN_HOME" "$1" 2>&1
  }
  # The operator's own values would beat the file and answer every lookup below.
  unset FOREMAN_DOCKER_USERNAME FOREMAN_DOCKER_PAT FOREMAN_CLAUDE_TOKEN
  creds="$WORK/creds-env"
  export FOREMAN_CREDENTIALS_FILE="$creds"

  # A missing file yields empty, not an error.
  OUT="$(lookup FOREMAN_DOCKER_USERNAME)"; ST=$?
  assert_eq "$ST" 0 "missing file: succeeds"
  assert_eq "$OUT" "" "missing file: empty"

  printf '%s\r\n' \
    '# the operator'"'"'s keys' \
    '' \
    'FOREMAN_DOCKER_USERNAME=someone' \
    'FOREMAN_DOCKER_PAT="dckr_pat_quoted"' \
    "FOREMAN_CLAUDE_TOKEN='sk-ant-single'" \
    '   # an indented comment' \
    'WITH_EQUALS=a=b=c' \
    'WITH_SPACE = spaced value  ' \
    'EMPTY=' > "$creds"
  printf 'LAST_LINE_NO_NEWLINE=tail' >> "$creds"

  assert_eq "$(lookup FOREMAN_DOCKER_USERNAME)" "someone" "a name present only in the file is found"
  assert_eq "$(lookup FOREMAN_DOCKER_PAT)" "dckr_pat_quoted" "CRLF endings and double quotes are stripped"
  assert_eq "$(lookup FOREMAN_CLAUDE_TOKEN)" "sk-ant-single" "single quotes are stripped"
  assert_eq "$(lookup WITH_EQUALS)" "a=b=c" "the value is everything after the first ="
  assert_eq "$(lookup WITH_SPACE)" "spaced value" "blanks around the name and value are trimmed"
  assert_eq "$(lookup LAST_LINE_NO_NEWLINE)" "tail" "a last line without a newline is read"
  assert_eq "$(lookup EMPTY)" "" "an empty value is empty"
  assert_eq "$(lookup NOT_THERE)" "" "an absent name is empty"
  assert_eq "$(lookup '# the operator')" "" "a comment is not a name"

  # The real environment wins over the file; an empty variable does not mask the file.
  OUT="$(FOREMAN_DOCKER_USERNAME=from-env lookup FOREMAN_DOCKER_USERNAME)"
  assert_eq "$OUT" "from-env" "an environment variable beats the file"
  OUT="$(FOREMAN_DOCKER_USERNAME= lookup FOREMAN_DOCKER_USERNAME)"
  assert_eq "$OUT" "someone" "an empty environment variable does not hide the file's value"

  # FOREMAN_CREDENTIALS_FILE moves the file; without it the file is ~/.config/foreman/env.
  printf 'FOREMAN_DOCKER_USERNAME=elsewhere\n' > "$WORK/other-creds"
  OUT="$(FOREMAN_CREDENTIALS_FILE="$WORK/other-creds" lookup FOREMAN_DOCKER_USERNAME)"
  assert_eq "$OUT" "elsewhere" "FOREMAN_CREDENTIALS_FILE moves the file"
  mkdir -p "$WORK/creds-home/.config/foreman"
  printf 'FOREMAN_DOCKER_USERNAME=from-home\n' > "$WORK/creds-home/.config/foreman/env"
  OUT="$(unset FOREMAN_CREDENTIALS_FILE; HOME="$WORK/creds-home" lookup FOREMAN_DOCKER_USERNAME)"
  assert_eq "$OUT" "from-home" "by default the file is ~/.config/foreman/env"
  OUT="$(unset FOREMAN_CREDENTIALS_FILE; HOME="$WORK/creds-home" bash -c \
    'source "$1/lib/foreman-credentials.sh"; foreman_credentials_file' _ "$FOREMAN_HOME")"
  assert_eq "$OUT" "$WORK/creds-home/.config/foreman/env" "the resolved path is available to callers"

  # Parsed as data, never sourced: nothing in the file may run.
  rm -f "$WORK/PWNED"
  printf '%s\n' \
    "FOREMAN_DOCKER_PAT=\$(touch $WORK/PWNED)" \
    "touch $WORK/PWNED" \
    "FOREMAN_CLAUDE_TOKEN=\`touch $WORK/PWNED\`" \
    "x[\$(touch $WORK/PWNED)]=1" \
    "FOO=bar; touch $WORK/PWNED" > "$creds"
  assert_eq "$(lookup FOREMAN_DOCKER_PAT)" "\$(touch $WORK/PWNED)" "shell code in a value is returned as text"
  assert_eq "$(lookup FOO)" "bar; touch $WORK/PWNED" "a trailing command is part of the value"
  lookup FOREMAN_CLAUDE_TOKEN >/dev/null
  lookup "x[\$(touch $WORK/PWNED)]" >/dev/null
  FOREMAN_DOCKER_PAT= lookup 'a[$(touch '"$WORK"'/PWNED)]' >/dev/null
  assert_eq "$([ -e "$WORK/PWNED" ] && echo executed || echo inert)" "inert" "no line of the file was executed"

  # A UTF-8 byte-order mark, as Windows editors write one, does not hide the first name.
  printf '\xEF\xBB\xBFFOREMAN_DOCKER_USERNAME=with-bom\r\nSECOND=ok\r\n' > "$creds"
  assert_eq "$(lookup FOREMAN_DOCKER_USERNAME)" "with-bom" "a byte-order mark on the first line is ignored"
  assert_eq "$(lookup SECOND)" "ok" "and the lines after it are unaffected"

  # The mask shows only the last four characters, and nothing at all of a short value.
  mask() { bash -c 'source "$1/lib/foreman-credentials.sh"; foreman_mask "$2"' _ "$FOREMAN_HOME" "$1"; }
  assert_eq "$(mask dckr_pat_abcdef1234)" "…1234" "a token is masked to …last4"
  assert_eq "$(mask short)" "…" "a short value shows nothing of itself"
  assert_eq "$(mask '')" "" "an empty value has no mask"
fi

if case_is "a sandbox that already exists is reused, and only a failed create is an error"; then
  # A stub `sbx` that knows of the sandboxes in $STUB_EXISTING (CRLF, as on Windows) and logs
  # each create, which succeeds or fails as $STUB_CREATE says.
  stub="$WORK/sbxcreate-bin"; mkdir -p "$stub"
  cat > "$stub/sbx" <<'STUB'
#!/bin/bash
case "$1" in
  ls)     for n in $STUB_EXISTING; do printf '%s\r\n' "$n"; done ;;
  create) printf '%s\n' "$*" >> "$STUB_LOG"
          [ "${STUB_CREATE:-ok}" = ok ] || { echo "error: no space left on device"; exit 1; } ;;
esac
STUB
  chmod +x "$stub/sbx"
  create_with() {    # create_with clone|mount
    PATH="$stub:$PATH" STUB_LOG="$WORK/create.log" FOREMAN_SANDBOX=foreman-x REPO_ROOT=/repo \
      bash -c '
        say() { printf "%s\n" "$*" >&2; }
        warn() { printf "%s\n" "$*" >&2; }
        warn_preflight() { warn "preflight: $*"; }
        source "$1/lib/exec/_sbx.sh"
        _sbx_create "$2"
      ' _ "$FOREMAN_HOME" "$1" 2>&1
  }

  rm -f "$WORK/create.log"
  OUT="$(STUB_EXISTING="other foreman-x" create_with clone)"; ST=$?
  assert_eq "$ST" 0 "an existing sandbox: succeeds"
  assert_eq "$OUT" "" "an existing sandbox: says nothing at all"
  assert_eq "$([ -e "$WORK/create.log" ] && echo called || echo not-called)" "not-called" \
    "an existing sandbox: sbx create is never run"

  OUT="$(STUB_EXISTING="foreman-xy" create_with clone)"; ST=$?
  assert_eq "$ST" 0 "a missing sandbox is created"
  assert_contains "$(cat "$WORK/create.log")" "create --clone --name foreman-x claude /repo" \
    "with --clone in clone mode"
  rm -f "$WORK/create.log"
  STUB_EXISTING="" create_with mount >/dev/null
  assert_missing "$(cat "$WORK/create.log")" "--clone" "and without it in mount mode"

  OUT="$(STUB_EXISTING="" STUB_CREATE=fail create_with clone)"; ST=$?
  assert_eq "$ST" 1 "a create that fails, leaving no sandbox, is an error"
  assert_contains "$OUT" "could not create sandbox 'foreman-x'" "and says so"
  assert_contains "$OUT" "no space left on device" "with what sbx said"
fi

if case_is "the clone's dirty check honours the .gitignore of the commit it is about to sync to"; then
  # The real sandbox adapter against a real clone: a stub `sbx` that runs `exec NAME sh -c`
  # inside $STUB_CLONE, so every git command is the one the sandbox would run.
  stub="$WORK/sbxdirty-bin"; mkdir -p "$stub"
  cat > "$stub/sbx" <<'STUB'
#!/bin/bash
[ "$1" = exec ] && [ "$3" = sh ] && [ "$4" = -c ] || exit 1
cd "$STUB_CLONE" && sh -c "$5"
STUB
  chmod +x "$stub/sbx"
  host="$WORK/dirty-host"; clone="$WORK/dirty-clone"
  rm -rf "$host" "$clone"
  git init -q "$host"
  printf 'build/\n' > "$host/.gitignore"; printf 'fun main() {}\n' > "$host/Main.kt"
  git -C "$host" add -A 2>/dev/null; git -C "$host" -c user.name=t -c user.email=t@t commit -qm init 2>/dev/null
  git clone -q "$host" "$clone"
  # What a Gradle build leaves behind, before anyone has thought to ignore it.
  mkdir -p "$clone/.kotlin/sessions"; printf 'x\n' > "$clone/.kotlin/sessions/s.salive"
  dirty_against() {    # dirty_against [TARGET] — prints dirty or clean
    PATH="$stub:$PATH" STUB_CLONE="$clone" FOREMAN_SANDBOX=foreman-x FOREMAN_EXEC_DIR="$FOREMAN_HOME/lib/exec" \
      bash -c '
        warn() { printf "%s\n" "$*" >&2; }
        source "$1/lib/exec/sandbox.sh"
        shift
        if exec_tree_dirty "$@"; then echo dirty; else echo clean; fi
      ' _ "$FOREMAN_HOME" "$@" 2>&1
  }

  assert_eq "$(dirty_against "$(git -C "$host" rev-parse HEAD)")" dirty \
    "an untracked cache nobody ignores yet is dirty"

  # The operator ignores it on the host. The clone is still on the old commit.
  printf 'build/\n.kotlin/\n' > "$host/.gitignore"
  git -C "$host" -c user.name=t -c user.email=t@t commit -qam "ignore .kotlin/" 2>/dev/null
  target="$(git -C "$host" rev-parse HEAD)"
  assert_eq "$(dirty_against "$target")" clean \
    "once the target commit ignores it, it no longer blocks the sync"
  assert_eq "$(dirty_against)" dirty "without a target, the clone's own rules still apply"

  printf 'class New\n' > "$clone/New.kt"
  assert_eq "$(dirty_against "$target")" dirty \
    "an untracked source file is still dirty: the sync's clean would delete it"
  rm -f "$clone/New.kt"
  printf 'fun main() { println() }\n' > "$clone/Main.kt"
  assert_eq "$(dirty_against "$target")" dirty "a modified tracked file is still dirty"
  git -C "$clone" checkout -q -- Main.kt

  # And the sync that now goes ahead leaves the cache alone: it is ignored at the target.
  PATH="$stub:$PATH" STUB_CLONE="$clone" FOREMAN_SANDBOX=foreman-x FOREMAN_EXEC_DIR="$FOREMAN_HOME/lib/exec" \
    bash -c 'warn() { :; }; source "$1/lib/exec/sandbox.sh"; exec_sync_down "$2"' _ "$FOREMAN_HOME" "$target"
  assert_eq "$(git -C "$clone" rev-parse HEAD)" "$target" "the sync then reaches the target"
  assert_eq "$([ -e "$clone/.kotlin/sessions/s.salive" ] && echo kept || echo wiped)" kept \
    "and keeps the now-ignored cache"
  assert_eq "$(dirty_against "$target")" clean "leaving a clean clone"
fi

if case_is "the sandbox adapters sign in to Docker with a token, only when asked to"; then
  # A stub `sbx` that records how it was called, so this needs no Docker account and the
  # token can be checked for the one property that matters: it is on stdin, not in argv.
  stub="$WORK/dockerlogin-bin"; mkdir -p "$stub"
  cat > "$stub/sbx" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" > "$STUB_ARGS"
cat > "$STUB_STDIN"
[ "${STUB_EXIT:-0}" -eq 0 ] || { echo "unauthorized: bad token"; exit 1; }
STUB
  chmod +x "$stub/sbx"
  login_with() {
    PATH="$stub:$PATH" STUB_ARGS="$WORK/login.args" STUB_STDIN="$WORK/login.stdin" \
      bash -c '
        warn() { printf "%s\n" "$*" >&2; }
        warn_preflight() { warn "preflight: $*"; }
        source "$1/lib/exec/_sbx.sh"
        _sbx_login
      ' _ "$FOREMAN_HOME" 2>&1
  }
  rm -f "$WORK/login.args" "$WORK/login.stdin"

  # Neither variable set: nothing changes from before — sbx is not even called.
  unset FOREMAN_DOCKER_USERNAME FOREMAN_DOCKER_PAT
  OUT="$(login_with)"; ST=$?
  assert_eq "$ST" 0 "no variables: succeeds"
  assert_eq "$([ -e "$WORK/login.args" ] && echo called || echo not-called)" "not-called" \
    "no variables: sbx login is not run"

  OUT="$(FOREMAN_DOCKER_USERNAME=someone login_with)"
  assert_eq "$([ -e "$WORK/login.args" ] && echo called || echo not-called)" "not-called" \
    "a username without a token: still not run"

  OUT="$(FOREMAN_DOCKER_USERNAME=someone FOREMAN_DOCKER_PAT=SECRET-TOKEN-123 login_with)"; ST=$?
  assert_eq "$ST" 0 "both set: succeeds"
  assert_contains "$(cat "$WORK/login.args")" "login --username someone --password-stdin" \
    "logs in non-interactively"
  assert_missing "$(cat "$WORK/login.args")" "SECRET-TOKEN-123" "the token is not on the command line"
  assert_eq "$(cat "$WORK/login.stdin")" "SECRET-TOKEN-123" "the token arrives on stdin"

  OUT="$(FOREMAN_DOCKER_USERNAME=someone FOREMAN_DOCKER_PAT=SECRET-TOKEN-123 STUB_EXIT=1 login_with)"
  assert_contains "$OUT" "could not sign in to Docker" "a rejected token is reported"
  assert_contains "$OUT" "unauthorized: bad token" "with what sbx said"
  assert_missing "$OUT" "SECRET-TOKEN-123" "and never echoes the token"

  # The same login from the credentials file, with nothing in the environment.
  creds="$WORK/login-creds"
  export FOREMAN_CREDENTIALS_FILE="$creds"
  printf '%s\r\n' '# docker' 'FOREMAN_DOCKER_USERNAME=filed-user' 'FOREMAN_DOCKER_PAT="FILE-TOKEN-456"' > "$creds"
  rm -f "$WORK/login.args" "$WORK/login.stdin"
  OUT="$(login_with)"; ST=$?
  assert_eq "$ST" 0 "file only: succeeds"
  assert_contains "$(cat "$WORK/login.args")" "login --username filed-user --password-stdin" \
    "file only: logs in as the file's username"
  assert_missing "$(cat "$WORK/login.args")" "FILE-TOKEN-456" "file only: the token is not on the command line"
  assert_eq "$(cat "$WORK/login.stdin")" "FILE-TOKEN-456" "file only: the token arrives on stdin"
  assert_missing "$OUT" "FILE-TOKEN-456" "file only: and is never printed"

  # The environment wins over the file, name by name.
  OUT="$(FOREMAN_DOCKER_PAT=ENV-TOKEN-789 login_with)"; ST=$?
  assert_contains "$(cat "$WORK/login.args")" "login --username filed-user" \
    "the file supplies the name the environment lacks"
  assert_eq "$(cat "$WORK/login.stdin")" "ENV-TOKEN-789" "an environment token beats the file's"

  # The file's token is rejected: said so, without the token.
  OUT="$(STUB_EXIT=1 login_with)"; ST=$?
  assert_eq "$ST" 1 "a rejected file token fails the preflight step"
  assert_contains "$OUT" "could not sign in to Docker as 'filed-user'" "a rejected file token is reported"
  assert_missing "$OUT" "FILE-TOKEN-456" "file only: a rejection never echoes the token"

  # A file with only half the pair is the same as no file: sbx is not called.
  printf 'FOREMAN_DOCKER_USERNAME=filed-user\n' > "$creds"
  rm -f "$WORK/login.args" "$WORK/login.stdin"
  OUT="$(login_with)"; ST=$?
  assert_eq "$ST" 0 "a file with a username only: succeeds"
  assert_eq "$([ -e "$WORK/login.args" ] && echo called || echo not-called)" "not-called" \
    "a file with a username only: sbx login is not run"

  # The token is read, never exported: a child of the login does not inherit it.
  printf 'FOREMAN_DOCKER_USERNAME=filed-user\nFOREMAN_DOCKER_PAT=FILE-TOKEN-456\n' > "$creds"
  cat > "$stub/sbx" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" > "$STUB_ARGS"
cat > "$STUB_STDIN"
env > "$STUB_ENV"
STUB
  STUB_ENV="$WORK/login.env" login_with >/dev/null
  assert_missing "$(cat "$WORK/login.env")" "FILE-TOKEN-456" "the token is not in sbx's environment"
fi

if case_is "syncing refuses over a dirty tree rather than resetting it"; then
  repo="$(make_repo 2 refuse-sync-repo)"

  # A clean tree syncs exactly as before, with no extra output.
  run_foreman "$repo" run batch 1
  assert_eq "$ST" 10 "clean tree: the iteration runs and pauses on the iteration budget"
  assert_eq "$(done_count "$repo")" "1" "clean tree: the ticket landed"
  assert_missing "$OUT" "Refusing to sync" "clean tree: no refusal text"

  # Leave the second ticket's tree dirty, as a stall would — and force the checkpoint turn
  # that would normally salvage a stall to fail too, so the tree is still dirty for the
  # rerun below to find. (The salvage path itself is covered by "a stall is salvaged by a
  # checkpoint turn and the ticket continues".)
  FOREMAN_FAKE_BEHAVIOUR=dirty FOREMAN_FAKE_CHECKPOINT_BEHAVIOUR=fail \
    run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 20 "the unsalvaged stall stops for a human"
  head_after_stall="$(git -C "$repo" rev-parse HEAD)"
  commits_after_stall="$(git -C "$repo" log --oneline | wc -l)"

  # The unsalvaged stall above left a marker, which a rerun would (rightly) trust and act
  # on — that path has its own cases below. Deleting the marker by hand is always safe, and
  # is exactly how to reach the refusal this case is about: a dirty tree nobody can vouch for.
  rm -f "$repo/batch/.foreman-stall-marker"

  # Rerunning is the natural response to any stop. FOREMAN_ALLOW_DIRTY=1 only waives the
  # PREFLIGHT gate on the review base (a different concern); it must not waive this
  # refusal, which exists so that "just rerun it" can never destroy the tree.
  log="$WORK/refuse-sync-prompts.txt"
  FOREMAN_ALLOW_DIRTY=1 FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=land \
    run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 20 "rerun over a dirty tree refuses rather than resetting"
  assert_contains "$OUT" "Refusing to sync" "says why it refused"
  assert_contains "$OUT" "git add -A && git commit -m 'wip:" "prints the mode's recovery note"
  assert_missing "$OUT" "sbx exec" "never the sandbox's advice"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_after_stall" "HEAD did not move"
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "$commits_after_stall" "nothing new was committed"
  [ -f "$log" ] && fail "the agent should never have been run" || pass
fi

# A stall the checkpoint turn could not salvage leaves a marker; that marker is the only
# thing that lets the NEXT run rescue the tree instead of refusing it. `fail` is what makes
# the stall unsalvaged in the first place. Prints the repo.
stalled_repo() {
  local repo
  repo="$(make_repo 2 "$1")"
  FOREMAN_FAKE_BEHAVIOUR=dirty FOREMAN_FAKE_CHECKPOINT_BEHAVIOUR=fail \
    run_foreman "$repo" run batch >/dev/null 2>&1
  printf '%s' "$repo"
}

if case_is "a rerun salvages the stalled work its own previous run left behind"; then
  repo="$(make_repo 2 rerun-salvage-repo)"
  marker="$repo/batch/.foreman-stall-marker"
  base="$(git -C "$repo" rev-parse HEAD)"

  FOREMAN_FAKE_BEHAVIOUR=dirty FOREMAN_FAKE_CHECKPOINT_BEHAVIOUR=fail \
    run_foreman "$repo" run batch
  assert_eq "$ST" 20 "the unsalvaged stall stops for a human"
  [ -f "$marker" ] && pass || fail "the unsalvaged stall records a marker"
  assert_contains "$(cat "$marker" 2>/dev/null)" "batch/issues/01-ticket.md" "it names the ticket"
  assert_contains "$(cat "$marker" 2>/dev/null)" "$base" "and the base ref"
  assert_contains "$(cat "$marker" 2>/dev/null)" "foreman-rerun-salvage-repo" "and the sandbox"
  [ -n "$(git -C "$repo" status --porcelain)" ] && pass || fail "the work is still uncommitted"

  # No FOREMAN_ALLOW_DIRTY here: "just rerun it" has to be true as typed.
  log="$WORK/rerun-salvage-prompts.txt"
  FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=land \
    run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "the rerun finishes the batch"
  assert_eq "$(done_count "$repo")" "2" "both tickets land"
  assert_contains "$OUT" "salvaged by a checkpoint turn" "the rescue is announced"
  assert_contains "$(git -C "$repo" log --format=%s)" "wip: batch/issues/01-ticket.md" \
    "the stalled work was committed by the checkpoint turn"
  [ -e "$marker" ] && fail "the marker is gone once the checkpoint succeeded" || pass
  assert_eq "$(git -C "$repo" status --porcelain)" "" "the tree ends clean"
  assert_contains "$OUT" "iterations run:        2" "the rescue does not spend an iteration"

  # The rescue ran BEFORE the ticket's own turn, so that turn is told it is continuing —
  # and told the stall variant, since the handoff was reconstructed from a diff.
  first="$(awk '/^===== fake prompt checkpoint /{f=1;next} /^===== fake prompt /{f=0} f' "$log")"
  assert_contains "$first" "CHECKPOINT TURN" "a checkpoint turn ran first"
  p1="$(awk '/^===== fake prompt 1 /{f=1;next} /^===== fake prompt /{f=0} f' "$log")"
  assert_contains "$p1" "You are CONTINUING" "the ticket's turn is a continuation"
  assert_contains "$p1" "ran out of room" "told the earlier turn ran out of room"
  assert_contains "$p1" "reconstructed" "and that the handoff was reconstructed"
  assert_contains "$p1" "$base" "and reviewed against the commit the stall began from"
fi

if case_is "a rerun with no stall marker refuses rather than rescuing, and deleting the marker is safe"; then
  repo="$(stalled_repo rerun-no-marker-repo)"
  marker="$repo/batch/.foreman-stall-marker"
  [ -f "$marker" ] && pass || fail "the stall left a marker to delete"
  rm -f "$marker"

  head_before="$(git -C "$repo" rev-parse HEAD)"
  log="$WORK/rerun-no-marker-prompts.txt"
  FOREMAN_ALLOW_DIRTY=1 FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=land \
    run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 20 "no marker: refuses and stops for a human"
  assert_contains "$OUT" "Refusing to sync" "says why"
  assert_contains "$OUT" "--adopt-dirty" "and names the flag that would review it instead"
  assert_contains "$OUT" "git add -A && git commit -m 'wip:" "and prints the recovery note"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_before" "nothing was committed"
  [ -f "$log" ] && fail "no agent turn of any kind may run" || pass
  [ -n "$(git -C "$repo" status --porcelain)" ] && pass || fail "the work is untouched"

  # Without the override the preflight has its say first, exactly as it always did.
  run_foreman "$repo" run batch
  assert_eq "$ST" 1 "a dirty tree nobody vouches for still fails the preflight"
fi

if case_is "a marker that does not match the dirty tree is never trusted"; then
  # Each of these is a marker the loop wrote about a DIFFERENT situation than the one it
  # finds now: another sandbox's stall, another commit's, another ticket's. The sandbox is
  # per repository, so a dirty tree may be another batch's stall or a human's own session.
  for field in sandbox base_ref ticket; do
    repo="$(stalled_repo "rerun-mismatch-$field-repo")"
    marker="$repo/batch/.foreman-stall-marker"
    case "$field" in
      sandbox)  sed -i 's|^sandbox=.*|sandbox=some-other-sandbox|' "$marker" ;;
      base_ref) sed -i 's|^base_ref=.*|base_ref=0000000000000000000000000000000000000000|' "$marker" ;;
      ticket)   sed -i 's|^ticket=.*|ticket=batch/issues/02-ticket.md|' "$marker" ;;
    esac

    head_before="$(git -C "$repo" rev-parse HEAD)"
    log="$WORK/rerun-mismatch-$field-prompts.txt"
    FOREMAN_ALLOW_DIRTY=1 FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=land \
      run_foreman "$repo" run batch --unlimited
    assert_eq "$ST" 20 "$field mismatch: refuses"
    assert_contains "$OUT" "Refusing to sync" "$field mismatch: says why"
    assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_before" "$field mismatch: nothing committed"
    [ -f "$log" ] && fail "$field mismatch: no agent turn may run" || pass
    [ -n "$(git -C "$repo" status --porcelain)" ] && pass || fail "$field mismatch: work untouched"
  done
fi

if case_is "a rerun whose rescue fails stops for a human and keeps the marker"; then
  repo="$(stalled_repo rerun-rescue-fails-repo)"
  marker="$repo/batch/.foreman-stall-marker"
  head_before="$(git -C "$repo" rev-parse HEAD)"

  FOREMAN_FAKE_BEHAVIOUR=land FOREMAN_FAKE_CHECKPOINT_BEHAVIOUR=fail \
    run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 20 "a rescue that cannot commit stops for a human"
  assert_contains "$OUT" "could not" "and says the checkpoint turn failed"
  assert_contains "$OUT" "git add -A && git commit -m 'wip:" "with the adapter's recovery note"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_before" "nothing was committed"
  assert_eq "$(done_count "$repo")" "0" "the ticket's own turn never ran"
  [ -f "$marker" ] && pass || fail "the stall is still unsalvaged, so it is still marked"

  # ...which is what makes the next rerun's rescue possible once the cause is fixed.
  FOREMAN_FAKE_BEHAVIOUR=land run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "a later rerun rescues it"
  assert_eq "$(done_count "$repo")" "2" "and finishes the batch"
  [ -e "$marker" ] && fail "the marker is gone" || pass
fi

if case_is "a marker is removed once the tree is clean, and a salvaged stall leaves none"; then
  repo="$(stalled_repo rerun-clean-repo)"
  marker="$repo/batch/.foreman-stall-marker"

  # The operator rescues it by hand, as the recovery note says, and reruns.
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "wip: by hand"
  FOREMAN_FAKE_BEHAVIOUR=land run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "a hand-rescued tree runs normally"
  assert_missing "$OUT" "Refusing to sync" "no refusal"
  [ -e "$marker" ] && fail "a clean tree retires the marker" || pass

  # A stall the checkpoint turn DID salvage was never left unsalvaged, so it never marks.
  repo="$(make_repo 2 salvaged-no-marker-repo)"
  FOREMAN_FAKE_BEHAVIOUR=dirty:land run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "a salvaged stall finishes the batch"
  [ -e "$repo/batch/.foreman-stall-marker" ] && fail "a salvaged stall records no marker" || pass
fi

# A run stopped part-way through a turn — a usage limit, or Ctrl-C — with the turn's work
# uncommitted. The marker written before the turn is what lets the next run review it. Prints
# the repo; the first argument is the fake behaviour that stops it.
stopped_mid_turn_repo() {
  local repo
  repo="$(make_repo 2 "$2")"
  FOREMAN_FAKE_BEHAVIOUR="$1" run_foreman "$repo" run batch --unlimited >/dev/null 2>&1
  printf '%s' "$repo"
}

# The whole round trip for one way of stopping: the stop leaves a marker beside the dirty
# tree, and a plain rerun reviews it, commits it as wip and carries on.
check_stopped_mid_turn_resumes() {    # check_stopped_mid_turn_resumes FAKE_BEHAVIOUR
    local stop="$1" repo marker base log first
    repo="$(make_repo 2 "$stop-repo")"
    marker="$repo/batch/.foreman-stall-marker"
    base="$(git -C "$repo" rev-parse HEAD)"

    FOREMAN_FAKE_BEHAVIOUR="$stop" run_foreman "$repo" run batch --unlimited
    assert_eq "$ST" 10 "$stop: the run pauses, resumable"
    [ -f "$marker" ] && pass || fail "$stop: the turn's marker is left behind"
    assert_contains "$(cat "$marker" 2>/dev/null)" "batch/issues/01-ticket.md" "$stop: it names the ticket"
    assert_contains "$(cat "$marker" 2>/dev/null)" "$base" "$stop: and the base ref"
    [ -n "$(git -C "$repo" status --porcelain)" ] && pass || fail "$stop: the work is still uncommitted"

    # "Just rerun it", as the footer says — no flag, no override.
    log="$WORK/$stop-prompts.txt"
    FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=land \
      run_foreman "$repo" run batch --unlimited
    assert_eq "$ST" 0 "$stop: the rerun finishes the batch"
    assert_eq "$(done_count "$repo")" "2" "$stop: both tickets land"
    assert_contains "$OUT" "reviewed and salvaged by a checkpoint turn" "$stop: the rescue is announced"
    assert_missing "$OUT" "Refusing to sync" "$stop: no refusal"
    assert_contains "$(git -C "$repo" log --format=%s)" "wip: batch/issues/01-ticket.md" \
      "$stop: the leftover work was committed as wip"
    [ -e "$marker" ] && fail "$stop: the marker is gone" || pass
    assert_eq "$(git -C "$repo" status --porcelain)" "" "$stop: the tree ends clean"
    assert_contains "$OUT" "iterations run:        2" "$stop: the review turn spends no iteration"
    first="$(awk '/^===== fake prompt checkpoint /{f=1;next} /^===== fake prompt /{f=0} f' "$log")"
    assert_contains "$first" "REVIEW CHECKPOINT TURN" "$stop: it was the review turn, not the stall's"
    assert_contains "$first" "do not run builds, tests" "$stop: which reads the diff only"
}

if case_is "a run paused by a usage limit mid-turn is reviewed and continued by the next run"; then
  check_stopped_mid_turn_resumes limit-dirty
fi

if case_is "a run interrupted mid-turn is reviewed and continued by the next run"; then
  check_stopped_mid_turn_resumes interrupt-dirty
fi

# The two checkpoint modes have different turn limits: a stall commits blind, a review must
# read the ticket, the diff and the new files first. The fake adapter logs the args each call
# was given, the --max-turns a real adapter would pass to claude.
if case_is "a review checkpoint gets a higher turn limit than a stall checkpoint"; then
  repo="$(make_repo 2 max-turns-stall-repo)"
  log="$WORK/max-turns-stall-prompts.txt"
  FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=dirty:land \
    run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "the stalled batch finishes"
  args="$(awk '/^===== fake prompt checkpoint /{getline; print; exit}' "$log")"
  assert_contains "$args" "--max-turns" "the checkpoint is given a turn limit"
  assert_eq "${args##*--max-turns }" "10" "a stall checkpoint is capped at 10 turns"
  args="$(awk '/^===== fake prompt 2 /{getline; print; exit}' "$log")"
  assert_missing "$args" "--max-turns" "and the next ordinary turn does not inherit the cap"

  repo="$(stopped_mid_turn_repo limit-dirty max-turns-review-repo)"
  log="$WORK/max-turns-review-prompts.txt"
  FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=land \
    run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "the reviewed batch finishes"
  assert_contains "$(cat "$log")" "REVIEW CHECKPOINT TURN" "a review checkpoint ran"
  args="$(awk '/^===== fake prompt checkpoint /{getline; print; exit}' "$log")"
  assert_contains "$args" "--max-turns" "the checkpoint is given a turn limit"
  assert_eq "${args##*--max-turns }" "20" "a review checkpoint is capped at 20 turns"
  args="$(awk '/^===== fake prompt 1 /{getline; print; exit}' "$log")"
  assert_missing "$args" "--max-turns" "and the first ordinary turn does not inherit the cap"
fi

if case_is "a turn that ends cleanly, or pauses with a clean tree, leaves no marker"; then
  repo="$(make_repo 2 no-marker-clean-repo)"
  run_foreman "$repo" run batch 1
  assert_eq "$ST" 10 "a landed iteration pauses on the budget"
  [ -e "$repo/batch/.foreman-stall-marker" ] && fail "a landed turn leaves no marker" || pass

  FOREMAN_FAKE_BEHAVIOUR=limit run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 10 "a usage limit with nothing written pauses"
  [ -e "$repo/batch/.foreman-stall-marker" ] && fail "a clean limit leaves no marker" || pass
fi

if case_is "a review turn that refuses the leftover work stops for a human and leaves it alone"; then
  repo="$(stopped_mid_turn_repo limit-dirty review-rejects-repo)"
  marker="$repo/batch/.foreman-stall-marker"
  [ -f "$marker" ] && pass || fail "the stopped turn left a marker"
  head_before="$(git -C "$repo" rev-parse HEAD)"
  dirty_before="$(git -C "$repo" status --porcelain)"

  FOREMAN_FAKE_BEHAVIOUR=land FOREMAN_FAKE_CHECKPOINT_BEHAVIOUR=reject \
    run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 20 "a refusal stops for a human"
  assert_contains "$OUT" "refused to commit" "says the review refused"
  assert_contains "$OUT" "changes outside the ticket's scope" "with the reviewer's reasons"
  assert_contains "$OUT" "git add -A && git commit -m 'wip:" "and the recovery note"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_before" "nothing was committed"
  assert_eq "$(git -C "$repo" status --porcelain)" "$dirty_before" "the tree is untouched"
  assert_eq "$(done_count "$repo")" "0" "the ticket's own turn never ran"
  [ -e "$marker" ] && fail "a refusal retires the marker, so a rerun does not pay for it again" || pass

  # ...so a plain rerun now refuses, and names the flag that would review it anyway.
  log="$WORK/review-rejects-prompts.txt"
  FOREMAN_ALLOW_DIRTY=1 FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=land \
    run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 20 "the rerun refuses"
  assert_contains "$OUT" "Refusing to sync" "says why"
  assert_contains "$OUT" "--adopt-dirty" "and offers --adopt-dirty"
  [ -f "$log" ] && fail "no agent turn of any kind may run" || pass
fi

if case_is "--adopt-dirty reviews and commits a dirty tree no marker vouches for"; then
  repo="$(stalled_repo adopt-dirty-repo)"
  rm -f "$repo/batch/.foreman-stall-marker"
  [ -n "$(git -C "$repo" status --porcelain)" ] && pass || fail "the tree is dirty and unmarked"

  # No FOREMAN_ALLOW_DIRTY: the flag is the operator vouching for the tree, preflight included.
  log="$WORK/adopt-dirty-prompts.txt"
  FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=land \
    run_foreman "$repo" run batch --unlimited --adopt-dirty
  assert_eq "$ST" 0 "the adopted tree is reviewed and the batch finishes"
  assert_contains "$OUT" "--adopt-dirty says" "it says why it trusted the tree"
  assert_contains "$OUT" "reviewed and salvaged by a checkpoint turn" "the rescue is announced"
  assert_contains "$(git -C "$repo" log --format=%s)" "wip: batch/issues/01-ticket.md" \
    "the adopted work was committed as wip"
  assert_eq "$(done_count "$repo")" "2" "both tickets land"
  first="$(awk '/^===== fake prompt checkpoint /{f=1;next} /^===== fake prompt /{f=0} f' "$log")"
  assert_contains "$first" "REVIEW CHECKPOINT TURN" "through the review turn"

  # On a clean tree the flag changes nothing.
  repo="$(make_repo 1 adopt-clean-repo)"
  run_foreman "$repo" run batch --adopt-dirty
  assert_eq "$ST" 0 "a clean tree runs as usual under --adopt-dirty"
  assert_missing "$OUT" "earlier run" "and no rescue is attempted"
fi

if case_is "--live draws what the agent is doing, and only that"; then
  # Once exec_run is invoked the terminal is silent until it returns. Writes and shell
  # commands are the two signals worth drawing; reads, greps and globs are the majority of
  # the traffic and say nothing about progress.
  # Two tickets, one iteration: the second is what the dry-run below has left to plan for.
  repo="$(make_repo 2 live-repo)"
  FOREMAN_FAKE_BEHAVIOUR=stream run_foreman "$repo" run batch --live

  assert_contains "$OUT" "Write src/foo.js" "a file write is drawn"
  assert_contains "$OUT" "Bash npm test" "and a shell command"
  assert_missing "$OUT" "src/quiet-read.js" "a read is not"
  # A tool_use event carries the WHOLE input — a Write carries the entire file body.
  assert_missing "$OUT" "SECRET-BODY-CONTENT" "the input object never reaches the terminal"
  assert_missing "$OUT" "TAIL-SENTINEL" "and a long argument is truncated"
  assert_eq "$(done_count "$repo")" "1" "the ticket still lands"

  # Which --output-format the adapter would ask for is the other decision `fake` cannot
  # exercise, so dry-run reports the state that decides it.
  run_foreman "$repo" dry-run batch
  assert_contains "$OUT" "Live:    off" "dry-run says a plain run is not watched"
  run_foreman "$repo" dry-run batch --live
  assert_contains "$OUT" "Live:    on" "and that a --live one is"
fi

if case_is "a --live run that produces no result object still says what it saw"; then
  # Verified against a real sandbox: when the agent fails to start, `sbx` prints its own
  # banner and `ERROR: agent exited with code 1`, and claude's error text never appears.
  # All of it is non-JSON, so the filter drops every line and the payload is empty — and the
  # recorder only dumps a raw payload when there is one, leaving the human with "payload was
  # not valid JSON" and nothing to read. The tail is what keeps that diagnosable.
  repo="$(make_repo 1 live-noresult)"
  FOREMAN_FAKE_BEHAVIOUR=stream-no-result run_foreman "$repo" run batch --live

  runlog="$(cat "$repo/batch/foreman-runs.log")"
  assert_contains "$runlog" "RAW PAYLOAD" "the log dumps what did arrive"
  assert_contains "$runlog" "SANDBOX-ERROR-SENTINEL" "including the error the sandbox printed"
  assert_contains "$OUT" "printed no result object" "and the run says so as it happens"
  assert_eq "$(done_count "$repo")" "0" "nothing is claimed to have landed"
fi

if case_is "--live changes nothing about the verdict or the recorded usage"; then
  # The assertion that protects the payload path: the filter sits in the pipeline in both
  # modes, and in the plain one it is a pass-through.
  plain="$(make_repo 2 live-equiv-plain)"
  lively="$(make_repo 2 live-equiv-live)"

  FOREMAN_FAKE_COST=0.25 run_foreman "$plain" run batch --unlimited
  plain_out="$OUT"; plain_st="$ST"
  FOREMAN_FAKE_COST=0.25 run_foreman "$lively" run batch --unlimited --live
  assert_eq "$ST" "$plain_st" "the same exit status"
  assert_eq "$(done_count "$lively")" "$(done_count "$plain")" "the same tickets land"

  # The footer is the run's whole verdict and every usage figure in one block.
  footer() { printf '%s' "$1" | sed -n '/^== run /,$p' | grep -v '^== run '; }
  assert_eq "$(footer "$OUT")" "$(footer "$plain_out")" "and identical usage figures"
fi

if case_is "a ticket that hands off part-finished is continued, not failed"; then
  # `claude --print` is one turn. A ticket whose work exceeds that turn's output budget ends
  # exit 0, subtype success, no error anywhere, with the deliverable half-written — and used
  # to stop the run as "still not implemented", so the next run redid the work from scratch.
  repo="$(make_repo 2 partial-repo)"
  log="$WORK/partial-prompts.txt"
  base="$(git -C "$repo" rev-parse HEAD)"
  FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=partial-turn:land \
    run_foreman "$repo" run batch --unlimited

  assert_contains "$OUT" "⋯ progressed" "the checkpoint reads as progress"
  assert_missing "$OUT" "is still not 'implemented'" "and not as a failure"
  assert_missing "$OUT" "(attempt 2)" "progress does not spend an attempt"
  assert_eq "$(done_count "$repo")" "2" "the ticket lands on the continuation"

  # The continuation is told, and is reviewed against the ticket's FIRST base rather than
  # its own last chunk — otherwise chunking silently produces unreviewed code.
  p1="$(awk '/^===== fake prompt 1 /{f=1;next} /^===== fake prompt /{f=0} f' "$log")"
  p2="$(awk '/^===== fake prompt 2 /{f=1;next} /^===== fake prompt /{f=0} f' "$log")"
  assert_missing "$p1" "You are CONTINUING" "the first attempt is not told"
  assert_contains "$p2" "You are CONTINUING" "the second one is"
  assert_contains "$p2" "$base" "and reviews against the ticket's first base"

  # A deliberate handoff is not told its notice was reconstructed from a stall — that
  # variant is only for a continuation that followed a checkpoint turn's salvage.
  assert_missing "$p2" "reconstructed" "the deliberate-handoff notice is unchanged"
  assert_missing "$p2" "ran out of room" "and does not carry the stall's context-retry framing"

  run_foreman "$repo" report DONE_batch
  assert_contains "$OUT" "progressed 1" "the report counts it as its own outcome"
  run_foreman "$repo" report DONE_batch --failures
  assert_contains "$OUT" "every recorded iteration landed" "and does not flag it as a problem"
fi

if case_is "a ticket that never stops chunking is called mis-sized"; then
  repo="$(make_repo 2 continuation-cap-repo)"
  FOREMAN_MAX_CONTINUATIONS=3 FOREMAN_FAKE_BEHAVIOUR=partial-turn \
    run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "stops for a human rather than chunking forever"
  assert_contains "$OUT" "has needed 3 extra turns without landing" "counts the continuations"
  assert_contains "$OUT" "(3 progressed, 0 stalled)" "and breaks down how many were which"
  assert_contains "$OUT" "split it into smaller tickets" "says what to do about it"
  assert_eq "$(done_count "$repo")" "0" "nothing landed"
fi

if case_is "a ticket that never stops stalling hits the same cap, broken down as stalls"; then
  # Stalls and deliberate handoffs feed the SAME continuation cap — there is no separate
  # stall budget — but the message must not call a ticket that only ever stalled
  # "progressed".
  repo="$(make_repo 2 stall-cap-repo)"
  FOREMAN_MAX_CONTINUATIONS=2 FOREMAN_FAKE_BEHAVIOUR=dirty \
    run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "stops for a human rather than salvaging forever"
  assert_contains "$OUT" "has needed 2 extra turns without landing" "counts the stalls as continuations too"
  assert_contains "$OUT" "(0 progressed, 2 stalled)" "and says they were all stalls"
  assert_contains "$OUT" "split it into smaller tickets" "still advises splitting the ticket"
  assert_eq "$(done_count "$repo")" "0" "nothing landed"
fi

if case_is "a progressed iteration does not consume a ticket's attempts"; then
  repo="$(make_repo 2 progress-attempts-repo)"
  FOREMAN_TICKET_ATTEMPTS=2 FOREMAN_FAKE_BEHAVIOUR=partial-turn:noop \
    run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "the unproductive iteration stops the run"
  assert_contains "$OUT" "after 1 attempt(s)" "only the unproductive one was counted"
fi

if case_is "a stalled iteration does not consume a ticket's attempts"; then
  repo="$(make_repo 2 stall-attempts-repo)"
  FOREMAN_FAKE_BEHAVIOUR=dirty:noop run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "the unproductive iteration after the salvage stops the run"
  assert_contains "$OUT" "salvaged by a checkpoint turn" "the stall itself was salvaged, not attempted"
  # If the stall had spent an attempt, this would read "after 2 attempt(s)" instead.
  assert_contains "$OUT" "after 1 attempt(s)" "only the unproductive attempt after it was counted"
fi

if case_is "a checkpoint turn is recorded as its own row and its cost is in the run total"; then
  repo="$(make_repo 2 checkpoint-cost-repo)"
  FOREMAN_FAKE_COST=0.10 FOREMAN_FAKE_BEHAVIOUR=dirty:land \
    run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 0 "the batch still finishes"
  assert_eq "$(done_count "$repo")" "2" "both tickets land"

  # 4 turns actually ran (stall, its checkpoint, and one landing turn per ticket), but the
  # checkpoint is not one of the 3 iterations the operator commissioned.
  assert_contains "$OUT" "iterations run:        3" "the checkpoint turn does not advance the iteration count"
  assert_contains "$OUT" "cost (USD, reported):  \$0.400000" "but its cost is folded into the run total"

  jsonl="$repo/DONE_batch/foreman-runs.jsonl"
  assert_eq "$(grep -c . "$jsonl")" "4" "all 4 turns are recorded"
  assert_eq "$(grep -c '"kind":"checkpoint"' "$jsonl")" "1" "one of them is its own, distinguishable row"

  run_foreman "$repo" report DONE_batch
  assert_contains "$OUT" "stalled 1" "the report counts the stall as its own outcome"
  assert_contains "$OUT" "checkpoint turns 1" "and the checkpoint as its own bucket"
  assert_contains "$OUT" '$0.4000' "totalling all 4 turns' cost"

  run_foreman "$repo" report DONE_batch --failures
  assert_contains "$OUT" "every recorded iteration landed" "a salvaged stall is not flagged as a failure"
fi

if case_is "the prompt tells the agent how to hand a ticket off"; then
  repo="$(make_repo 1 handoff-prompt-repo)"
  printf 'FOREMAN_CONTEXT_BUDGET_TOKENS=123456\n' >> "$repo/batch/foreman.conf"
  git -C "$repo" commit --quiet -am "context budget"

  run_foreman "$repo" dry-run batch
  assert_eq "$ST" 0 "dry-run exits 0"
  assert_contains "$OUT" "123456 tokens of context" "the budget comes from foreman.conf"
  assert_contains "$OUT" "wip: <ticket>" "the handoff names the commit shape"
  assert_contains "$OUT" "Remaining:" "and the note it has to leave"
  assert_missing "$OUT" "__CONTEXT_BUDGET__" "the marker is not left behind"
fi

if case_is "a denied tool call names permissions, not the dirty tree it caused"; then
  # `acceptEdits` does not cover Bash, and `claude --print` has no one to approve one, so a
  # batch with no git allowlist gets the ticket's work done and then cannot commit it. The
  # tree is dirty as a CONSEQUENCE; before this the dirty branch won and the terminal never
  # mentioned permissions at all.
  repo="$(make_repo 2 permdenied-repo)"
  FOREMAN_FAKE_BEHAVIOUR=permission-denied run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 20 "exits needs-a-human"
  assert_contains "$OUT" "stopped by a permission denial" "names the real cause"
  assert_contains "$OUT" 'Bash(git commit:*)' "and the exact foreman.conf line that fixes it"
  assert_missing "$OUT" "left uncommitted changes behind" "not reported as a plain dirty tree"
  # The stall branch sits BELOW this one: a denied `git commit` dirties the tree as a
  # consequence, and a checkpoint turn salvaging it would report the symptom, never the
  # cause.
  assert_missing "$OUT" "stalled" "and no checkpoint turn is attempted either"
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "1" "committed nothing"

  runlog="$(cat "$repo/batch/foreman-runs.log")"
  assert_contains "$runlog" "PERMISSION DENIED SIGNAL DETECTED" "recorded as its own signal"
fi

if case_is "the permission mode defaults to what the execution mode needs"; then
  # Not reachable through `fake`, which never invokes `claude` — which is exactly why
  # dry-run reports the effective mode. Inside a sandbox the container is the boundary and
  # the gate only costs a paid iteration; on a real machine `local` keeps its gate.
  repo="$(make_repo 1 perms-repo)"

  printf 'FOREMAN_EXEC=local\n' >> "$repo/batch/foreman.conf"
  git -C "$repo" commit --quiet -am "local mode"
  run_foreman "$repo" dry-run batch
  assert_eq "$ST" 0 "dry-run exits 0"
  assert_contains "$OUT" "Perms:   acceptEdits" "local keeps the permission gate"

  printf 'FOREMAN_EXEC=sandbox\n' >> "$repo/batch/foreman.conf"
  git -C "$repo" commit --quiet -am "sandbox mode"
  run_foreman "$repo" dry-run batch
  assert_contains "$OUT" "Perms:   bypassPermissions" "a sandbox mode does not"

  printf 'FOREMAN_PERMISSION_MODE=plan\n' >> "$repo/batch/foreman.conf"
  git -C "$repo" commit --quiet -am "explicit mode"
  run_foreman "$repo" dry-run batch
  assert_contains "$OUT" "Perms:   plan" "an explicit setting beats the default"

  FOREMAN_PERMISSION_MODE=manual run_foreman "$repo" dry-run batch
  assert_contains "$OUT" "Perms:   manual" "and the environment beats foreman.conf"
fi

if case_is "the model defaults to a pinned full id, and foreman.conf and the environment still override it"; then
  # A full id, not the `sonnet` alias: the alias is resolved by the claude CLI that runs the
  # call, and the sandbox's can be older than the host's. dry-run reports the effective model
  # for the same reason it reports the permission mode — `fake` never invokes `claude`.
  repo="$(make_repo 1 model-repo)"

  run_foreman "$repo" dry-run batch
  assert_eq "$ST" 0 "dry-run exits 0"
  assert_contains "$OUT" "Model:   claude-sonnet-5-5 " "the default is the pinned full id"
  assert_missing "$OUT" "Model:   sonnet" "not the alias"

  printf 'FOREMAN_MODEL=claude-opus-5-5\n' >> "$repo/batch/foreman.conf"
  git -C "$repo" commit --quiet -am "explicit model"
  run_foreman "$repo" dry-run batch
  assert_contains "$OUT" "Model:   claude-opus-5-5 " "a FOREMAN_MODEL in foreman.conf beats the default"

  FOREMAN_MODEL=haiku run_foreman "$repo" dry-run batch
  assert_contains "$OUT" "Model:   haiku " "and the environment beats foreman.conf"
fi

if case_is "doctor flags a local batch whose agent could never commit"; then
  repo="$WORK/perm-doctor-repo"
  mkdir -p "$repo/batch/issues"
  git -C "$repo" init --quiet
  printf '# Ticket 1\n\n**Status:** todo\n' > "$repo/batch/issues/01-ticket.md"
  printf 'FOREMAN_EXEC=local\n' > "$repo/batch/foreman.conf"

  run_foreman "$repo" doctor
  assert_eq "$ST" 1 "doctor reports something to fix"
  assert_contains "$OUT" "no way for the agent to commit" "says what is wrong"
  assert_contains "$OUT" 'Bash(git add:*)' "and the line to add"

  printf 'FOREMAN_CLAUDE_ARGS=(--allowed-tools "Bash(git add:*)" "Bash(git commit:*)")\n' \
    >> "$repo/batch/foreman.conf"
  run_foreman "$repo" doctor
  assert_missing "$OUT" "no way for the agent to commit" "and is satisfied once it is there"
fi

if case_is "a usage limit pauses the run"; then
  repo="$(make_repo 3 limit-repo)"
  FOREMAN_FAKE_BEHAVIOUR=limit run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 10 "exits paused, not stopped"
  assert_contains "$OUT" "usage limit reached" "says why"
  assert_contains "$OUT" "Resume:" "tells you how to resume"
fi

if case_is "a session limit pauses the run and says when it resets"; then
  # The same 5-hour window, worded the way the CLI words it now. Matching only the older
  # "usage limit reached" phrasing sent this down the generic paths, where a dirty tree wins
  # the branch order and the run stopped as "left uncommitted changes" — the real cause, and
  # the reset time, appearing nowhere in the terminal.
  repo="$(make_repo 3 session-limit-repo)"
  FOREMAN_FAKE_BEHAVIOUR=session-limit run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 10 "exits paused, not stopped"
  assert_contains "$OUT" "usage limit reached" "reads as a limit, not a mystery stop"
  assert_contains "$OUT" "4:50pm" "carries the reset time through to the pause message"
  assert_contains "$OUT" "Resume:" "tells you how to resume"
fi

if case_is "the cost budget stops the run before spending over it"; then
  repo="$(make_repo 5 cost-repo)"
  FOREMAN_FAKE_COST=0.50 FOREMAN_MAX_COST_USD=1 run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 10 "pauses on the cost budget"
  assert_contains "$OUT" "cost budget reached" "says why"
  assert_eq "$(done_count "$repo")" "2" "stops once the budget is reached, not after"
  assert_missing "$OUT" "overshot to salvage" "nothing stalled here, so no salvage note"
fi

if case_is "the run is recorded for foreman report"; then
  repo="$(make_repo 2 report-repo)"
  FOREMAN_FAKE_COST=0.25 run_foreman "$repo" run batch --unlimited

  assert_eq "$(grep -c . "$repo/DONE_batch/foreman-runs.jsonl")" "2" "one record per iteration"

  run_foreman "$repo" report DONE_batch
  assert_eq "$ST" 0 "report reads the log"
  assert_contains "$OUT" "iterations 2  ·  landed 2" "report agrees with the run"
  assert_contains "$OUT" '$0.5000' "report totals the cost"

  run_foreman "$repo" report DONE_batch --failures
  assert_contains "$OUT" "every recorded iteration landed" "nothing is flagged"
fi

if case_is "the prompt carries the ticket, the order file and the progress tail"; then
  repo="$(make_repo 2 prompt-repo)"
  log="$WORK/prompts.txt"
  FOREMAN_FAKE_PROMPT_LOG="$log" run_foreman "$repo" run batch 1

  prompts="$(cat "$log")"
  assert_contains "$prompts" "@batch/issues/01-ticket.md" "the ticket is attached"
  assert_contains "$prompts" "batch/progress.txt" "the progress file is named"
  assert_contains "$prompts" "nothing recorded yet" "the first prompt says so"
  assert_contains "$prompts" "'**Status:**' line to 'implemented'" "it says what to write when done"
  # The one thing the agent cannot discover for itself: --print gives it no second turn, so
  # a backgrounded verify command ends the iteration waiting for a result that never comes.
  assert_contains "$prompts" "single non-interactive turn" "it says the session is one-shot"
  assert_contains "$prompts" "in the foreground" "and that checks must be waited on"
fi

if case_is "an unknown exec mode is rejected before anything runs"; then
  repo="$(make_repo 1 badexec-repo)"
  FOREMAN_EXEC=nonesuch run_foreman "$repo" run batch

  assert_eq "$ST" 1 "refuses to start"
  assert_contains "$OUT" "FOREMAN_EXEC must be one of:" "lists the modes that exist"
  assert_contains "$OUT" "fake" "the list is generated from lib/exec/"
fi

if case_is "doctor asks the adapter what this repo needs"; then
  repo="$(make_repo 1 doctor-repo)"
  run_foreman "$repo" doctor

  assert_eq "$ST" 0 "a fake batch needs no runner on PATH"
  assert_contains "$OUT" "0 of 1 done" "the batch is listed with its progress"
  assert_missing "$OUT" "sbx is not on PATH" "does not ask for a sandbox it will not use"
fi

if case_is "init scaffolds a batch from its own ticket list"; then
  repo="$(make_repo 2 init-repo)"
  rm -f "$repo/batch/order.md"
  run_foreman "$repo" init batch --no-order

  assert_eq "$ST" 0 "init exits 0"
  order="$(cat "$repo/batch/order.md")"
  assert_contains "$order" "batch/issues/01-ticket.md" "the order block lists ticket 1"
  assert_contains "$order" "batch/issues/02-ticket.md" "the order block lists ticket 2"
  assert_contains "$order" "ready-for-human" "the prose points at human tickets"
  assert_contains "$order" "followup" "the prose points at followup tickets"
  assert_contains "$OUT" "created  batch/progress.txt" "progress.txt is scaffolded"
fi

if case_is "init and --unordered honour FOREMAN_ISSUES_DIRS"; then
  # The bug this fixes: init used to scan a hard-coded `issues/`, so a batch whose conf
  # points elsewhere was scaffolded from an empty directory.
  repo="$WORK/issuesdir-repo"
  mkdir -p "$repo/batch/specs"
  git -C "$repo" init --quiet
  git -C "$repo" config core.autocrlf false
  printf '# Spec %s\n\n**Status:** todo\n' 1 > "$repo/batch/specs/01-spec.md"
  printf '# Spec %s\n\n**Status:** todo\n' 2 > "$repo/batch/specs/02-spec.md"
  printf '# not a ticket\n' > "$repo/batch/specs/README.md"
  printf 'FOREMAN_EXEC=fake\nFOREMAN_ISSUES_DIRS="specs"\n' > "$repo/batch/foreman.conf"

  run_foreman "$repo" next batch --unordered
  assert_eq "$ST" 0 "--unordered exits 0"
  assert_contains "$OUT" "batch/specs/01-spec.md" "it finds the specs directory"
  assert_missing "$OUT" "README.md" "it applies the exclusion list"

  run_foreman "$repo" init batch --no-order
  order="$(cat "$repo/batch/order.md")"
  assert_contains "$order" "batch/specs/01-spec.md" "init scaffolds from specs, not issues"
  assert_contains "$order" "batch/specs/02-spec.md" "and lists all of them"
  assert_missing "$order" "No tickets found" "it does not report an empty batch"
fi

if case_is "--unordered ignores an existing order.md"; then
  repo="$(make_repo 3 unordered-repo)"
  mkdir -p "$repo/batch"
  { echo '<!-- ORDER:BEGIN -->'
    echo 'batch/issues/03-ticket.md'
    echo '<!-- ORDER:END -->'; } > "$repo/batch/order.md"

  run_foreman "$repo" next batch --all
  assert_eq "$OUT" "batch/issues/03-ticket.md" "--all follows the order file"

  run_foreman "$repo" next batch --unordered
  assert_contains "$OUT" "batch/issues/01-ticket.md" "--unordered sees tickets the order file omits"
  assert_eq "$(printf '%s\n' "$OUT" | grep -c .)" "3" "and sees all of them"
fi

if case_is "a && in a check command survives into the prompt"; then
  # Bash's ${var//pat/repl} treats & in the replacement as "the text that matched" — a
  # FOREMAN_TEST_CMD containing && used to render as two copies of __VERIFY_BLOCK__'s own
  # marker text instead of the command. dry-run exits before exec_prepare, so no sandbox
  # is touched.
  repo="$(make_repo 1 ampersand-repo)"
  printf 'FOREMAN_TEST_CMD="node a.js && node b.js"\n' >> "$repo/batch/foreman.conf"
  git -C "$repo" commit --quiet -am "add test cmd"

  run_foreman "$repo" dry-run batch
  assert_eq "$ST" 0 "dry-run exits 0"
  assert_contains "$OUT" "node a.js && node b.js" "the command survives verbatim"
  assert_missing "$OUT" "__VERIFY_BLOCK__" "the marker is not left behind"
fi

if case_is "FOREMAN_ISSUES_DIRS='.' means the batch directory, not the repo root"; then
  # A relative FOREMAN_ISSUES_DIRS entry used to resolve against the repo root first, so "."
  # meant the repo's own top level rather than the batch directory.
  repo="$WORK/dot-issues-repo"
  mkdir -p "$repo/batch"
  git -C "$repo" init --quiet
  git -C "$repo" config core.autocrlf false
  printf '# decoy repo-root file\n' > "$repo/CLAUDE.md"
  printf '# Ticket 1\n\n**Status:** todo\n' > "$repo/batch/01-ticket.md"
  printf '# Ticket 2\n\n**Status:** todo\n' > "$repo/batch/02-ticket.md"
  printf 'FOREMAN_EXEC=fake\nFOREMAN_ISSUES_DIRS="."\n' > "$repo/batch/foreman.conf"

  run_foreman "$repo" next batch --unordered
  assert_eq "$ST" 0 "--unordered exits 0"
  assert_contains "$OUT" "01-ticket.md" "it lists the first ticket"
  assert_contains "$OUT" "02-ticket.md" "and the second"
  assert_missing "$OUT" "CLAUDE.md" "it does not pick up the repo-root decoy"
fi

if case_is "a batch whose tickets are not where FOREMAN_ISSUES_DIRS looks says where it looked"; then
  repo="$WORK/misplaced-tickets-repo"
  mkdir -p "$repo/batch"
  git -C "$repo" init --quiet
  git -C "$repo" config core.autocrlf false
  printf '# Ticket 1\n\n**Status:** todo\n' > "$repo/batch/01-ticket.md"
  printf 'FOREMAN_EXEC=fake\n' > "$repo/batch/foreman.conf"

  run_foreman "$repo" status batch
  assert_contains "$OUT" "batch/issues" "names the resolved (default) issues path"
  assert_contains "$OUT" "(missing)" "and says it does not exist"
  assert_contains "$OUT" 'FOREMAN_ISSUES_DIRS="."' "suggests the one-line fix"
fi

if case_is "--unordered is quiet about an empty batch, the other modes are not"; then
  repo="$WORK/empty-repo"
  mkdir -p "$repo/batch/issues"
  git -C "$repo" init --quiet
  printf 'FOREMAN_EXEC=fake\n' > "$repo/batch/foreman.conf"

  run_foreman "$repo" next batch --unordered
  assert_eq "$ST" 0 "--unordered exits 0 on an empty batch"
  assert_eq "$OUT" "" "and prints nothing"

  run_foreman "$repo" next batch --count
  assert_eq "$ST" 2 "--count still calls an empty batch malformed"
fi

if case_is "a landed ticket with every box ticked is renamed DONE_"; then
  repo="$(make_repo 2 done-rename-repo)"
  run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "the batch finishes"
  d="$repo/DONE_batch/issues"
  [ -f "$d/DONE_01-ticket.md" ] && [ -f "$d/DONE_02-ticket.md" ] && pass || fail "both tickets carry the prefix"
  [ -e "$d/01-ticket.md" ] && fail "the old name is gone" || pass
  assert_contains "$OUT" "marked done" "the rename is announced"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "the rename was committed, tree is clean"
  assert_contains "$(git -C "$repo" log --format=%s)" "chore: mark 01-ticket.md done" "as its own commit"
  assert_eq "$(done_count "$repo")" "2" "renamed tickets still count as done"

  run_foreman "$repo" next DONE_batch --count
  assert_eq "$OUT" "2 2" "--count agrees"
  run_foreman "$repo" run DONE_batch
  assert_eq "$ST" 0 "a rerun has nothing left to do and renames nothing further"
fi

if case_is "a ticket with an unticked box, or not yet done, keeps its name"; then
  repo="$(make_repo 2 done-rename-boxes-repo)"
  printf '# Ticket 1\n\n**Status:** todo\n\n- [x] one\n  - [ ] two\n' > "$repo/batch/issues/01-ticket.md"
  printf '# Ticket 2\n\n**Status:** todo\n\n- [x] one\n* [X] two\n' > "$repo/batch/issues/02-ticket.md"
  git -C "$repo" commit --quiet -am "boxes"

  run_foreman "$repo" run batch --unlimited
  d="$repo/DONE_batch/issues"
  [ -f "$d/01-ticket.md" ] && pass || fail "unticked box: the name is kept"
  assert_contains "$OUT" "unchecked boxes" "and says why"
  [ -f "$d/DONE_02-ticket.md" ] && pass || fail "every box ticked: renamed"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "tree clean"

  repo="$(make_repo 1 done-rename-noop-repo)"
  FOREMAN_FAKE_BEHAVIOUR=noop run_foreman "$repo" run batch 1
  [ -f "$repo/batch/issues/01-ticket.md" ] && pass || fail "a ticket that did not land is never renamed"
fi

if case_is "an order.md written before the rename still finds the renamed ticket"; then
  repo="$(make_repo 3 done-rename-order-repo)"
  { echo '<!-- ORDER:BEGIN -->'
    echo 'batch/issues/03-ticket.md'
    echo 'batch/issues/01-ticket.md'
    echo 'batch/issues/02-ticket.md'
    echo '<!-- ORDER:END -->'; } > "$repo/batch/order.md"
  git -C "$repo" add -A; git -C "$repo" commit --quiet -m order

  run_foreman "$repo" run batch 1
  [ -f "$repo/batch/issues/DONE_03-ticket.md" ] && pass || fail "ticket 3 ran first and was renamed"
  run_foreman "$repo" next batch --all
  assert_eq "$(printf '%s\n' "$OUT" | head -1)" "batch/issues/DONE_03-ticket.md" "order.md resolves the renamed file"
  run_foreman "$repo" next batch
  assert_eq "$OUT" "batch/issues/01-ticket.md" "and the next ticket is still 01"
fi

if case_is "renamed tickets keep their place in filename order"; then
  repo="$(make_repo 3 done-rename-sort-repo)"
  git -C "$repo" mv batch/issues/01-ticket.md batch/issues/DONE_01-ticket.md
  run_foreman "$repo" next batch --all
  assert_eq "$(printf '%s\n' "$OUT" | head -1)" "batch/issues/DONE_01-ticket.md" "DONE_01 sorts as 01"
  assert_eq "$(printf '%s\n' "$OUT" | tail -1)" "batch/issues/03-ticket.md" "and 03 is still last"
fi

if case_is "FOREMAN_DONE_PREFIX empty leaves ticket files alone"; then
  repo="$(make_repo 1 done-rename-off-repo)"
  FOREMAN_DONE_PREFIX= run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "the batch finishes"
  [ -f "$repo/batch/issues/01-ticket.md" ] && pass || fail "the ticket kept its name"
  [ -d "$repo/batch" ] && pass || fail "and so did the batch"
fi

if case_is "a finished batch directory is renamed with the done prefix"; then
  repo="$(make_repo 2 done-batch-repo)"
  run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "the batch finishes"
  [ -d "$repo/DONE_batch" ] && [ ! -e "$repo/batch" ] && pass || fail "batch became DONE_batch"
  assert_contains "$OUT" "batch marked done  ·  DONE_batch" "the rename is announced"
  assert_eq "$(git -C "$repo" log -1 --format=%s)" "chore: mark batch batch done" "the rename is the last commit"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "and the tree is clean"
  [ -f "$repo/DONE_batch/foreman-runs.log" ] && pass || fail "the run log moved with the directory"
  [ -f "$repo/DONE_batch/issues/DONE_02-ticket.md" ] && pass || fail "the tickets are inside"

  run_foreman "$repo" run DONE_batch
  assert_eq "$ST" 0 "running the renamed batch is still a finished batch"
  assert_contains "$OUT" "Nothing to do" "says there is nothing to do"
  assert_missing "$OUT" "batch marked done" "and does not rename it again"
  [ -d "$repo/DONE_batch" ] && [ ! -e "$repo/DONE_DONE_batch" ] && pass || fail "no second prefix"
fi

if case_is "commands with no batch argument skip finished batches"; then
  repo="$(make_repo 1 done-batch-skip-repo)"
  run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "the batch finishes and becomes DONE_batch"

  run_foreman "$repo" status
  [ "$ST" != 0 ] && pass || fail "a repo whose only batch is finished has no batch to default to"
  assert_contains "$OUT" "no unfinished foreman.conf batch" "and says why"

  # A second, unfinished batch becomes the only candidate — the finished one does not make it ambiguous.
  mkdir -p "$repo/other/issues"
  cp "$repo/DONE_batch/foreman.conf" "$repo/other/foreman.conf"
  printf '# Ticket 1\n\n**Status:** ready-for-agent\n\n- [ ] one\n' > "$repo/other/issues/01-ticket.md"
  git -C "$repo" add other && git -C "$repo" commit --quiet -m "another batch"
  run_foreman "$repo" status
  assert_eq "$ST" 0 "status picks the unfinished batch"
  assert_contains "$OUT" "01-ticket.md" "and lists its ticket"

  run_foreman "$repo" status DONE_batch
  assert_eq "$ST" 0 "a finished batch can still be named"
fi

if case_is "FOREMAN_DONE_PREFIX empty leaves the batch directory alone"; then
  repo="$(make_repo 1 done-batch-off-repo)"
  FOREMAN_DONE_PREFIX= run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "the batch finishes"
  [ -d "$repo/batch" ] && [ ! -e "$repo/DONE_batch" ] && pass || fail "the batch kept its name"
  assert_missing "$OUT" "batch marked done" "and nothing is announced"
fi

if case_is "a batch with a tracked modification keeps its name"; then
  # A dirty tree stalls an iteration, so this only arises when the batch was finished by hand
  # and the run has nothing to do.
  repo="$(make_repo 1 done-batch-dirty-repo)"
  printf '# Ticket 1

**Status:** implemented

- [x] one
' > "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "01 done by hand"
  printf '# edited by hand
' >> "$repo/batch/foreman.conf"
  FOREMAN_ALLOW_DIRTY=1 run_foreman "$repo" run batch
  assert_eq "$ST" 0 "nothing to do is a success"
  [ -d "$repo/batch" ] && [ ! -e "$repo/DONE_batch" ] && pass || fail "the batch kept its name"
  assert_contains "$OUT" "has uncommitted changes — leaving its name alone" "says why"
  assert_contains "$(git -C "$repo" status --porcelain)" "foreman.conf" "the edit is still uncommitted"
fi

if case_is "a batch finished by hand is renamed on the next run"; then
  repo="$(make_repo 1 done-batch-hand-repo)"
  printf '# Ticket 1\n\n**Status:** implemented\n\n- [x] one\n' > "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "01 done by hand"
  run_foreman "$repo" run batch
  assert_eq "$ST" 0 "nothing to do is a success"
  assert_contains "$OUT" "Nothing to do" "says so"
  [ -d "$repo/DONE_batch" ] && [ ! -e "$repo/batch" ] && pass || fail "batch became DONE_batch"
  assert_eq "$(git -C "$repo" log -1 --format=%s)" "chore: mark batch batch done" "committed"
fi

if case_is "the usage line shows minutes beside seconds"; then
  repo="$(make_repo 1 usage-minutes-repo)"
  run_foreman "$repo" run batch --unlimited
  assert_contains "$OUT" "1.2s (0.0m)" "the fake adapter's 1200 ms"
fi

if case_is "a ticket marked done counts as done, like an implemented one"; then
  repo="$(make_repo 2 done-word-repo)"
  printf '# Ticket 1\n\n**Status:** done\n\n- [x] one\n' > "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "01 done by hand"

  run_foreman "$repo" next batch --count
  assert_eq "$OUT" "1 2" "done is counted like implemented"
  run_foreman "$repo" next batch
  assert_eq "$OUT" "batch/issues/02-ticket.md" "and skipped when picking the next ticket"
fi

# ---------------------------------------------------------------------------
# Human tickets
# ---------------------------------------------------------------------------

# Ticket $2 becomes a human ticket, with a `Handoff:` line naming batch/handoff/0N-ticket.md
# and that file created — unless $3 is `none`, which leaves it without a handoff at all.
make_human_ticket() {
  local repo="$1" n="$2" handoff="${3:-}" ticket
  ticket="$repo/batch/issues/0$n-ticket.md"
  sed -i 's/^\*\*Status:\*\* todo/**Status:** ready-for-human/' "$ticket"
  if [ "$handoff" != none ]; then
    sed -i "s|^\*\*Status:\*\* ready-for-human|&\n**Handoff:** batch/handoff/0$n-ticket.md|" "$ticket"
    mkdir -p "$repo/batch/handoff"
    printf '# Handoff %s\n\n## What you did\n\n<!-- -->\n' "$n" > "$repo/batch/handoff/0$n-ticket.md"
  fi
  git -C "$repo" add -A >/dev/null
  git -C "$repo" commit --quiet -m "ticket $n is a human ticket"
}

# Ticket $2 as its person leaves it: done, committed.
finish_human_ticket() {
  local repo="$1" n="$2"
  sed -i 's/^\*\*Status:\*\* ready-for-human/**Status:** done/' "$repo/batch/issues/0$n-ticket.md"
  git -C "$repo" commit --quiet -am "ticket $n done by hand"
}

runs_rows() { grep -c . "$1/batch/foreman-runs.jsonl" 2>/dev/null || printf 0; }

if case_is "a human ticket at the head of the order stops the run before anything is spent"; then
  repo="$(make_repo 3 human-head-repo)"
  make_human_ticket "$repo" 1
  head="$(git -C "$repo" rev-parse HEAD)"
  log="$WORK/human-head-prompts.txt"

  FOREMAN_FAKE_PROMPT_LOG="$log" run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 30 "exits waiting-on-a-human"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head" "no new commits"
  [ -e "$repo/batch/foreman-runs.jsonl" ] && fail "no run-log rows were written" || pass
  [ -e "$repo/batch/foreman-runs.log" ] && fail "and no run log at all" || pass
  [ -e "$log" ] && fail "no prompt was sent" || pass
  assert_contains "$OUT" "batch/issues/01-ticket.md is a human ticket" "names the ticket"
  assert_contains "$OUT" "batch/handoff/01-ticket.md" "names its handoff file"
  assert_contains "$OUT" "run batch --unlimited" "gives the exact rerun command"
  assert_contains "$OUT" "costs nothing" "says rerunning early is free"
  assert_missing "$OUT" "== run" "there is no run to report"
fi

if case_is "a human ticket with no handoff file is named without one"; then
  repo="$(make_repo 2 human-nohandoff-repo)"
  make_human_ticket "$repo" 1 none

  run_foreman "$repo" run batch
  assert_eq "$ST" 30 "still stops"
  assert_missing "$OUT" "Fill in every section" "there is no handoff step to give"
  assert_contains "$OUT" "  2. Commit your work." "and the steps renumber"
  assert_contains "$OUT" "  4. Rerun:" "ending at the rerun"
fi

if case_is "a run that reaches a human ticket mid-batch lands what is before it and stops"; then
  repo="$(make_repo 4 human-mid-repo)"
  make_human_ticket "$repo" 3
  log="$WORK/human-mid-prompts.txt"

  FOREMAN_FAKE_PROMPT_LOG="$log" run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 30 "exits waiting-on-a-human"
  assert_eq "$(done_count "$repo")" "2" "tickets 1 and 2 landed"
  assert_contains "$OUT" "tickets landed:        2" "the usual footer is printed"
  assert_contains "$OUT" "batch/issues/03-ticket.md is a human ticket" "then the note"
  assert_eq "$(grep -c '^===== fake prompt' "$log")" "2" "only the two agent tickets were prompted"
  assert_missing "$(cat "$log")" "04-ticket.md" "nothing after the human ticket was prompted"
  assert_contains "$(tail -3 "$repo/batch/foreman-runs.log")" \
    "# stopped: waiting on a human — batch/issues/03-ticket.md" "the run log says why it stopped"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "the tree is clean"
fi

if case_is "the human gate is checked before the iteration budget"; then
  repo="$(make_repo 2 human-budget-repo)"
  make_human_ticket "$repo" 2

  run_foreman "$repo" run batch
  assert_eq "$ST" 30 "waiting on a human, not paused on the budget"
  assert_eq "$(done_count "$repo")" "1" "the first ticket landed"
  assert_missing "$OUT" "PAUSED" "and nothing says the budget stopped it"
  assert_contains "$OUT" "run batch 1" "the rerun command keeps the iteration count"
fi

if case_is "rerunning a human ticket without finishing it stops again, for free"; then
  repo="$(make_repo 4 human-rerun-repo)"
  make_human_ticket "$repo" 3
  run_foreman "$repo" run batch --unlimited
  head="$(git -C "$repo" rev-parse HEAD)"
  rows="$(runs_rows "$repo")"
  log="$WORK/human-rerun-prompts.txt"

  FOREMAN_FAKE_PROMPT_LOG="$log" run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 30 "stops the same way"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head" "HEAD did not move"
  assert_eq "$(runs_rows "$repo")" "$rows" "nothing was recorded"
  [ -e "$log" ] && fail "no prompt was sent" || pass
  assert_contains "$OUT" "batch/issues/03-ticket.md is a human ticket" "says the same thing"
fi

if case_is "setting a human ticket to done lets a rerun continue with the next ticket"; then
  repo="$(make_repo 3 human-resume-repo)"
  make_human_ticket "$repo" 2
  run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 30 "stopped at the human ticket"

  finish_human_ticket "$repo" 2
  log="$WORK/human-resume-prompts.txt"
  FOREMAN_FAKE_PROMPT_LOG="$log" run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "the batch finishes"
  assert_eq "$(grep -c '^===== fake prompt' "$log")" "1" "one prompt: the ticket after it"
  assert_contains "$(cat "$log")" "03-ticket.md" "and it was ticket 3"
fi

if case_is "dry-run at a human ticket says it would stop there and prints no prompt"; then
  repo="$(make_repo 2 human-dry-repo)"
  make_human_ticket "$repo" 1

  run_foreman "$repo" dry-run batch
  assert_eq "$ST" 0 "exits 0"
  assert_contains "$OUT" "Would stop before batch/issues/01-ticket.md" "says where it would stop"
  assert_missing "$OUT" "=== prompt that would be sent" "prints no prompt"
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "2" "committed nothing"
fi

if case_is "the human word is configurable and can be switched off"; then
  repo="$(make_repo 2 human-word-repo)"
  make_human_ticket "$repo" 1
  sed -i 's/ready-for-human/needs-owner/' "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "a different word"

  run_foreman "$repo" run batch
  assert_eq "$ST" 10 "the default word no longer stops there: the ticket is an agent's"

  repo="$(make_repo 2 human-word2-repo)"
  make_human_ticket "$repo" 1
  sed -i 's/ready-for-human/needs-owner/' "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "a different word"
  FOREMAN_HUMAN_WORD=needs-owner run_foreman "$repo" run batch
  assert_eq "$ST" 30 "FOREMAN_HUMAN_WORD=needs-owner stops on that word"
  assert_contains "$OUT" "'**Status:** needs-owner'" "and the note quotes it"

  repo="$(make_repo 2 human-off-repo)"
  make_human_ticket "$repo" 1
  log="$WORK/human-off-prompts.txt"
  FOREMAN_HUMAN_WORD= FOREMAN_FAKE_PROMPT_LOG="$log" run_foreman "$repo" run batch
  assert_eq "$ST" 10 "an empty word hands the ticket to the agent like any other"
  assert_contains "$(cat "$log")" "01-ticket.md" "which was prompted"
fi

if case_is "a done ticket is never a human ticket"; then
  repo="$(make_repo 2 human-done-repo)"
  make_human_ticket "$repo" 1
  finish_human_ticket "$repo" 1
  run_foreman "$repo" dry-run batch
  assert_missing "$OUT" "Would stop before" "done wins over the human marker"
fi

# ---------------------------------------------------------------------------
# Followup tickets
# ---------------------------------------------------------------------------

# Ticket N checks ticket M: it gets a `Checks:` line naming that ticket's file.
make_followup_ticket() {
  local repo="$1" n="$2" m="$3"
  sed -i "s|^\*\*Status:\*\* todo|&\n**Checks:** 0$m-ticket.md|" "$repo/batch/issues/0$n-ticket.md"
  git -C "$repo" commit --quiet -am "ticket $n checks ticket $m"
}

# A batch of 5 in which 3 is a human ticket already set to done by its person, 4 checks it, and
# the run before that stopped at it.
checked_repo() {    # checked_repo NAME
  local repo
  repo="$(make_repo 5 "$1")"
  make_human_ticket "$repo" 3
  make_followup_ticket "$repo" 4 3
  run_foreman "$repo" run batch --unlimited
  finish_human_ticket "$repo" 3
  printf '%s' "$repo"
}

if case_is "a followup ticket that sends its human ticket back ends the run at exit 30"; then
  repo="$(checked_repo check-sendback-repo)"
  log="$WORK/check-sendback-prompts.txt"

  FOREMAN_FAKE_BEHAVIOUR=send-back FOREMAN_FAKE_PROMPT_LOG="$log" run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 30 "waiting on a human again"
  assert_contains "$OUT" "↩ sent back to a human by 04-ticket.md" "the run says so"
  assert_contains "$OUT" "↩ It was sent back by 04-ticket.md: read '## Sent back by 04-ticket.md'" \
    "and the note points at the section"
  assert_contains "$OUT" "batch/issues/03-ticket.md is a human ticket" "the note is the human ticket's"
  [ -f "$repo/batch/issues/03-ticket.md" ] && pass || fail "the human ticket kept its name"
  [ -e "$repo/batch/issues/DONE_03-ticket.md" ] && fail "and was not prefixed" || pass
  assert_contains "$(cat "$repo/batch/issues/03-ticket.md")" "**Status:** ready-for-human" "it is a human ticket again"
  assert_contains "$(cat "$repo/batch/issues/03-ticket.md")" "## Sent back by 04-ticket.md" "and carries the section"
  assert_contains "$(cat "$repo/batch/issues/04-ticket.md")" "**Status:** todo" "the followup ticket is unflipped"
  assert_eq "$(grep -c '^===== fake prompt' "$log")" "1" "only the followup ticket was prompted"
  assert_missing "$(cat "$log")" "05-ticket.md" "nothing after it ran"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "the tree is clean"

  head="$(git -C "$repo" rev-parse HEAD)"
  rows="$(runs_rows "$repo")"
  run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 30 "a plain rerun stops the same way"
  assert_contains "$OUT" "↩ It was sent back by 04-ticket.md" "and says again that it was sent back"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head" "HEAD did not move"
  assert_eq "$(runs_rows "$repo")" "$rows" "nothing was recorded"
fi

if case_is "a human ticket is renamed only once its followup ticket has landed"; then
  repo="$(checked_repo check-rename-repo)"

  FOREMAN_FAKE_BEHAVIOUR=noop run_foreman "$repo" run batch 1
  assert_eq "$ST" 20 "a followup ticket that does nothing does not land"
  [ -e "$repo/batch/issues/03-ticket.md" ] && pass || fail "so the human ticket keeps its name"
  [ -e "$repo/batch/issues/DONE_03-ticket.md" ] && fail "and is not prefixed" || pass

  run_foreman "$repo" run batch 1
  assert_contains "$OUT" "batch/issues/03-ticket.md waits for batch/issues/04-ticket.md before it is marked done" \
    "the run says what the human ticket waits for"
  assert_contains "$OUT" "✓ landed" "the followup ticket landed"
  [ -e "$repo/batch/issues/DONE_04-ticket.md" ] && pass || fail "the followup ticket is DONE_-prefixed"
  [ -e "$repo/batch/issues/DONE_03-ticket.md" ] && pass || fail "and so is the human ticket it checked"
  [ -e "$repo/batch/issues/03-ticket.md" ] && fail "which no longer has its old name" || pass
  assert_eq "$(git -C "$repo" status --porcelain)" "" "the tree is clean"
fi

if case_is "Checks: resolves whichever side carries the done prefix"; then
  # The followup ticket names the human ticket WITH the prefix; the human ticket has none.
  repo="$(make_repo 3 check-prefix-repo)"
  make_human_ticket "$repo" 2
  make_followup_ticket "$repo" 3 2
  sed -i 's/^\*\*Checks:\*\* 02/**Checks:** DONE_02/' "$repo/batch/issues/03-ticket.md"
  git -C "$repo" commit --quiet -am "the followup names the prefixed name"
  finish_human_ticket "$repo" 2
  run_foreman "$repo" run batch 2
  assert_contains "$OUT" "batch/issues/02-ticket.md waits for batch/issues/03-ticket.md" "found through the prefix"
  [ -e "$repo/DONE_batch/issues/DONE_02-ticket.md" ] && pass || fail "and renamed when the followup landed"

  # The human ticket carries the prefix; the followup ticket names it without.
  repo="$(make_repo 2 check-prefix2-repo)"
  make_human_ticket "$repo" 1
  make_followup_ticket "$repo" 2 1
  finish_human_ticket "$repo" 1
  git -C "$repo" mv batch/issues/01-ticket.md batch/issues/DONE_01-ticket.md
  git -C "$repo" commit --quiet -m "renamed by hand"
  FOREMAN_FAKE_BEHAVIOUR=send-back run_foreman "$repo" run batch
  assert_eq "$ST" 30 "the followup ticket found its human ticket and sent it back"
  assert_contains "$(cat "$repo/batch/issues/DONE_01-ticket.md")" "## Sent back by 02-ticket.md" "the prefixed file"
fi

# ---------------------------------------------------------------------------
# Status, dry-run and warnings
# ---------------------------------------------------------------------------

if case_is "status marks human and followup tickets and says where the loop will stop"; then
  repo="$(make_repo 4 status-marked-repo)"
  make_human_ticket "$repo" 3
  make_followup_ticket "$repo" 4 3

  run_foreman "$repo" status batch
  assert_eq "$ST" 0 "status still exits 0"
  assert_contains "$OUT" "human tickets remaining: 1" "the progress line counts it"
  assert_contains "$OUT" "  3  03-ticket.md   [HUMAN]" "the human ticket is marked"
  assert_contains "$OUT" "  4  04-ticket.md   [CHECKS 03-ticket.md]" "and its checker names it"
  assert_contains "$OUT" \
    "The loop will run 2 ticket(s), then stop at 03-ticket.md for a human." \
    "and says where it will stop"
  assert_missing "$OUT" "warning:" "both pieces are in place, so nothing to warn about"

  run_foreman "$repo" dry-run batch
  assert_eq "$ST" 0 "dry-run exits 0"
  assert_contains "$OUT" "  3  03-ticket.md   [HUMAN]" "dry-run marks the same way"
  assert_contains "$OUT" "  4  04-ticket.md   [CHECKS 03-ticket.md]" "checker included"
fi

if case_is "a Checks: line reads the same bold or plain, with CRLF, and with trailing spaces"; then
  repo="$(make_repo 5 checks-forms-repo)"
  # 2: plain, no bold. 3: bold, trailing spaces. 4: a CRLF file, trailing space before the CR.
  # 5: a value with nothing after the colon, so the first Checks: line wins and is empty.
  sed -i 's|^\*\*Status:\*\* todo|&\nChecks: 01-ticket.md|' "$repo/batch/issues/02-ticket.md"
  sed -i 's|^\*\*Status:\*\* todo|&\n**Checks:** 01-ticket.md   |' "$repo/batch/issues/03-ticket.md"
  sed -i 's|^\*\*Status:\*\* todo|&\n**Checks:** 01-ticket.md |' "$repo/batch/issues/04-ticket.md"
  sed -i 's/$/\r/' "$repo/batch/issues/04-ticket.md"
  sed -i 's|^\*\*Status:\*\* todo|&\n**Checks:**\nChecks: 01-ticket.md|' "$repo/batch/issues/05-ticket.md"
  git -C "$repo" commit --quiet -am "four spellings of Checks:"

  run_foreman "$repo" status batch
  assert_eq "$ST" 0 "status exits 0"
  assert_contains "$OUT" "  2  02-ticket.md   [CHECKS 01-ticket.md]" "plain, no bold"
  assert_contains "$OUT" "  3  03-ticket.md   [CHECKS 01-ticket.md]" "trailing spaces trimmed"
  assert_contains "$OUT" "  4  04-ticket.md   [CHECKS 01-ticket.md]" "CRLF and trailing space trimmed"
  assert_contains "$OUT" "  5  05-ticket.md" "an empty first Checks: line is listed"
  assert_missing "$OUT" "05-ticket.md   [CHECKS" "and is not a followup ticket"
  assert_missing "$OUT" "batch/issues/02-ticket.md should come right after" "the plain spelling resolves, and 02 is where it belongs"
  assert_contains "$OUT" "warning: batch/issues/03-ticket.md should come right after batch/issues/01-ticket.md in order.md" \
    "the trimmed name resolves to its ticket"
  assert_contains "$OUT" "warning: batch/issues/04-ticket.md should come right after batch/issues/01-ticket.md in order.md" \
    "and so does the CRLF one"
  assert_missing "$OUT" "Checks: 01-ticket.md, which is not a ticket" "no spelling fails to resolve"
fi

if case_is "a custom FOREMAN_DONE_PATTERN and FOREMAN_HUMAN_PATTERN are matched as grep patterns"; then
  repo="$(make_repo 4 custom-pattern-repo)"
  sed -i 's|^\*\*Status:\*\* todo|State: finished|' "$repo/batch/issues/01-ticket.md"
  sed -i 's|^\*\*Status:\*\* todo|State: over|' "$repo/batch/issues/02-ticket.md"
  sed -i 's|^\*\*Status:\*\* todo|State: waiting on someone|' "$repo/batch/issues/03-ticket.md"
  git -C "$repo" commit --quiet -am "a status line of another shape"

  FOREMAN_DONE_PATTERN='^State: *\(finished\|over\)$' FOREMAN_HUMAN_PATTERN='^State: *waiting.*one$' \
    run_foreman "$repo" status batch
  assert_contains "$OUT" "Tickets done: 2 / 4" "both alternatives of the done pattern count"
  assert_contains "$OUT" "Next: 03-ticket.md   [HUMAN" "the custom human pattern marks the next ticket"
  assert_contains "$OUT" "  2  04-ticket.md" "and the ticket with no State: line is still to do"
fi

if case_is "a status line holding . [ * ^ $ or a backslash matches itself only"; then
  repo="$(make_repo 6 status-line-chars-repo)"
  line='St.t[u]s*^$\x:'
  # 1: the line exactly. 2-3: what an unescaped . or [u] would also match. 4: the line, but not
  # done and the human word. 5: an unescaped * would let `ss` through. 6: no backslash.
  printf '# T\n\n%s implemented\n' "$line" > "$repo/batch/issues/01-ticket.md"
  printf '# T\n\n%s implemented\n' 'Stxt[u]s*^$\x:' > "$repo/batch/issues/02-ticket.md"
  printf '# T\n\n%s implemented\n' 'St.tus*^$\x:' > "$repo/batch/issues/03-ticket.md"
  printf '# T\n\n%s ready-for-human\n' "$line" > "$repo/batch/issues/04-ticket.md"
  printf '# T\n\n%s implemented\n' 'St.t[u]ss^$\x:' > "$repo/batch/issues/05-ticket.md"
  printf '# T\n\n%s implemented\n' 'St.t[u]s*^$x:' > "$repo/batch/issues/06-ticket.md"
  git -C "$repo" add -A >/dev/null
  git -C "$repo" commit --quiet -m "a status line of metacharacters"

  FOREMAN_STATUS_LINE="$line" run_foreman "$repo" status batch
  assert_eq "$ST" 0 "status exits 0"
  assert_contains "$OUT" "Tickets done: 1 / 6" "only the ticket carrying the line itself is done"
  assert_contains "$OUT" "  3  04-ticket.md   [HUMAN]" "the human pattern is escaped the same way"
  assert_missing "$OUT" "02-ticket.md   [HUMAN" "and no other ticket is a human ticket"
fi

if case_is "file names are cut the way basename and dirname cut them"; then
  repo="$(make_repo 1 name-helpers-repo)"
  paths=("" a a/ a// / /a /a/ /a// a/b a/b/ a//b ./a ../a "a b/c d" /a//b// C:/x/y -x a/-b "a/b.md" ".scratch/b/issues/01-t.md"
         'C:\x\y.jsonl' 'C:\y' 'a\b' 'a\b\' '\a' '\' 'a/b\c' 'a\b/c')
  helpers_out="$(cd "$repo" && FOREMAN_BATCH=batch bash -c '
    source "$1/lib/foreman-config.sh" || exit 1
    shift
    for p in "$@"; do
      _foreman_basename b "$p"; _foreman_dirname d "$p"
      printf "%s\t%s\n" "$b" "$d"
    done' _ "$FOREMAN_HOME" "${paths[@]}" 2>&1)"
  want=""
  for p in "${paths[@]}"; do
    want+="$(basename -- "$p")"$'\t'"$(dirname -- "$p")"$'\n'
  done
  assert_eq "$helpers_out" "${want%$'\n'}" "basename and dirname answers, for every awkward path"
fi

if case_is "status names the human ticket when it is next, with its note"; then
  repo="$(make_repo 2 status-next-human-repo)"
  make_human_ticket "$repo" 1

  run_foreman "$repo" status batch
  assert_eq "$ST" 0 "status exits 0"
  assert_contains "$OUT" "Next: 01-ticket.md   [HUMAN" "Next: is marked"
  assert_contains "$OUT" "batch/issues/01-ticket.md is a human ticket. The loop stops here." \
    "and the note follows"
  assert_contains "$OUT" "batch/handoff/01-ticket.md" "naming the handoff file"
fi

if case_is "warning: a human ticket with no followup ticket"; then
  repo="$(make_repo 1 warn-nocheck-repo)"
  make_human_ticket "$repo" 1

  run_foreman "$repo" status batch
  assert_eq "$ST" 0 "warnings never change the exit code"
  assert_contains "$OUT" \
    "warning: batch/issues/01-ticket.md is a human ticket with no ticket that Checks: it — run /foreman-human-followup-tickets" \
    "warns about the missing checker"
fi

if case_is "warning: a human ticket with no handoff file"; then
  repo="$(make_repo 1 warn-nohandoff-repo)"
  make_human_ticket "$repo" 1 none

  run_foreman "$repo" status batch
  assert_eq "$ST" 0 "warnings never change the exit code"
  assert_contains "$OUT" "warning: batch/issues/01-ticket.md has no Handoff: file — run /foreman-human-followup-tickets" \
    "warns about the missing handoff"
fi

if case_is "warning: a Handoff: line naming a file that does not exist"; then
  repo="$(make_repo 1 warn-missinghandoff-repo)"
  make_human_ticket "$repo" 1
  rm "$repo/batch/handoff/01-ticket.md"
  git -C "$repo" commit --quiet -am "the handoff file went missing"

  run_foreman "$repo" status batch
  assert_eq "$ST" 0 "warnings never change the exit code"
  assert_contains "$OUT" "warning: batch/issues/01-ticket.md has no Handoff: file — run /foreman-human-followup-tickets" \
    "warns the same way as a missing line"
fi

if case_is "warning: a followup ticket that is not immediately after the ticket it checks"; then
  repo="$(make_repo 3 warn-notadjacent-repo)"
  make_human_ticket "$repo" 1
  make_followup_ticket "$repo" 3 1
  { echo '<!-- ORDER:BEGIN -->'
    echo 'batch/issues/01-ticket.md'
    echo 'batch/issues/02-ticket.md'
    echo 'batch/issues/03-ticket.md'
    echo '<!-- ORDER:END -->'; } > "$repo/batch/order.md"
  git -C "$repo" add -A && git -C "$repo" commit --quiet -m "order.md puts 02 in between"

  run_foreman "$repo" status batch
  assert_eq "$ST" 0 "warnings never change the exit code"
  assert_contains "$OUT" \
    "warning: batch/issues/03-ticket.md should come right after batch/issues/01-ticket.md in order.md" \
    "warns that the checker is out of place"
fi

if case_is "warning: a Checks: line naming no ticket in the batch"; then
  repo="$(make_repo 2 warn-unresolved-repo)"
  sed -i 's/^\*\*Status:\*\* todo/&\n**Checks:** 99-nowhere.md/' "$repo/batch/issues/02-ticket.md"
  git -C "$repo" commit --quiet -am "ticket 2 checks nothing that exists"

  run_foreman "$repo" status batch
  assert_eq "$ST" 0 "warnings never change the exit code"
  assert_contains "$OUT" \
    "warning: batch/issues/02-ticket.md Checks: 99-nowhere.md, which is not a ticket in this batch" \
    "warns about the unresolved name"
fi

if case_is "with the human word off, only the followup-ticket warnings still apply"; then
  repo="$(make_repo 2 warn-humanoff-repo)"
  sed -i 's/^\*\*Status:\*\* todo/**Status:** ready-for-human/' "$repo/batch/issues/01-ticket.md"
  sed -i 's/^\*\*Status:\*\* todo/&\n**Checks:** 99-nowhere.md/' "$repo/batch/issues/02-ticket.md"
  git -C "$repo" commit --quiet -am "ticket 1 human, ticket 2 checks nothing real"

  FOREMAN_HUMAN_WORD= run_foreman "$repo" status batch
  assert_eq "$ST" 0 "still exits 0"
  assert_missing "$OUT" "is a human ticket with no ticket" "warning 1 is skipped"
  assert_missing "$OUT" "has no Handoff:" "warning 2 is skipped"
  assert_contains "$OUT" "which is not a ticket in this batch" "warning 4 still applies"
fi

if case_is "dry-run at a human ticket still shows the marked listing and warnings"; then
  repo="$(make_repo 1 warn-dryrun-repo)"
  make_human_ticket "$repo" 1

  run_foreman "$repo" dry-run batch
  assert_eq "$ST" 0 "exits 0"
  assert_contains "$OUT" "  1  01-ticket.md   [HUMAN]" "the listing is marked"
  assert_contains "$OUT" \
    "warning: batch/issues/01-ticket.md is a human ticket with no ticket that Checks: it — run /foreman-human-followup-tickets" \
    "and the warning is printed"
  assert_contains "$OUT" "Would stop before batch/issues/01-ticket.md" "still says it would stop"
fi

if case_is "the start-of-run sweep renames a finished ticket and leaves a dirty tree alone"; then
  repo="$(make_repo 2 sweep-repo)"
  sed -i 's/^\*\*Status:\*\* todo/**Status:** done\n\n- [x] the thing/' "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "ticket 1 done by hand"

  run_foreman "$repo" status batch
  run_foreman "$repo" dry-run batch
  [ -e "$repo/batch/issues/01-ticket.md" ] && pass || fail "status and dry-run rename nothing"

  run_foreman "$repo" run batch 1
  [ -e "$repo/DONE_batch/issues/DONE_01-ticket.md" ] && pass || fail "a run renames it before picking a ticket"
  assert_contains "$OUT" "✓ marked done" "and says so"
  assert_contains "$(git -C "$repo" log --format=%s)" "chore: mark 01-ticket.md done" "in a commit of its own"

  repo="$(make_repo 2 sweep-unticked-repo)"
  sed -i 's/^\*\*Status:\*\* todo/**Status:** done\n\n- [ ] the thing/' "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "ticket 1 done by hand, boxes unticked"
  run_foreman "$repo" run batch 1
  [ -e "$repo/DONE_batch/issues/01-ticket.md" ] && pass || fail "an unticked ticket keeps its name"

  repo="$(make_repo 3 sweep-dirty-repo)"
  sed -i 's/^\*\*Status:\*\* todo/**Status:** done/' "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "ticket 1 done by hand"
  printf 'uncommitted\n' > "$repo/scratch.txt"
  FOREMAN_ALLOW_DIRTY=1 run_foreman "$repo" run batch 1
  [ -e "$repo/batch/issues/01-ticket.md" ] && pass || fail "a dirty tree is not swept"
  assert_missing "$(git -C "$repo" log --format=%s)" "mark 01-ticket.md done" "and no rename commit was made"
fi

# ---------------------------------------------------------------------------
# Ordering
# ---------------------------------------------------------------------------

# A stub `claude` on PATH for `foreman order`: captures the `-p` prompt to
# FOREMAN_ORDER_PROMPT_LOG and prints a placeholder response, so ordering runs with no model
# and no cost. Prints the stub's own directory — put it first on PATH.
make_claude_stub() {
  local dir="$WORK/claude-stub-$CASE_IDX"    # one per case: cases run side by side
  mkdir -p "$dir"
  cat > "$dir/claude" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    -p) shift; [ -n "${FOREMAN_ORDER_PROMPT_LOG:-}" ] && printf '%s' "$1" > "$FOREMAN_ORDER_PROMPT_LOG" ;;
  esac
  shift
done
echo '{"total_cost_usd":0}'
STUB
  chmod +x "$dir/claude"
  printf '%s' "$dir"
}

# order.md need only exist for `foreman order` to run — it always re-derives the ticket list
# itself (--unordered). But `foreman_human_warnings` reads the batch through `--all`, which DOES
# honour order.md, so the block has to list every ticket already in batch/issues, or an empty
# block reads as an empty batch.
write_order_stub() {    # write_order_stub REPO
  local repo="$1"
  { echo '<!-- ORDER:BEGIN -->'
    for f in "$repo"/batch/issues/*.md; do echo "batch/issues/$(basename "$f")"; done
    echo '<!-- ORDER:END -->'; } > "$repo/batch/order.md"
  git -C "$repo" add -A && git -C "$repo" commit --quiet -m "order.md stub"
}

if case_is "foreman order runs with a stub claude, spending no money and needing no model"; then
  repo="$(make_repo 2 order-stub-repo)"
  write_order_stub "$repo"
  log="$WORK/order-stub-prompt.txt"

  PATH="$(make_claude_stub):$PATH" FOREMAN_ORDER_PROMPT_LOG="$log" run_foreman "$repo" order batch
  assert_eq "$ST" 0 "foreman order exits 0 against the stub"
  assert_contains "$OUT" "wrote batch/order.md" "it reports writing order.md"
  [ -f "$log" ] && pass || fail "the stub captured a prompt"
  assert_contains "$(cat "$log")" "Tickets in batch:" "the prompt lists the batch's tickets"
fi

if case_is "the ordering prompt names human tickets and followup tickets"; then
  repo="$(make_repo 3 order-human-repo)"
  make_human_ticket "$repo" 2
  make_followup_ticket "$repo" 3 2
  write_order_stub "$repo"
  log="$WORK/order-human-prompt.txt"

  PATH="$(make_claude_stub):$PATH" FOREMAN_ORDER_PROMPT_LOG="$log" run_foreman "$repo" order batch
  assert_eq "$ST" 0 "foreman order still exits 0"
  prompt="$(cat "$log")"
  assert_contains "$prompt" "HUMAN TICKETS" "the human-tickets section is present"
  assert_contains "$prompt" "batch/issues/02-ticket.md" "naming the human ticket"
  assert_contains "$prompt" "FOLLOWUP TICKETS" "the followup-tickets section is present"
  assert_contains "$prompt" "Blocked by" "and the Blocked by: sentence is always there"
fi

if case_is "with neither kind of ticket, the ordering prompt has no human or followup sections"; then
  repo="$(make_repo 2 order-plain-repo)"
  write_order_stub "$repo"
  log="$WORK/order-plain-prompt.txt"

  PATH="$(make_claude_stub):$PATH" FOREMAN_ORDER_PROMPT_LOG="$log" run_foreman "$repo" order batch
  assert_eq "$ST" 0 "foreman order exits 0"
  prompt="$(cat "$log")"
  assert_missing "$prompt" "HUMAN TICKETS" "no human-tickets section"
  assert_missing "$prompt" "FOLLOWUP TICKETS" "no followup-tickets section"
  assert_contains "$prompt" "Blocked by" "the Blocked by: sentence is still there"
fi

# A stub `claude` that prints $STUB_OUT on stdout and exits $STUB_EXIT, for the failure cases.
make_canned_claude_stub() {
  local dir="$WORK/canned-stub-$CASE_IDX"
  mkdir -p "$dir"
  cat > "$dir/claude" <<'STUB'
#!/bin/bash
printf '%s\n' "$STUB_OUT"
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$dir/claude"
  printf '%s' "$dir"
}

if case_is "foreman order says why the agent call failed, and points at /login when the login expired"; then
  repo="$(make_repo 1 order-auth-repo)"
  write_order_stub "$repo"
  before="$(cat "$repo/batch/order.md")"

  PATH="$(make_canned_claude_stub):$PATH" STUB_EXIT=1 \
    STUB_OUT='{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":null,"total_cost_usd":0,"result":"Failed to authenticate: OAuth session expired and could not be refreshed"}' \
    run_foreman "$repo" order batch
  assert_eq "$ST" 1 "a failed agent call exits 1"
  assert_contains "$OUT" "OAuth session expired" "it shows what claude said"
  assert_contains "$OUT" "claude /login" "it points at the fix"
  assert_eq "$(cat "$repo/batch/order.md")" "$before" "order.md is unchanged"
fi

if case_is "foreman order treats is_error as a failure even when claude exits 0"; then
  repo="$(make_repo 1 order-iserror-repo)"
  write_order_stub "$repo"

  PATH="$(make_canned_claude_stub):$PATH" STUB_EXIT=0 \
    STUB_OUT='{"type":"result","subtype":"success","is_error":true,"total_cost_usd":0,"result":"Prompt is too long for this model"}' \
    run_foreman "$repo" order batch
  assert_eq "$ST" 1 "is_error:true fails the call"
  assert_contains "$OUT" "Prompt is too long" "it shows the result text"
  assert_missing "$OUT" "wrote" "it does not claim to have written the order"
  assert_missing "$OUT" "claude /login" "and gives no login hint for an unrelated error"
fi

if case_is "foreman order shows non-JSON output from a failed call"; then
  repo="$(make_repo 1 order-nonjson-repo)"
  write_order_stub "$repo"

  PATH="$(make_canned_claude_stub):$PATH" STUB_EXIT=1 STUB_OUT='claude: unexpected failure' \
    run_foreman "$repo" order batch
  assert_eq "$ST" 1 "the call failed"
  assert_contains "$OUT" "claude: unexpected failure" "the raw output is shown"
fi

if case_is "foreman order still reports the cost of a successful call"; then
  repo="$(make_repo 1 order-cost-repo)"
  write_order_stub "$repo"

  PATH="$(make_canned_claude_stub):$PATH" STUB_EXIT=0 \
    STUB_OUT='{"is_error":false,"total_cost_usd":0.1234,"result":"done"}' \
    run_foreman "$repo" order batch
  assert_eq "$ST" 0 "a clean call exits 0"
  assert_contains "$OUT" 'wrote batch/order.md (cost $0.1234)' "the cost is reported"
fi

if case_is "foreman order warns about a human ticket with no followup ticket, and still exits 0"; then
  repo="$(make_repo 1 order-warn-repo)"
  make_human_ticket "$repo" 1
  write_order_stub "$repo"

  PATH="$(make_claude_stub):$PATH" run_foreman "$repo" order batch
  assert_eq "$ST" 0 "warnings never change the exit code"
  assert_contains "$OUT" \
    "warning: batch/issues/01-ticket.md is a human ticket with no ticket that Checks: it — run /foreman-human-followup-tickets" \
    "and the warning is printed after ordering"
fi

# ---------------------------------------------------------------------------
# foreman commands
# ---------------------------------------------------------------------------

# A claude config directory holding this checkout's foreman-conf-commands skill, as install.sh
# would leave it. Prints its path — point CLAUDE_CONFIG_DIR at it.
make_conf_skill_config() {
  local dir="$WORK/conf-skill-config-$CASE_IDX"
  mkdir -p "$dir/skills/foreman-conf-commands"
  cp "$FOREMAN_HOME/skills/foreman-conf-commands/SKILL.md" "$dir/skills/foreman-conf-commands/"
  printf '%s' "$dir"
}

# A stub `claude` standing in for the skill: captures the `-p` prompt to STUB_PROMPT_LOG,
# runs STUB_SCRIPT (from the repo root, as the agent would) to make its edit, then prints
# STUB_OUT — a clean zero-cost reply unless set — and exits STUB_EXIT.
make_commands_claude_stub() {
  local dir="$WORK/commands-stub-$CASE_IDX"
  mkdir -p "$dir"
  cat > "$dir/claude" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    -p) shift; [ -n "${STUB_PROMPT_LOG:-}" ] && printf '%s' "$1" > "$STUB_PROMPT_LOG" ;;
  esac
  shift
done
[ -z "${STUB_SCRIPT:-}" ] || bash -c "$STUB_SCRIPT"
if [ -n "${STUB_OUT:-}" ]; then printf '%s\n' "$STUB_OUT"; else echo '{"is_error":false,"total_cost_usd":0}'; fi
exit "${STUB_EXIT:-0}"
STUB
  chmod +x "$dir/claude"
  printf '%s' "$dir"
}

# What the skill does to one slot: the commented-out line becomes the set line, in place, with
# the evidence comment above it.
SET_TEST_CMD='sed -i "s|^#FOREMAN_TEST_CMD=.*|# foreman-conf-commands: from Makefile\nFOREMAN_TEST_CMD=\"make test\"|" batch/foreman.conf'

if case_is "foreman commands runs the skill headless and prints each slot as the conf now has it"; then
  repo="$(make_repo 1 commands-repo)"
  log="$WORK/commands-prompt.txt"

  CLAUDE_CONFIG_DIR="$(make_conf_skill_config)" PATH="$(make_commands_claude_stub):$PATH" \
    STUB_PROMPT_LOG="$log" STUB_SCRIPT="$SET_TEST_CMD" run_foreman "$repo" commands batch
  assert_eq "$ST" 0 "foreman commands exits 0"
  assert_eq "$(cat "$log" 2>/dev/null)" "/foreman-conf-commands batch" "the prompt is the skill's slash command"
  assert_contains "$OUT" "updated batch/foreman.conf" "it says the conf was updated"
  assert_contains "$OUT" 'FOREMAN_TEST_CMD="make test"' "it prints the line the agent set"
  assert_contains "$OUT" "left empty  FOREMAN_CHECK_CMD" "and names the slots it left empty"
  assert_contains "$(cat "$repo/batch/foreman.conf")" "# foreman-conf-commands: from Makefile" "the evidence comment is kept"
fi

if case_is "foreman commands skips, changing nothing, when the skill is not installed"; then
  repo="$(make_repo 1 commands-noskill-repo)"
  log="$WORK/commands-noskill-prompt.txt"
  before="$(cat "$repo/batch/foreman.conf")"

  PATH="$(make_commands_claude_stub):$PATH" STUB_PROMPT_LOG="$log" STUB_SCRIPT="$SET_TEST_CMD" \
    run_foreman "$repo" commands batch
  assert_eq "$ST" 0 "a missing skill is not an error"
  assert_contains "$OUT" "foreman-conf-commands skill is not installed" "it says why it skipped"
  assert_contains "$OUT" "install.sh" "and how to fix it"
  [ -e "$log" ] && fail "claude was not called" || pass
  assert_eq "$(cat "$repo/batch/foreman.conf")" "$before" "foreman.conf is unchanged"
fi

if case_is "foreman commands leaves a conf alone once every slot is set, even to empty"; then
  repo="$(make_repo 1 commands-allset-repo)"
  log="$WORK/commands-allset-prompt.txt"
  printf '%s\n' 'FOREMAN_CHECK_CMD="make lint"' 'export FOREMAN_TEST_CMD="make test"' \
    'FOREMAN_FOCUSED_TEST_CMD=' 'FOREMAN_SANDBOX_SETUP=' 'FOREMAN_SANDBOX_PROBE=' >> "$repo/batch/foreman.conf"

  CLAUDE_CONFIG_DIR="$(make_conf_skill_config)" PATH="$(make_commands_claude_stub):$PATH" \
    STUB_PROMPT_LOG="$log" run_foreman "$repo" commands batch
  assert_eq "$ST" 0 "exits 0"
  assert_contains "$OUT" "already set" "it says there is nothing to fill in"
  [ -e "$log" ] && fail "claude was not called" || pass
fi

if case_is "foreman commands fails, and says what claude said, when the agent call fails"; then
  repo="$(make_repo 1 commands-fail-repo)"

  CLAUDE_CONFIG_DIR="$(make_conf_skill_config)" PATH="$(make_commands_claude_stub):$PATH" STUB_EXIT=0 \
    STUB_OUT='{"is_error":true,"total_cost_usd":0,"result":"Failed to authenticate: OAuth session expired"}' \
    run_foreman "$repo" commands batch
  assert_eq "$ST" 1 "is_error:true fails the call, even with exit 0"
  assert_contains "$OUT" "fill in batch/foreman.conf by hand" "it says what to do instead"
  assert_contains "$OUT" "OAuth session expired" "it shows what claude said"
  assert_contains "$OUT" "claude /login" "and points at the fix"
  assert_missing "$OUT" "updated batch/foreman.conf" "it does not claim to have updated the conf"
fi

if case_is "foreman commands catches an edit that leaves foreman.conf unparseable"; then
  repo="$(make_repo 1 commands-broken-repo)"

  CLAUDE_CONFIG_DIR="$(make_conf_skill_config)" PATH="$(make_commands_claude_stub):$PATH" \
    STUB_SCRIPT="printf 'FOREMAN_TEST_CMD=\"make test\n' >> batch/foreman.conf" \
    run_foreman "$repo" commands batch
  assert_eq "$ST" 1 "a broken conf exits 1"
  assert_contains "$OUT" "no longer parses" "it says the conf is broken"
  assert_missing "$OUT" "updated batch/foreman.conf" "rather than reporting the update"
fi

if case_is "init fills in the commands of a conf it writes, but not with --no-commands or for a kept conf"; then
  repo="$(make_repo 1 init-commands-repo)"
  rm -f "$repo/batch/foreman.conf"
  log="$WORK/init-commands-prompt.txt"
  config="$(make_conf_skill_config)"
  stub="$(make_commands_claude_stub)"

  CLAUDE_CONFIG_DIR="$config" PATH="$stub:$PATH" STUB_PROMPT_LOG="$log" STUB_SCRIPT="$SET_TEST_CMD" \
    run_foreman "$repo" init batch --no-order
  assert_eq "$ST" 0 "init exits 0"
  assert_eq "$(cat "$log" 2>/dev/null)" "/foreman-conf-commands batch" "init ran the skill on the new conf"
  assert_contains "$OUT" 'FOREMAN_TEST_CMD="make test"' "and printed what it set"

  rm -f "$log"
  CLAUDE_CONFIG_DIR="$config" PATH="$stub:$PATH" STUB_PROMPT_LOG="$log" run_foreman "$repo" init batch --no-order
  assert_eq "$ST" 0 "a second init exits 0"
  [ -e "$log" ] && fail "a conf init kept is not handed to the agent again" || pass

  repo="$(make_repo 1 init-nocommands-repo)"
  rm -f "$repo/batch/foreman.conf"
  CLAUDE_CONFIG_DIR="$config" PATH="$stub:$PATH" STUB_PROMPT_LOG="$log" \
    run_foreman "$repo" init batch --no-order --no-commands
  assert_eq "$ST" 0 "init --no-commands exits 0"
  [ -e "$log" ] && fail "--no-commands skips the agent" || pass
  assert_contains "$(cat "$repo/batch/foreman.conf")" '#FOREMAN_TEST_CMD=' "and the slots stay commented out"
fi

# ---------------------------------------------------------------------------
# install.sh and the skill copy
# ---------------------------------------------------------------------------

# A throwaway copy of this checkout's bin/lib/skills/install.sh, so a test can edit its
# SKILL.md (simulating a pulled update) without touching the real repo. Prints its path.
make_foreman_checkout() {
  local name="${1:-checkout}" dir
  dir="$WORK/$name"
  mkdir -p "$dir"
  cp -r "$FOREMAN_HOME/bin" "$FOREMAN_HOME/lib" "$FOREMAN_HOME/skills" "$FOREMAN_HOME/install.sh" "$dir/"
  printf '%s' "$dir"
}

# Runs $1/install.sh with HOME, CLAUDE_CONFIG_DIR and --to all pointed at fresh directories
# under $WORK/$2, plus any extra arguments. Captures output in $OUT, status in $ST, and sets
# INSTALL_HOME / INSTALL_CONFIG / INSTALL_BIN for the caller to inspect. Calling it again
# with the same NAME reuses the same three directories — that is what "re-running
# install.sh" and "--uninstall after installing" both mean here.
run_install() {
  local checkout="$1" name="$2"; shift 2
  INSTALL_HOME="$WORK/$name-home"
  INSTALL_CONFIG="$WORK/$name-config"
  INSTALL_BIN="$WORK/$name-bin"
  mkdir -p "$INSTALL_HOME" "$INSTALL_CONFIG" "$INSTALL_BIN"
  OUT="$(HOME="$INSTALL_HOME" CLAUDE_CONFIG_DIR="$INSTALL_CONFIG" bash "$checkout/install.sh" --to "$INSTALL_BIN" "$@" 2>&1)"
  ST=$?
}

skill_copy_dir() { printf '%s/skills/foreman-human-followup-tickets' "$1"; }

if case_is "install.sh installs the shims and a marked copy of the skill"; then
  checkout="$(make_foreman_checkout install-basic-checkout)"
  run_install "$checkout" install-basic

  assert_eq "$ST" 0 "install.sh exits 0"
  [ -f "$INSTALL_BIN/foreman" ] && pass || fail "the bash shim was written"
  [ -f "$INSTALL_BIN/foreman.cmd" ] && pass || fail "the cmd shim was written"
  [ -f "$(skill_copy_dir "$INSTALL_CONFIG")/SKILL.md" ] && pass || fail "the skill's SKILL.md was copied"
  [ -f "$(skill_copy_dir "$INSTALL_CONFIG")/.foreman-installed-from" ] && pass || fail "the copy carries the marker"
  [ -f "$INSTALL_CONFIG/skills/foreman-conf-commands/.foreman-installed-from" ] && pass || fail "every skill is copied, foreman-conf-commands too"
  assert_contains "$OUT" "installed skill" "and says so"
fi

if case_is "re-running install.sh after the checkout's SKILL.md changes replaces the copy, no --force needed"; then
  checkout="$(make_foreman_checkout install-update-checkout)"
  run_install "$checkout" install-update
  assert_eq "$ST" 0 "the first install exits 0"

  printf '\n<!-- a line the pulled update added -->\n' >> "$checkout/skills/foreman-human-followup-tickets/SKILL.md"
  run_install "$checkout" install-update
  assert_eq "$ST" 0 "the second install exits 0 without --force"
  assert_contains "$(cat "$(skill_copy_dir "$INSTALL_CONFIG")/SKILL.md")" \
    "a line the pulled update added" "the installed copy picked up the change"
fi

if case_is "a skill directory without the marker refuses and writes nothing; --force overwrites it"; then
  checkout="$(make_foreman_checkout install-foreign-checkout)"
  INSTALL_HOME="$WORK/install-foreign-home"
  INSTALL_CONFIG="$WORK/install-foreign-config"
  # Deliberately NOT created — a genuine "write nothing" refusal must not even create it.
  INSTALL_BIN="$WORK/install-foreign-bin"
  mkdir -p "$INSTALL_HOME" "$(skill_copy_dir "$INSTALL_CONFIG")"
  printf "someone else's skill\n" > "$(skill_copy_dir "$INSTALL_CONFIG")/SKILL.md"

  OUT="$(HOME="$INSTALL_HOME" CLAUDE_CONFIG_DIR="$INSTALL_CONFIG" bash "$checkout/install.sh" --to "$INSTALL_BIN" 2>&1)"; ST=$?
  assert_eq "$ST" 1 "refuses without --force"
  assert_contains "$(cat "$(skill_copy_dir "$INSTALL_CONFIG")/SKILL.md")" \
    "someone else's skill" "the foreign directory is untouched"
  [ -e "$INSTALL_BIN" ] && fail "nothing was written, not even the bin directory itself" || pass

  OUT="$(HOME="$INSTALL_HOME" CLAUDE_CONFIG_DIR="$INSTALL_CONFIG" bash "$checkout/install.sh" --to "$INSTALL_BIN" --force 2>&1)"; ST=$?
  assert_eq "$ST" 0 "--force overwrites it"
  [ -f "$(skill_copy_dir "$INSTALL_CONFIG")/.foreman-installed-from" ] && pass || fail "the copy now carries the marker"
fi

if case_is "--uninstall removes a marked copy and leaves an unmarked one alone"; then
  checkout="$(make_foreman_checkout install-uninstall-checkout)"

  run_install "$checkout" install-uninstall-marked
  assert_eq "$ST" 0 "the install exits 0"
  run_install "$checkout" install-uninstall-marked --uninstall
  assert_eq "$ST" 0 "uninstall exits 0"
  [ -e "$(skill_copy_dir "$INSTALL_CONFIG")" ] && fail "the marked copy was removed" || pass
  [ -e "$INSTALL_BIN/foreman" ] && fail "the shims were removed too" || pass

  INSTALL_HOME="$WORK/install-uninstall-foreign-home"
  INSTALL_CONFIG="$WORK/install-uninstall-foreign-config"
  INSTALL_BIN="$WORK/install-uninstall-foreign-bin"
  mkdir -p "$INSTALL_HOME" "$(skill_copy_dir "$INSTALL_CONFIG")" "$INSTALL_BIN"
  printf "someone else's skill\n" > "$(skill_copy_dir "$INSTALL_CONFIG")/SKILL.md"
  OUT="$(HOME="$INSTALL_HOME" CLAUDE_CONFIG_DIR="$INSTALL_CONFIG" bash "$checkout/install.sh" --to "$INSTALL_BIN" --uninstall 2>&1)"; ST=$?
  assert_eq "$ST" 0 "uninstall still exits 0 when there is nothing of its own to remove"
  [ -f "$(skill_copy_dir "$INSTALL_CONFIG")/SKILL.md" ] && pass || fail "the unmarked directory is left alone"
fi

if case_is "--no-skill installs only the shims"; then
  checkout="$(make_foreman_checkout install-noskill-checkout)"
  run_install "$checkout" install-noskill --no-skill

  assert_eq "$ST" 0 "install.sh exits 0"
  [ -f "$INSTALL_BIN/foreman" ] && pass || fail "the shims were still installed"
  [ -e "$(skill_copy_dir "$INSTALL_CONFIG")" ] && fail "no skill directory was created" || pass
fi

if case_is "install.sh warns under WSL, names the WSL home and the Git Bash command, and installs the same"; then
  checkout="$(make_foreman_checkout install-wsl-checkout)"

  # Not a real WSL: the signal is WSL_DISTRO_NAME, or "microsoft" in /proc/version, which
  # FOREMAN_PROC_VERSION lets a test point at a file of its own.
  OUT="$(HOME="$WORK/install-wsl-home" CLAUDE_CONFIG_DIR="$WORK/install-wsl-config" WSL_DISTRO_NAME=Ubuntu \
    bash "$checkout/install.sh" --to "$WORK/install-wsl-bin" 2>&1)"; ST=$?
  assert_eq "$ST" 0 "the warning does not change the exit code"
  assert_contains "$OUT" "WSL" "says it is running under WSL"
  assert_contains "$OUT" "$WORK/install-wsl-home" "names the WSL home it is installing into"
  assert_contains "$OUT" 'C:\Program Files\Git\bin\bash.exe' "gives the Git Bash command for Windows"
  [ -f "$WORK/install-wsl-bin/foreman" ] && [ -f "$WORK/install-wsl-bin/foreman.cmd" ] && pass || fail "the shims were still installed"
  [ -f "$(skill_copy_dir "$WORK/install-wsl-config")/SKILL.md" ] && pass || fail "the skill was still installed"
  assert_contains "$OUT" "installed skill" "and says so"

  # The same signal from /proc/version.
  printf 'Linux version 5.15.153.1-microsoft-standard-WSL2 (root@build) (gcc)\n' > "$WORK/fake-proc-wsl"
  OUT="$(HOME="$WORK/install-wsl2-home" CLAUDE_CONFIG_DIR="$WORK/install-wsl2-config" FOREMAN_PROC_VERSION="$WORK/fake-proc-wsl" \
    bash "$checkout/install.sh" --to "$WORK/install-wsl2-bin" 2>&1)"; ST=$?
  assert_eq "$ST" 0 "a /proc/version naming microsoft exits 0 too"
  assert_contains "$OUT" 'C:\Program Files\Git\bin\bash.exe' "and warns"

  # Outside WSL: nothing new, even with a /proc/version that names something else.
  printf 'Linux version 6.1.0-18-amd64 (debian-kernel@lists.debian.org)\n' > "$WORK/fake-proc-linux"
  OUT="$(HOME="$WORK/install-nowsl-home" CLAUDE_CONFIG_DIR="$WORK/install-nowsl-config" FOREMAN_PROC_VERSION="$WORK/fake-proc-linux" \
    WSL_DISTRO_NAME= bash "$checkout/install.sh" --to "$WORK/install-nowsl-bin" 2>&1)"; ST=$?
  assert_eq "$ST" 0 "the install outside WSL exits 0"
  assert_missing "$OUT" "WSL" "no warning outside WSL"
fi

if case_is "foreman doctor warns when the installed skill copy is stale, and is silent otherwise"; then
  repo="$WORK/doctor-skill-repo"
  mkdir -p "$repo"
  git -C "$repo" init --quiet
  git -C "$repo" config user.name foreman-test
  git -C "$repo" config user.email test@foreman.invalid

  doctor_home="$WORK/doctor-skill-home"
  doctor_config="$WORK/doctor-skill-config"
  doctor_bin="$WORK/doctor-skill-bin"
  mkdir -p "$doctor_home" "$doctor_config"

  run_doctor() { OUT="$(cd "$repo" && HOME="$doctor_home" CLAUDE_CONFIG_DIR="$doctor_config" "$FOREMAN" doctor 2>&1)"; ST=$?; }

  run_doctor
  assert_missing "$OUT" "foreman-human-followup-tickets" "silent before the skill is installed"

  HOME="$doctor_home" CLAUDE_CONFIG_DIR="$doctor_config" bash "$FOREMAN_HOME/install.sh" --to "$doctor_bin" >/dev/null

  run_doctor
  assert_missing "$OUT" "STALE" "silent — the installed copy matches this checkout"

  printf '\n<!-- drift -->\n' >> "$(skill_copy_dir "$doctor_config")/SKILL.md"
  run_doctor
  assert_contains "$OUT" "STALE" "warns once the installed copy drifts"
  assert_contains "$OUT" "foreman-human-followup-tickets" "names the skill"
  assert_contains "$OUT" "install.sh" "and says to re-run it"
fi

if case_is "foreman finds its toolkit when bash is handed a Windows path, as foreman.cmd does, from any directory"; then
  # foreman.cmd runs `bash C:\...\bin\foreman`. That path has no '/', so the dispatcher once
  # resolved FOREMAN_HOME against the current directory and looked for lib/ one level above it.
  if command -v cygpath >/dev/null 2>&1; then
    elsewhere="$WORK/winpath-elsewhere"
    mkdir -p "$elsewhere"
    OUT="$(cd "$elsewhere" && bash "$(cygpath -w "$FOREMAN")" version 2>&1)"; ST=$?
    assert_eq "$ST" 0 "version exits 0 given a backslash path"
    assert_contains "$OUT" "$FOREMAN_HOME" "FOREMAN_HOME is the checkout, not a path beside the current directory"
  else
    pass  # no cygpath, so this is not Windows: a backslash path is just an odd file name
  fi
fi

# --- colour (foreman-ui.sh) ----------------------------------------------------
# run_foreman captures through `$(...)`, so none of these runs has a terminal: what they show is
# the auto rule (plain), and FOREMAN_COLOR=always for the colour itself. A real terminal is the
# one thing a test run cannot give — try `FOREMAN_COLOR=auto foreman run <batch>` by hand.

# The lines whose wording colour must not change: every event line, rule and frame, with the
# things that differ between two runs (the run id, a commit's short sha) normalised away.
colour_lines() {
  printf '%s\n' "$1" | sed $'s/\033\[[0-9;]*m//g' |
    grep -E '^( +(✓|⋯|↩|✗)|──|== )' |
    sed -E 's/[0-9]{8}T[0-9]{6}Z-[0-9]+/RUN/; s/[0-9a-f]{7}( |$)/SHA\1/'
}

# The colour tier of one stream, in an environment of its own. $1 is tty or pipe — whether the
# stream asked about is a terminal — $2 the file descriptor, and the rest are VAR=value
# settings. A terminal is made with `script`, which not every machine has.
TIER_PROBE="$WORK/tier-probe.sh"
printf '%s\n' '. "$1/lib/foreman-ui.sh"' 'ui_color_tier t "$2"' 'printf "%s" "$t"' > "$TIER_PROBE"
tier_of() {
  local kind="$1" fd="$2" cmd out; shift 2
  printf -v cmd '%q ' env -u COLORTERM -u WT_SESSION -u NO_COLOR -u FOREMAN_COLOR -u TERM "$@" \
    bash "$TIER_PROBE" "$FOREMAN_HOME" "$fd"
  if [ "$kind" = tty ]; then
    [ "$fd" != 2 ] || cmd+='2>/dev/null'    # stdout stays the terminal; stderr is made a pipe
    out="$(script -qec "$cmd" /dev/null </dev/null 2>/dev/null)"
    printf '%s' "${out//$'\r'/}"
  else
    eval "$cmd" 2>/dev/null
  fi
}

if case_is "ui_color_tier decides none, 16, 256 or 24 per stream from the environment"; then
  # (stream, environment) -> tier. A pipe is what `$(…)` gives; every row of a terminal needs script.
  assert_eq "$(tier_of pipe 1 TERM=xterm)" none "auto: a pipe is plain"
  assert_eq "$(tier_of pipe 1 TERM=xterm-256color COLORTERM=truecolor)" none "auto: a pipe is plain whatever the terminal could do"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=never COLORTERM=truecolor)" none "never is none"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=always)" 16 "always with nothing detected is 16"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=always TERM=xterm)" 16 "always on a plain xterm is 16"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=always TERM=xterm-256color)" 256 "always follows a 256color TERM"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=always TERM=screen.xterm-256color)" 256 "and any TERM that ends in 256color"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=always COLORTERM=truecolor)" 24 "always follows COLORTERM=truecolor"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=always COLORTERM=24bit)" 24 "and COLORTERM=24bit"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=always WT_SESSION=1c3e)" 24 "and Windows Terminal, which sets WT_SESSION and not COLORTERM"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=always COLORTERM=truecolor TERM=xterm-256color)" 24 "24 beats 256"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=always COLORTERM=yes TERM=xterm)" 16 "another COLORTERM value says nothing"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=always NO_COLOR=1 TERM=dumb)" 16 "always wins over NO_COLOR and a dumb TERM"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=16 COLORTERM=truecolor)" 16 "16 pins the tier, whatever is detected"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=256)" 256 "256 pins it, on a pipe"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=truecolor)" 24 "truecolor pins it, on a pipe"
  assert_eq "$(tier_of pipe 1 FOREMAN_COLOR=truecolor NO_COLOR=1 TERM=dumb)" 24 "a pinned tier wins over NO_COLOR and a dumb TERM"
  assert_eq "$(tier_of pipe 2 FOREMAN_COLOR=256)" 256 "and on stderr"

  if command -v script >/dev/null 2>&1 && [ -n "$(tier_of tty 1 FOREMAN_COLOR=always)" ]; then
    assert_eq "$(tier_of tty 1 TERM=xterm)" 16 "auto: a plain terminal is 16"
    assert_eq "$(tier_of tty 1 TERM=xterm FOREMAN_COLOR=auto)" 16 "and so is auto named"
    assert_eq "$(tier_of tty 1 TERM=xterm-256color)" 256 "a 256color terminal is 256"
    assert_eq "$(tier_of tty 1 TERM=xterm COLORTERM=truecolor)" 24 "COLORTERM=truecolor is 24"
    assert_eq "$(tier_of tty 1 TERM=xterm COLORTERM=24bit)" 24 "COLORTERM=24bit is 24"
    assert_eq "$(tier_of tty 1 TERM=xterm WT_SESSION=1c3e)" 24 "WT_SESSION is 24"
    assert_eq "$(tier_of tty 1 TERM=xterm-256color COLORTERM=truecolor)" 24 "24 beats 256 on a terminal too"
    assert_eq "$(tier_of tty 1 TERM=xterm COLORTERM=yes)" 16 "an unknown COLORTERM is 16"
    assert_eq "$(tier_of tty 1 COLORTERM=truecolor NO_COLOR=1)" none "NO_COLOR is none, whatever the terminal could do"
    assert_eq "$(tier_of tty 1 COLORTERM=truecolor TERM=dumb)" none "a dumb TERM is none"
    assert_eq "$(tier_of tty 1 TERM=xterm COLORTERM=truecolor FOREMAN_COLOR=never)" none "never is none on a terminal"
    assert_eq "$(tier_of tty 1 TERM=xterm COLORTERM=truecolor FOREMAN_COLOR=16)" 16 "16 pins a 24-bit terminal down"
    assert_eq "$(tier_of tty 1 TERM=xterm NO_COLOR=1 FOREMAN_COLOR=256)" 256 "a pinned tier wins over NO_COLOR"
    assert_eq "$(tier_of tty 2 TERM=xterm COLORTERM=truecolor)" none "stderr is asked about on its own: it is a pipe here"
  else
    printf '  (no usable script(1): the terminal rows of the tier table are not run)\n'
  fi
fi

if case_is "ui_paint paints at the stream's tier: the palette at 24 and 256, the old codes at 16"; then
  ESC=$'\033'
  OUT="$(env -u COLORTERM -u WT_SESSION FOREMAN_COLOR=truecolor bash -c '. "$1/lib/foreman-ui.sh"; say_event ok landed "abc1234"' _ "$FOREMAN_HOME")"
  assert_eq "$OUT" "   ${ESC}[38;2;143;207;143m✓${ESC}[0m landed  ·  abc1234" "24 bits: the ok glyph in the palette's exact green, the words plain"

  OUT="$(env -u COLORTERM -u WT_SESSION FOREMAN_COLOR=256 bash -c '. "$1/lib/foreman-ui.sh"; say_event ok landed "abc1234"' _ "$FOREMAN_HOME")"
  assert_eq "$OUT" "   ${ESC}[38;5;114m✓${ESC}[0m landed  ·  abc1234" "256: the nearest xterm shade"

  OUT="$(env -u COLORTERM -u WT_SESSION FOREMAN_COLOR=16 bash -c '. "$1/lib/foreman-ui.sh"; say_event ok landed "abc1234"' _ "$FOREMAN_HOME")"
  assert_eq "$OUT" "   ${ESC}[32m✓${ESC}[0m landed  ·  abc1234" "16: the old ANSI green, as before"

  OUT="$(env -u COLORTERM -u WT_SESSION FOREMAN_COLOR=always TERM=xterm-256color bash -c '. "$1/lib/foreman-ui.sh"; say_event ok landed' _ "$FOREMAN_HOME")"
  assert_contains "$OUT" "${ESC}[38;5;114m✓" "always paints at the tier it detects"
  OUT="$(env -u WT_SESSION FOREMAN_COLOR=always COLORTERM=truecolor bash -c '. "$1/lib/foreman-ui.sh"; say_event ok landed' _ "$FOREMAN_HOME")"
  assert_contains "$OUT" "${ESC}[38;2;143;207;143m✓" "and at 24 bits under COLORTERM=truecolor"

  # Every style, at each tier.
  paint_all() {
    env -u COLORTERM -u WT_SESSION FOREMAN_COLOR="$1" bash -c '. "$1/lib/foreman-ui.sh"
      for s in ok warn error accent muted bogus; do ui_paint v 1 $s "<$s>"; printf "%s" "$v"; done' _ "$FOREMAN_HOME"
  }
  assert_eq "$(paint_all 16)" \
    "${ESC}[32m<ok>${ESC}[0m${ESC}[33m<warn>${ESC}[0m${ESC}[31m<error>${ESC}[0m${ESC}[36m<accent>${ESC}[0m${ESC}[2m<muted>${ESC}[0m${ESC}[0m<bogus>${ESC}[0m" \
    "16: the five styles keep their old codes"
  assert_eq "$(paint_all truecolor)" \
    "${ESC}[38;2;143;207;143m<ok>${ESC}[0m${ESC}[38;2;224;168;74m<warn>${ESC}[0m${ESC}[38;2;240;128;120m<error>${ESC}[0m${ESC}[38;2;246;213;142m<accent>${ESC}[0m${ESC}[38;2;168;162;153m<muted>${ESC}[0m${ESC}[0m<bogus>${ESC}[0m" \
    "24: ok, amber, error, sun and muted"
  assert_eq "$(paint_all 256)" \
    "${ESC}[38;5;114m<ok>${ESC}[0m${ESC}[38;5;179m<warn>${ESC}[0m${ESC}[38;5;210m<error>${ESC}[0m${ESC}[38;5;222m<accent>${ESC}[0m${ESC}[38;5;247m<muted>${ESC}[0m${ESC}[0m<bogus>${ESC}[0m" \
    "256: the same five, at their nearest indexes"

  # ui_color_on is "the tier is not none".
  assert_eq "$(env -u COLORTERM FOREMAN_COLOR=256 bash -c '. "$1/lib/foreman-ui.sh"; ui_color_on 1 && echo on || echo off' _ "$FOREMAN_HOME")" on "ui_color_on: a pinned tier is on"
  assert_eq "$(env -u COLORTERM FOREMAN_COLOR=never bash -c '. "$1/lib/foreman-ui.sh"; ui_color_on 1 && echo on || echo off' _ "$FOREMAN_HOME")" off "never is off"
  assert_eq "$(env -u COLORTERM -u FOREMAN_COLOR bash -c '. "$1/lib/foreman-ui.sh"; ui_color_on 1 && echo on || echo off' _ "$FOREMAN_HOME")" off "auto on a pipe is off"

  # Painting into a plain stream stays byte for byte the text.
  assert_eq "$(env -u COLORTERM -u FOREMAN_COLOR bash -c '. "$1/lib/foreman-ui.sh"; ui_paint v 1 ok "x y"; printf "%s" "$v"' _ "$FOREMAN_HOME")" "x y" "plain paint is the text"
fi

if case_is "the palette is defined once, with a hex, a 256 index and a 16 code per name"; then
  # The one assignment, as foreman-draw.cjs will read it: a regex over _UI_PALETTE='…'.
  table="$(sed -n "/^_UI_PALETTE='\$/,/^'\$/p" "$FOREMAN_HOME/lib/foreman-ui.sh" | sed '1d;$d')"
  assert_eq "$(printf '%s\n' "$table" | grep -c .)" 13 "thirteen names"
  assert_eq "$(grep -c "^_UI_PALETTE=" "$FOREMAN_HOME/lib/foreman-ui.sh")" 1 "defined in one place"
  names=""; bad=""
  while read -r name hex idx code extra; do
    names+="$name "
    [[ $hex =~ ^#[0-9a-f]{6}$ ]] || bad+=" $name:hex"
    [[ $idx =~ ^([0-9]{1,3}|-)$ ]] && { [ "$idx" = - ] || [ "$idx" -ge 16 -a "$idx" -le 255 ]; } || bad+=" $name:idx"
    [[ $code =~ ^[0-9]+$ ]] || bad+=" $name:code"
    [ -z "$extra" ] || bad+=" $name:extra"
    # The index is the nearest of the 216 cube colours and 24 greys, by squared distance.
    if [ "$idx" != - ]; then
      r=$((16#${hex:1:2})); g=$((16#${hex:3:2})); b=$((16#${hex:5:2}))
      best=-1; bestd=999999
      lv=(0 95 135 175 215 255)
      for ((i = 16; i < 256; i++)); do
        if [ $i -lt 232 ]; then n=$((i - 16)); cr=${lv[n / 36]}; cg=${lv[n / 6 % 6]}; cb=${lv[n % 6]}
        else cr=$((8 + 10 * (i - 232))); cg=$cr; cb=$cr; fi
        d=$(( (r - cr) ** 2 + (g - cg) ** 2 + (b - cb) ** 2 ))
        [ $d -lt $bestd ] && { bestd=$d; best=$i; }
      done
      [ "$best" = "$idx" ] || bad+=" $name:nearest-is-$best"
    fi
  done <<< "$table"
  assert_eq "$bad" "" "every row is well formed and its 256 index is the nearest shade"
  assert_eq "$names" "sun amber rust post earth shade night ok error muted dim text ink " "the names, in the spec's order"
  squeezed="$(printf '%s\n' "$table" | tr -s ' ')"
  assert_contains "$squeezed" "sun #f6d58e 222 33" "sun"
  assert_contains "$squeezed" "text #ece8e1 - 0" "text has no 256 index: below 24 bits it is the terminal's own"
fi

if case_is "FOREMAN_COLOR takes 16, 256 and truecolor beside auto, always and never"; then
  repo="$(make_repo 2 colour-values-repo)"
  for v in auto always never 16 256 truecolor; do
    FOREMAN_COLOR=$v run_foreman "$repo" status batch
    assert_eq "$ST" 0 "FOREMAN_COLOR=$v is accepted"
  done
  FOREMAN_COLOR=rainbow run_foreman "$repo" status batch
  assert_eq "$ST" 1 "an unknown value is refused"
  assert_contains "$OUT" "or 16, 256 or truecolor" "and the message names the pinned tiers"
  printf 'FOREMAN_COLOR=256\n' >> "$repo/batch/foreman.conf"
  git -C "$repo" commit --quiet -am "pin 256"
  run_foreman "$repo" status batch
  assert_eq "$ST" 0 "foreman.conf can pin a tier"
  assert_contains "$OUT" "${ESC:=$'\033'}[38;5;" "and a captured status is then painted at it"
fi

if case_is "colour is off when output is not a terminal, and the log never carries it"; then
  ESC=$'\033'
  repo="$(make_repo 3 colour-plain-repo)"
  FOREMAN_FAKE_BEHAVIOUR=transient:land:partial-turn:land run_foreman "$repo" run batch --unlimited

  assert_eq "$ST" 0 "the batch finishes"
  assert_missing "$OUT" "$ESC" "a captured run has no escape codes at all"
  assert_contains "$OUT" "   ✓ landed  ·  " "a landing line keeps its shape"
  assert_contains "$OUT" "   ⋯ progressed  ·  " "and a progress line"
  assert_contains "$OUT" "   ✗ did not land (exit 1)." "and a failure line"
  assert_contains "$OUT" "── iteration 1  ·  batch/issues/01-ticket.md" "and the iteration rule"
  assert_contains "$OUT" "== run " "and the summary frame"

  # NO_COLOR is a no-op here, being already off — and must not break anything.
  NO_COLOR=1 run_foreman "$repo" status batch
  assert_missing "$OUT" "$ESC" "status with NO_COLOR set is plain too"

  # Forcing colour on must not reach the files a run writes.
  repo="$(make_repo 3 colour-log-repo)"
  FOREMAN_COLOR=always FOREMAN_FAKE_BEHAVIOUR=land run_foreman "$repo" run batch --unlimited
  assert_missing "$(cat "$repo"/*batch/foreman-runs.log)" "$ESC" "the run log has no escape codes, even with colour forced"
  assert_missing "$(cat "$repo"/*batch/foreman-runs.jsonl)" "$ESC" "nor has the jsonl"
fi

if case_is "FOREMAN_COLOR=always colours the glyph or prefix only, and the words stay the same"; then
  ESC=$'\033'
  # A ticket with an open checkbox is what makes the loop print a `note:` when it lands. Both
  # runs get it, so the lines compared below are the same lines.
  plain_repo="$(make_repo 3 colour-same-plain)"
  printf '\n- [ ] still open\n' >> "$plain_repo/batch/issues/01-ticket.md"
  git -C "$plain_repo" commit --quiet -am "open box"
  FOREMAN_FAKE_BEHAVIOUR=transient:land:partial-turn:land run_foreman "$plain_repo" run batch --unlimited
  plain_lines="$(colour_lines "$OUT")"

  repo="$(make_repo 3 colour-same-repo)"
  printf '\n- [ ] still open\n' >> "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "open box"
  FOREMAN_COLOR=always FOREMAN_FAKE_BEHAVIOUR=transient:land:partial-turn:land \
    run_foreman "$repo" run batch --unlimited

  assert_contains "$OUT" "${ESC}[32m✓${ESC}[0m landed  ·  " "landed is a green tick"
  assert_contains "$OUT" "${ESC}[2m⋯${ESC}[0m progressed  ·  " "progress is a dim ellipsis"
  assert_contains "$OUT" "${ESC}[31m✗${ESC}[0m did not land (exit 1)." "a failure is a red cross"
  assert_contains "$OUT" "${ESC}[36m──${ESC}[0m iteration 1  ·  " "a rule is cyan, its text is not"
  assert_contains "$OUT" "${ESC}[36m==${ESC}[0m run " "the summary frame opens cyan"
  assert_contains "$OUT" "${ESC}[36m==${ESC}[0m"$'\n' "and closes cyan"
  assert_contains "$OUT" "   ${ESC}[33mnote:${ESC}[0m batch/issues/01-ticket.md is 'implemented' but has unchecked boxes" \
    "a note's prefix is yellow"
  # Take the codes out and the same words are left, in the same places.
  assert_eq "$(colour_lines "$OUT")" "$plain_lines" "stripped of colour, the output is the plain output"
fi

if case_is "FOREMAN_COLOR is read from foreman.conf, the environment beats it, and a bad value is refused"; then
  ESC=$'\033'
  repo="$(make_repo 4 colour-conf-repo)"
  printf 'FOREMAN_COLOR=always\n' >> "$repo/batch/foreman.conf"
  git -C "$repo" commit --quiet -am "colour on"

  run_foreman "$repo" run batch
  assert_contains "$OUT" "${ESC}[32m✓${ESC}[0m landed" "foreman.conf can turn colour on"

  FOREMAN_COLOR=never run_foreman "$repo" run batch
  assert_missing "$OUT" "$ESC" "and the environment wins over it"

  # An explicit FOREMAN_COLOR is a decision about foreman; NO_COLOR is a default for every tool.
  NO_COLOR=1 FOREMAN_COLOR=always run_foreman "$repo" run batch
  assert_contains "$OUT" "${ESC}[32m✓${ESC}[0m landed" "FOREMAN_COLOR=always wins over NO_COLOR"

  FOREMAN_COLOR=rainbow run_foreman "$repo" status batch
  assert_eq "$ST" 1 "an unknown value is a usage error"
  assert_contains "$OUT" "FOREMAN_COLOR must be auto, always or never (got 'rainbow')" "that says what is allowed"
fi

if case_is "a preflight failure is prefixed in colour only when asked to be"; then
  ESC=$'\033'
  repo="$(make_repo 1 colour-preflight-repo)"
  printf 'stray edit\n' >> "$repo/batch/issues/01-ticket.md"

  run_foreman "$repo" run batch
  assert_eq "$ST" 1 "a dirty tree is refused"
  assert_contains "$OUT" "preflight: the working tree is dirty." "plain: the prefix is just text"
  assert_missing "$OUT" "$ESC" "and there is no escape code"

  FOREMAN_COLOR=always run_foreman "$repo" run batch
  assert_eq "$ST" 1 "still refused"
  assert_contains "$OUT" "${ESC}[33mpreflight:${ESC}[0m the working tree is dirty." "forced: the prefix is yellow"
  assert_contains "$OUT" "           iteration's review sees only what this iteration wrote." \
    "continuation lines keep their 11-column indent, uncoloured"
fi

if case_is "a key echo is plain text unless colour is asked for, and always takes over the line"; then
  ESC=$'\033'
  ctl="$WORK/colour-keys-ctl"
  mkdir -p "$ctl"
  printf '3\n' > "$ctl/budget"
  printf '1\n' > "$ctl/iteration"

  OUT="$(bash "$FOREMAN_HOME/lib/foreman-keys.sh" --apply + "$ctl" 2>&1)"
  assert_eq "$OUT" $'\r\033[2K   ⌨ iterations: 1 of 4' "plain: byte for byte what it always was"

  OUT="$(FOREMAN_COLOR=always bash "$FOREMAN_HOME/lib/foreman-keys.sh" --apply + "$ctl" 2>&1)"
  assert_eq "$OUT" $'\r\033[2K   \033[36m⌨\033[0m iterations: 1 of 5' \
    "forced: only the glyph is cyan, and the erase-line still comes first"

  OUT="$(NO_COLOR=1 bash "$FOREMAN_HOME/lib/foreman-keys.sh" --apply + "$ctl" 2>&1)"
  assert_missing "$OUT" "[36m" "NO_COLOR keeps the echo plain"
fi

if case_is "--live draws its clock dim only when colour is on, and the line is otherwise the same"; then
  ESC=$'\033'
  repo="$(make_repo 2 colour-live-repo)"
  FOREMAN_FAKE_BEHAVIOUR=stream run_foreman "$repo" run batch --live
  assert_missing "$OUT" "$ESC" "a plain ticker line has no escape codes"
  assert_contains "$OUT" " · Write src/foo.js" "and is clock, dot, label"

  repo="$(make_repo 2 colour-live-forced-repo)"
  FOREMAN_COLOR=always FOREMAN_FAKE_BEHAVIOUR=stream run_foreman "$repo" run batch --live
  assert_contains "$OUT" "   ${ESC}[2m00:0" "forced: the clock digits are dim"
  assert_contains "$OUT" "${ESC}[0m · Write src/foo.js" "and the dot and the label are not"
fi

if case_is "status colours its labels when asked to, and prints the same words either way"; then
  ESC=$'\033'
  repo="$(make_repo 3 colour-status-repo)"
  sed -i 's/Status:\*\* todo/Status:** ready-for-human/' "$repo/batch/issues/02-ticket.md"
  git -C "$repo" commit --quiet -am "human ticket"

  run_foreman "$repo" status batch
  plain="$OUT"
  assert_missing "$plain" "$ESC" "a captured status is plain"
  assert_contains "$plain" "Batch: batch" "and keeps its first line"
  assert_contains "$plain" "  2  02-ticket.md   [HUMAN]" "and the marked list"

  FOREMAN_COLOR=always run_foreman "$repo" status batch
  assert_contains "$OUT" "${ESC}[36mBatch:${ESC}[0m batch" "forced: the Batch label is cyan"
  assert_contains "$OUT" "${ESC}[36mNext:${ESC}[0m 01-ticket.md" "and the Next label"
  assert_contains "$OUT" "02-ticket.md   ${ESC}[33m[HUMAN]${ESC}[0m" "and the human flag is yellow"
  assert_eq "$(printf '%s' "$OUT" | sed $'s/\033\[[0-9;]*m//g')" "$plain" "stripped of colour it is the plain status"
fi

# --- foreman convert ---------------------------------------------------------
# A repo as the toolkit left it before the rename: ralph.conf, RALPH_* settings, the old run
# files, the old .gitignore lines, prose that names ralph — plus one file of the project's
# own with ralph in its name, and credit to the Ralph loop. Prints its path.
make_ralph_repo() {
  local repo
  repo="$(make_repo 1 "$1")"
  git -C "$repo" mv batch/foreman.conf batch/ralph.conf
  printf '# Sourced by the ralph toolkit. Try `ralph doctor`.\nRALPH_EXEC=fake\n#RALPH_SANDBOX=ralph-<repo-name>\n' \
    > "$repo/batch/ralph.conf"
  printf '**/ralph-runs.jsonl\n**/.ralph-iter.bundle\n' >> "$repo/.gitignore"
  mkdir -p "$repo/docs"
  printf 'Run `ralph run batch`, then read ralph-loop.sh.\r\nBuilt on the Ralph loop, after Ralph Wiggum.\r\nSee docs/ralph-notes.md.\r\n' \
    > "$repo/docs/guide.md"
  printf 'notes\n' > "$repo/docs/ralph-notes.md"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "as ralph left it"
  printf '{}\n' > "$repo/batch/ralph-runs.jsonl"
  printf 'bundle' > "$repo/batch/.ralph-iter.bundle"
  printf '%s' "$repo"
}

if case_is "convert moves a ralph project to foreman, and keeps the credit and the project's own names"; then
  repo="$(make_ralph_repo convert-repo)"
  mkdir -p "$WORK/convert-home/.config/ralph"
  printf 'RALPH_DOCKER_USERNAME=someone\n' > "$WORK/convert-home/.config/ralph/env"
  OUT="$(cd "$repo" && unset FOREMAN_CREDENTIALS_FILE; HOME="$WORK/convert-home" "$FOREMAN" convert 2>&1)"; ST=$?
  assert_eq "$ST" 0 "convert succeeds"
  assert_contains "$OUT" "renamed  batch/ralph.conf → foreman.conf" "it names the conf it renamed"
  assert_contains "$OUT" "Review with \`git diff\`" "and leaves the commit to you"

  assert_contains "$(git -C "$repo" status --porcelain)" "RM batch/ralph.conf -> batch/foreman.conf" \
    "the conf is a staged git mv, its rewrite left unstaged"
  assert_eq "$(cat "$repo/batch/foreman.conf")" \
    "$(printf '# Sourced by the foreman toolkit. Try `foreman doctor`.\nFOREMAN_EXEC=fake\n#FOREMAN_SANDBOX=foreman-<repo-name>')" \
    "and its settings and prose are foreman's"
  [ -f "$repo/batch/foreman-runs.jsonl" ] && [ ! -e "$repo/batch/ralph-runs.jsonl" ] && pass || fail "the run log is renamed"
  [ ! -e "$repo/batch/.ralph-iter.bundle" ] && pass || fail "the old iteration bundle is gone"
  assert_contains "$(cat "$repo/.gitignore")" "**/foreman-runs.jsonl" ".gitignore names the new run log"
  assert_missing "$(cat "$repo/.gitignore")" "ralph" "and nothing of ralph's"

  assert_eq "$(cat "$repo/docs/guide.md")" \
    "$(printf 'Run `foreman run batch`, then read foreman-loop.sh.\r\nBuilt on the Ralph loop, after Ralph Wiggum.\r\nSee docs/ralph-notes.md.')" \
    "prose is converted, CRLF kept, the credit and the project's own file name left alone"
  [ -f "$repo/docs/ralph-notes.md" ] && pass || fail "the project's own file is not renamed"
  assert_contains "$OUT" "docs/ralph-notes.md" "it is listed for you to look at"

  assert_eq "$(cat "$WORK/convert-home/.config/foreman/env")" "FOREMAN_DOCKER_USERNAME=someone" \
    "the credentials file is copied under the new names"
  [ -f "$WORK/convert-home/.config/ralph/env" ] && pass || fail "and the old one is kept"

  run_foreman "$repo" status batch
  assert_missing "$OUT" "rename to Foreman" "the converted repo draws no legacy warning"

  git -C "$repo" commit --quiet -am "converted"
  OUT="$(cd "$repo" && HOME="$WORK/convert-home" "$FOREMAN" convert 2>&1)"; ST=$?
  assert_eq "$ST" 0 "a second convert succeeds"
  assert_contains "$OUT" "Nothing in the project to convert" "and finds nothing to do"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "and changes nothing"
fi

if case_is "convert --dry-run changes nothing, and a dirty tree or the toolkit itself is refused"; then
  repo="$(make_ralph_repo convert-dry-repo)"
  OUT="$(HOME="$WORK/convert-dry-home" "$FOREMAN" convert "$repo" --dry-run 2>&1)"; ST=$?
  assert_eq "$ST" 0 "a dry run succeeds, given the project as an argument"
  assert_contains "$OUT" "renamed  batch/ralph.conf → foreman.conf" "it says what it would rename"
  assert_contains "$OUT" "rewrote  docs/guide.md" "and rewrite"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "and changes nothing tracked"
  [ -f "$repo/batch/ralph-runs.jsonl" ] && pass || fail "nor the run files"

  printf 'x\n' >> "$repo/docs/guide.md"
  OUT="$(HOME="$WORK/convert-dry-home" "$FOREMAN" convert "$repo" 2>&1)"; ST=$?
  assert_eq "$ST" 1 "a dirty tree is refused"
  assert_contains "$OUT" "uncommitted changes" "and says why"
  [ -f "$repo/batch/ralph.conf" ] && pass || fail "with nothing converted"

  OUT="$(HOME="$WORK/convert-dry-home" "$FOREMAN" convert "$FOREMAN_HOME" --dry-run 2>&1)"; ST=$?
  assert_eq "$ST" 1 "the toolkit's own repo is refused"
  assert_contains "$OUT" "the foreman toolkit itself" "and says so"
fi

# --- the show (foreman-ui.sh, foreman-draw.cjs) -------------------------------------
# The show is the drawn rendering of a command; plain is today's text. `ui_show` decides which,
# per stream, and `ui_cols` asks how wide the terminal is. A real terminal is made with `script`,
# which not every machine has; the pipe cases need nothing.

# What ui_show says about one stream, in an environment of its own: "no", or "show:<tier>". $1 is
# tty or pipe, $2 the file descriptor, and the rest are VAR=value settings. A bare `bool` as the
# first setting asks for the status alone, with no variable to receive the tier.
SHOW_PROBE="$WORK/show-probe.sh"
printf '%s\n' '. "$1/lib/foreman-ui.sh"' \
  'if [ "${3:-}" = bool ]; then if ui_show "$2"; then printf show; else printf no; fi; exit; fi' \
  'if ui_show "$2" t; then printf "show:%s" "$t"; else printf no; fi' > "$SHOW_PROBE"
show_of() {
  local kind="$1" fd="$2" cmd out probe_arg=""; shift 2
  if [ "${1:-}" = bool ]; then probe_arg=bool; shift; fi
  printf -v cmd '%q ' env -u COLORTERM -u WT_SESSION -u NO_COLOR -u FOREMAN_COLOR -u TERM -u CI -u FOREMAN_SHOW \
    "$@" bash "$SHOW_PROBE" "$FOREMAN_HOME" "$fd" $probe_arg
  if [ "$kind" = tty ]; then
    [ "$fd" != 2 ] || cmd+='2>/dev/null'
    out="$(script -qec "$cmd" /dev/null </dev/null 2>/dev/null)"
    printf '%s' "${out//$'\r'/}"
  else
    eval "$cmd" 2>/dev/null
  fi
}

if case_is "ui_show: a stream that is not a terminal never gets the show unless FOREMAN_SHOW=always"; then
  assert_eq "$(show_of pipe 1 FOREMAN_COLOR=truecolor)" no "a pinned tier on a pipe is still not a terminal"
  assert_eq "$(show_of pipe 1 FOREMAN_COLOR=always COLORTERM=truecolor)" no "colour on a pipe is not the show"
  assert_eq "$(show_of pipe 1 FOREMAN_SHOW=sometimes FOREMAN_COLOR=truecolor)" no "an unknown FOREMAN_SHOW is auto"
  assert_eq "$(show_of pipe 1 FOREMAN_SHOW=auto)" no "auto on a pipe"
  assert_eq "$(show_of pipe 1 FOREMAN_SHOW=always)" show:16 "always forces it, and a tier of at least 16"
  assert_eq "$(show_of pipe 1 FOREMAN_SHOW=always TERM=xterm-256color)" show:256 "at the best tier the terminal says"
  assert_eq "$(show_of pipe 1 FOREMAN_SHOW=always COLORTERM=truecolor)" show:24 "24 bits"
  assert_eq "$(show_of pipe 1 FOREMAN_SHOW=always WT_SESSION=1c3e)" show:24 "and Windows Terminal"
  assert_eq "$(show_of pipe 1 FOREMAN_SHOW=always FOREMAN_COLOR=truecolor)" show:24 "a pinned tier is the show's tier"
  assert_eq "$(show_of pipe 1 FOREMAN_SHOW=always FOREMAN_COLOR=16 COLORTERM=truecolor)" show:16 "and a pinned 16 holds it down"
  assert_eq "$(show_of pipe 1 FOREMAN_SHOW=always FOREMAN_COLOR=256)" show:256 "256"
  assert_eq "$(show_of pipe 2 FOREMAN_SHOW=always)" show:16 "on stderr too"
  assert_eq "$(show_of pipe 1 FOREMAN_SHOW=always NO_COLOR=1 TERM=dumb)" show:16 "naming it wins over NO_COLOR and a dumb TERM"
  assert_eq "$(show_of pipe 1 FOREMAN_SHOW=always CI=true)" show:16 "and over CI"
  assert_eq "$(show_of pipe 1 FOREMAN_SHOW=always FOREMAN_COLOR=never COLORTERM=truecolor)" no "but never colouring is plain"
  assert_eq "$(show_of pipe 1 FOREMAN_SHOW=never FOREMAN_COLOR=truecolor)" no "never is plain"
  assert_eq "$(show_of pipe 1 bool FOREMAN_SHOW=always)" show "ui_show FD alone is a status"
  assert_eq "$(show_of pipe 1 bool)" no "and says no"
fi

if case_is "ui_show: a terminal with colour on gets the show, unless CI, NO_COLOR, a dumb TERM or FOREMAN_SHOW=never says no"; then
  if command -v script >/dev/null 2>&1 && [ "$(show_of tty 1 FOREMAN_SHOW=always)" = show:16 ]; then
    assert_eq "$(show_of tty 1 TERM=xterm)" show:16 "a plain terminal"
    assert_eq "$(show_of tty 1 bool TERM=xterm)" show "ui_show FD alone, on a terminal"
    assert_eq "$(show_of tty 1 TERM=xterm-256color)" show:256 "a 256-colour one"
    assert_eq "$(show_of tty 1 TERM=xterm COLORTERM=truecolor)" show:24 "a 24-bit one"
    assert_eq "$(show_of tty 1 TERM=xterm WT_SESSION=1c3e)" show:24 "Windows Terminal"
    assert_eq "$(show_of tty 1 TERM=xterm FOREMAN_COLOR=256)" show:256 "a pinned tier is used"
    assert_eq "$(show_of tty 1 TERM=xterm FOREMAN_SHOW=auto)" show:16 "auto named"
    assert_eq "$(show_of tty 1 TERM=xterm CI=true)" no "CI set"
    assert_eq "$(show_of tty 1 TERM=xterm CI=)" show:16 "CI set to nothing is not set"
    assert_eq "$(show_of tty 1 TERM=xterm NO_COLOR=1)" no "NO_COLOR"
    assert_eq "$(show_of tty 1 TERM=dumb)" no "a dumb terminal"
    assert_eq "$(show_of tty 1 TERM=xterm FOREMAN_COLOR=never)" no "colour never"
    assert_eq "$(show_of tty 1 TERM=xterm FOREMAN_SHOW=never)" no "the show never"
    assert_eq "$(show_of tty 1 TERM=xterm FOREMAN_SHOW=never FOREMAN_COLOR=truecolor)" no "never beats a pinned tier"
    assert_eq "$(show_of tty 1 TERM=xterm FOREMAN_SHOW=always CI=true)" show:16 "always beats CI"
    assert_eq "$(show_of tty 1 TERM=xterm FOREMAN_SHOW=always FOREMAN_COLOR=never)" no "and loses to colour never"
    assert_eq "$(show_of tty 2 TERM=xterm)" no "the stream asked about is stderr, a pipe here"
  else
    printf '  (skipped: no `script` to give a terminal)\n'
  fi
fi

# What ui_cols says. $1 is tty or pipe; the rest are settings, run after `stty rows 30 cols 101`
# on a terminal, so the terminal's own answer is known.
COLS_PROBE="$WORK/cols-probe.sh"
printf '%s\n' '. "$1/lib/foreman-ui.sh"' 'ui_cols w "$2"' 'printf "%s" "$w"' > "$COLS_PROBE"
cols_of() {
  local kind="$1" cmd out; shift
  printf -v cmd '%q ' env -u COLUMNS "$@" bash "$COLS_PROBE" "$FOREMAN_HOME" 1
  if [ "$kind" = tty ]; then
    out="$(script -qec "stty rows 30 cols 101; $cmd" /dev/null </dev/null 2>/dev/null)"
    out="${out//$'\r'/}"
    printf '%s' "${out##*$'\n'}"
  else
    eval "$cmd" 2>/dev/null
  fi
}

if case_is "ui_cols: COLUMNS, else the terminal's own width, else 80"; then
  assert_eq "$(cols_of pipe COLUMNS=120)" 120 "COLUMNS"
  assert_eq "$(cols_of pipe COLUMNS=64)" 64 "a narrow one"
  assert_eq "$(cols_of pipe)" 80 "nothing known is the classic 80"
  assert_eq "$(cols_of pipe COLUMNS=wide)" 80 "a COLUMNS that is not a number is not an answer"
  assert_eq "$(cols_of pipe COLUMNS=0)" 80 "nor is 0"
  assert_eq "$(cols_of pipe COLUMNS=-5)" 80 "nor a negative"
  if command -v script >/dev/null 2>&1 && [ "$(cols_of tty COLUMNS=120)" = 120 ]; then
    assert_eq "$(cols_of tty)" 101 "a terminal is asked"
    assert_eq "$(cols_of tty COLUMNS=130)" 130 "but COLUMNS wins, and is not asked"
  else
    printf '  (skipped: no `script` to give a terminal)\n'
  fi
fi

if case_is "foreman-draw reads the palette from foreman-ui.sh and keeps no copy"; then
  DRAW="$FOREMAN_HOME/lib/foreman-draw.cjs"
  assert_eq "$(node -e '
    const d = require(process.argv[1]); const p = d.loadPalette();
    console.log(Object.keys(p).join(" "));
    console.log(JSON.stringify([p.sun.hex, p.sun.rgb, p.sun.x256, p.sun.sgr16]));
    console.log(JSON.stringify([p.text.hex, p.text.x256, p.text.sgr16]));
    console.log(JSON.stringify([p.ink.hex, p.ink.x256, p.ink.sgr16]));
  ' "$DRAW")" 'sun amber rust post earth shade night ok error muted dim text ink
["#f6d58e",[246,213,142],222,33]
["#ece8e1",null,0]
["#171614",233,30]' "the table, as foreman-ui.sh has it"
  # Change one row in a copy, and the reader follows it: nothing is cached or written twice.
  sed 's/^sun   #f6d58e 222 33$/sun   #010203 17 36/' "$FOREMAN_HOME/lib/foreman-ui.sh" > "$WORK/ui-changed.sh"
  assert_eq "$(node -e 'const p = require(process.argv[1]).loadPalette(process.argv[2]); console.log(JSON.stringify([p.sun.hex, p.sun.rgb, p.sun.x256, p.sun.sgr16]))' "$DRAW" "$WORK/ui-changed.sh")" \
    '["#010203",[1,2,3],17,36]' "a changed row is read as changed"
  assert_eq "$(grep -ci 'f6d58e\|e0a84a\|c9772f' "$DRAW")" 0 "and no palette hex is written in the renderer"
  assert_eq "$(node -e 'try { require(process.argv[1]).loadPalette(process.argv[2]) } catch (e) { console.log("threw: " + e.message) }' "$DRAW" "$FOREMAN_HOME/README.md")" \
    "threw: no _UI_PALETTE in $FOREMAN_HOME/README.md" "a file without the table is an error that names it"
fi

if case_is "foreman-draw's encoder writes 24-bit, 256 and 16-colour SGR, half-blocks, and resets every line"; then
  DRAW="$FOREMAN_HOME/lib/foreman-draw.cjs"
  enc() {    # enc TIER ROWS_JSON — the encoded rows, with ESC shown as <E>
    node -e 'const d = require(process.argv[1]); process.stdout.write(d.encode(JSON.parse(process.argv[3]), +process.argv[2]))' \
      "$DRAW" "$1" "$2" | sed $'s/\033/<E>/g'
  }
  half='[[{"t":"▀▀","style":{"fg":"sun","bg":"rust"}}]]'
  assert_eq "$(enc 24 "$half")" '<E>[0;38;2;246;213;142;48;2;201;119;47m▀▀<E>[0m' "24 bits: a foreground and a background"
  assert_eq "$(enc 256 "$half")" '<E>[0;38;5;222;48;5;172m▀▀<E>[0m' "256: the palette's indexes"
  assert_eq "$(enc 16 "$half")" '<E>[0;33;41m▀▀<E>[0m' "16: yellow on red"
  assert_eq "$(enc 24 '[[{"t":"x","style":{"fg":"ok"}}]]')" '<E>[0;38;2;143;207;143mx<E>[0m' "a foreground alone"
  assert_eq "$(enc 24 '[[{"t":"x","style":{"bg":"ok"}}]]')" '<E>[0;48;2;143;207;143mx<E>[0m' "a background alone"
  assert_eq "$(enc 24 '[[{"t":"x","style":{"fg":"ok","bold":true}}]]')" '<E>[0;1;38;2;143;207;143mx<E>[0m' "bold"
  # Colours the art computes (a figure, a sky band) are hex, not names.
  assert_eq "$(enc 24 '[[{"t":"▀","style":{"fg":"#0a0908"}}]]')" '<E>[0;38;2;10;9;8m▀<E>[0m' "a hex colour, exact at 24"
  assert_eq "$(enc 256 '[[{"t":"▀","style":{"fg":"#0a0908"}}]]')" '<E>[0;38;5;232m▀<E>[0m' "its nearest shade at 256"
  assert_eq "$(enc 16 '[[{"t":"▀","style":{"fg":"#0a0908"}}]]')" '<E>[0;30m▀<E>[0m' "and black at 16, being nearest to ink"
  assert_eq "$(enc 16 '[[{"t":"▀","style":{"fg":"#f4d08c","bg":"#c8782e"}}]]')" '<E>[0;33;41m▀<E>[0m' "a hex shade folds to its nearest name at 16"
  # The terminal's own default stands in for text below 24 bits, and dim is not a background.
  assert_eq "$(enc 24 '[[{"t":"x","style":{"fg":"text"}}]]')" '<E>[0;38;2;236;232;225mx<E>[0m' "text is its hex at 24"
  assert_eq "$(enc 256 '[[{"t":"x","style":{"fg":"text"}}]]')" '<E>[0mx<E>[0m' "and the terminal's own at 256"
  assert_eq "$(enc 16 '[[{"t":"x","style":{"fg":"dim"}}]]')" '<E>[0;2mx<E>[0m' "dim is the attribute at 16"
  assert_eq "$(enc 16 '[[{"t":"▄","style":{"fg":"sun","bg":"dim"}}]]')" '<E>[0;33m▄<E>[0m' "and a dim background is none"
  # Lines: every one ends with a reset, an unstyled run drops the style before it, an empty row is a reset.
  assert_eq "$(enc 24 '[[{"t":"a","style":{"fg":"sun"}},{"t":"b"}],[],[{"t":"c"}]]')" \
    '<E>[0;38;2;246;213;142ma<E>[0mb<E>[0m
<E>[0m
c<E>[0m' "a reset at the end of every line, and before an unstyled run"
  assert_eq "$(enc 24 '[[{"t":"a","style":{"fg":"sun"}}]]' | wc -l | tr -d ' ')" 1 "one line per row"
fi

if case_is "foreman-draw parses the facts a shell pipes in"; then
  DRAW="$FOREMAN_HOME/lib/foreman-draw.cjs"
  facts() { node -e 'process.stdout.write(JSON.stringify(require(process.argv[1]).parseFacts(process.argv[2])))' "$DRAW" "$1"; }
  assert_eq "$(facts $'batch\tterminal-design\ndone\t2')" '{"batch":"terminal-design","done":"2"}' "key<TAB>value lines"
  assert_eq "$(facts $'item\ta\nitem\tb\nitem\tc')" '{"item":["a","b","c"]}' "a repeated key is a list"
  assert_eq "$(facts $'a\tx\ty\n')" '{"a":"x\ty"}' "the value is everything after the first tab"
  assert_eq "$(facts $'a\tx\r\n\r\nb\t\nc')" '{"a":"x","b":"","c":""}' "CRLF, blank lines, an empty value and a key alone"
  assert_eq "$(facts '')" '{}' "nothing is no facts"
  assert_eq "$(facts $'constructor\tx\n__proto__\ty')" '{"constructor":"x","__proto__":"y"}' "a key may be named like an Object method"
fi

if case_is "foreman-draw help draws the D1 sunrise at the tier it is given, and refuses a narrow screen"; then
  DRAW="$FOREMAN_HOME/lib/foreman-draw.cjs"
  ESC=$'\033'
  OUT24="$(node "$DRAW" help --tier 24 --cols 120 </dev/null)"; ST=$?
  assert_eq "$ST" 0 "the scene runs"
  assert_eq "$(printf '%s\n' "$OUT24" | wc -l | tr -d ' ')" 19 "eighteen rows and a blank line"
  assert_contains "$OUT24" "${ESC}[0;38;2;" "24 bits"
  assert_contains "$OUT24" ";48;2;" "half blocks carry a background"
  assert_contains "$OUT24" "38;2;224;168;74" "the sun's amber, exactly"
  assert_contains "$OUT24" "▀" "block characters"
  assert_eq "$(printf '%s\n' "$OUT24" | grep -vc "${ESC}\[0m\$")" 0 "every line ends with a reset"
  stripped="$(printf '%s\n' "$OUT24" | sed "s/${ESC}\[[0-9;]*m//g")"
  assert_eq "$(printf '%s\n' "$stripped" | head -n 1)" "                      ▄▄▄▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▄▄▄" "the top of the dome, as designed"
  assert_eq "$(printf '%s\n' "$stripped" | sed -n 18p)" "█████████████████████████▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀████████████████████████" "and the ground, as designed"
  assert_eq "$(printf '%s\n' "$stripped" | sed -n 19p)" "" "then a blank line"

  OUT256="$(node "$DRAW" help --tier 256 --cols 120 </dev/null)"
  assert_contains "$OUT256" "${ESC}[0;38;5;" "256 colours"
  assert_missing "$OUT256" "38;2;" "and not 24 bits"
  OUT16="$(node "$DRAW" help --tier 16 --cols 120 </dev/null)"
  assert_missing "$OUT16" "38;2;" "16 colours: no 24 bits"
  assert_missing "$OUT16" "38;5;" "no 256"
  assert_missing "$OUT16" "48;5;" "no 256 background"
  assert_missing "$OUT16" "48;2;" "no 24-bit background"
  assert_contains "$OUT16" "${ESC}[0;33" "yellow for the sun"
  assert_contains "$OUT16" "${ESC}[0;31;43m" "the rust rim over the yellow"
  assert_contains "$OUT16" "${ESC}[0;30;43m" "and the figure, black, in front of it"
  assert_eq "$(printf '%s\n' "$OUT16" | wc -l | tr -d ' ')" 19 "the same eighteen rows and blank line"
  # The ground and the dome's rim are the dark shades, which 16 colours leave to the terminal.
  assert_missing "$(printf '%s\n' "$OUT16" | sed -n 18p)" "█" "no ground at 16"
  assert_eq "$(printf '%s\n' "$OUT256" | sed "s/${ESC}\[[0-9;]*m//g")" "$stripped" "256 colours draw the same shapes as 24 bits"

  assert_eq "$(printf 'batch\tx\n' | node "$DRAW" help --tier 24 --cols 120)" "$OUT24" "facts on stdin are read, and help has no use for them"
  assert_eq "$(node "$DRAW" help --tier 24 --cols 64 </dev/null)" "$OUT24" "64 columns is wide enough"
  OUT="$(node "$DRAW" help --tier 24 --cols 63 </dev/null 2>"$WORK/draw-err")"; ST=$?
  assert_eq "$ST" 3 "one column short is refused, with its own status"
  assert_eq "$OUT" "" "and draws nothing"
  assert_contains "$(cat "$WORK/draw-err")" "too narrow" "and says so"
  OUT="$(node "$DRAW" nosuch --tier 24 --cols 120 </dev/null 2>&1)"; ST=$?
  assert_eq "$ST" 2 "an unknown scene is a usage error"
  assert_contains "$OUT" "unknown scene 'nosuch'" "and names it"
  OUT="$(node "$DRAW" constructor --tier 24 --cols 120 </dev/null 2>&1)"; ST=$?
  assert_eq "$ST" 2 "a scene is looked up among the scenes, not the Object methods"
  assert_eq "$(node -e 'try { require(process.argv[1]).draw("toString", {}, { tier: 24, cols: 99 }) } catch (e) { console.log(e.message) }' "$DRAW")" \
    "unknown scene 'toString'" "and so is the module's draw"
  OUT="$(node "$DRAW" help --cols 120 </dev/null 2>&1)"; ST=$?
  assert_eq "$ST" 2 "no tier is a usage error"
  OUT="$(node "$DRAW" help --tier none --cols 120 </dev/null 2>&1)"; ST=$?
  assert_eq "$ST" 2 "none is not a tier to draw at"
  OUT="$(node "$DRAW" help --tier 24 </dev/null 2>&1)"; ST=$?
  assert_eq "$ST" 2 "no width is a usage error"
  OUT="$(node "$DRAW" help --tier 24 --cols wide </dev/null 2>&1)"; ST=$?
  assert_eq "$ST" 2 "and so is one that is not a number"

  # The module does the same as the script.
  assert_eq "$(node -e 'process.stdout.write(require(process.argv[1]).draw("help", {}, { tier: 24, cols: 120 }))' "$DRAW")" \
    "$OUT24" "draw(scene, facts, opts) is the script's output"
  assert_eq "$(node -e 'process.stdout.write(String(require(process.argv[1]).draw("help", {}, { tier: 24, cols: 10 })))' "$DRAW")" \
    "" "and is empty below the scene's minimum"
  # The shell decides plain or show before it starts node, so it needs the minimum: it must agree.
  assert_eq "$(node -e 'console.log(require(process.argv[1]).SCENES.help.min)' "$DRAW")" \
    "$(sed -n 's/^_help_min_cols=\([0-9]*\).*/\1/p' "$FOREMAN_HOME/bin/foreman")" "the renderer's minimum for help is the dispatcher's"
  assert_eq "$(node -e 'console.log(require(process.argv[1]).SCENES.intro.min)' "$DRAW")" \
    "$(sed -n 's/^_intro_min_cols=\([0-9]*\).*/\1/p' "$FOREMAN_HOME/bin/foreman")" "and the renderer's minimum for the intro is the dispatcher's"
fi

# `foreman help`: the plain text is today's, and the show is the sunrise above it.
help_text() {    # the help text as the dispatcher's own header comment has it
  awk 'NR==1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$FOREMAN" | sed "s|\$FOREMAN_HOME|$FOREMAN_HOME|g"
}

if case_is "foreman help is the header comment on a pipe, and the sunrise above it when the show is forced"; then
  ESC=$'\033'
  want="$(help_text)"
  assert_contains "$want" "foreman init    <batch>" "(the help text read from the header)"
  OUT="$("$FOREMAN" help 2>&1)"; ST=$?
  assert_eq "$ST" 0 "help exits 0"
  assert_eq "$OUT" "$want" "captured, help is today's text"
  assert_missing "$OUT" "$ESC" "with no escape code"
  OUT="$("$FOREMAN" 2>&1)"; ST=$?
  assert_eq "$ST" 0 "bare foreman exits as it did"
  assert_eq "$OUT" "$want" "and prints the same"
  OUT="$("$FOREMAN" --help 2>&1)"; assert_eq "$OUT" "$want" "--help"
  OUT="$("$FOREMAN" -h 2>&1)"; assert_eq "$OUT" "$want" "-h"

  OUT="$(FOREMAN_SHOW=always FOREMAN_COLOR=truecolor COLUMNS=120 "$FOREMAN" help 2>&1)"; ST=$?
  assert_eq "$ST" 0 "the forced show exits 0"
  assert_contains "$OUT" "38;2;" "it is drawn in 24 bits"
  assert_contains "$OUT" "38;2;224;168;74" "in the palette's amber"
  stripped="$(printf '%s\n' "$OUT" | sed "s/${ESC}\[[0-9;]*m//g")"
  assert_contains "$stripped" "▄▄▄▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▄▄▄" "the sunrise"
  assert_eq "${stripped: -${#want}}" "$want" "above the help text, which ends it unchanged"
  assert_eq "$(printf '%s\n' "$stripped" | wc -l | tr -d ' ')" "$(( $(printf '%s\n' "$want" | wc -l) + 19 ))" "and nothing else is added: eighteen rows and a blank line"
  show24="$OUT"

  OUT="$(FOREMAN_SHOW=always FOREMAN_COLOR=16 COLUMNS=120 "$FOREMAN" help 2>&1)"
  assert_contains "$(printf '%s\n' "$OUT" | sed "s/${ESC}\[[0-9;]*m//g")" "▄▄██████▀▀▀▀███████████▄▄" "at 16 colours it is still drawn"
  assert_missing "$OUT" "38;2;" "but not in 24 bits"
  assert_missing "$OUT" "38;5;" "nor 256"
  assert_contains "$OUT" "${ESC}[0;33" "it is yellow"
  assert_contains "$OUT" "foreman init    <batch>" "and the help follows"
  OUT="$(FOREMAN_SHOW=always FOREMAN_COLOR=256 COLUMNS=120 "$FOREMAN" help 2>&1)"
  assert_contains "$OUT" "38;5;" "256"
  assert_missing "$OUT" "38;2;" "not 24"

  OUT="$(FOREMAN_SHOW=always FOREMAN_COLOR=truecolor COLUMNS=40 "$FOREMAN" help 2>&1)"
  assert_eq "$OUT" "$want" "a narrow screen gets today's text"
  OUT="$(FOREMAN_SHOW=always FOREMAN_COLOR=truecolor COLUMNS=63 "$FOREMAN" help 2>&1)"
  assert_eq "$OUT" "$want" "one column short of the sunrise"
  OUT="$(FOREMAN_SHOW=always FOREMAN_COLOR=truecolor COLUMNS=64 "$FOREMAN" help 2>&1)"
  assert_contains "$OUT" "38;2;" "and exactly enough"
  OUT="$(FOREMAN_SHOW=never FOREMAN_COLOR=truecolor COLUMNS=120 "$FOREMAN" help 2>&1)"
  assert_eq "$OUT" "$want" "FOREMAN_SHOW=never"
  OUT="$(FOREMAN_SHOW=always FOREMAN_COLOR=never COLUMNS=120 "$FOREMAN" help 2>&1)"
  assert_eq "$OUT" "$want" "FOREMAN_COLOR=never"
  OUT="$(FOREMAN_COLOR=truecolor COLUMNS=120 "$FOREMAN" help 2>&1)"
  assert_eq "$OUT" "$want" "colour alone is not the show: this is a pipe"

  OUT="$(FOREMAN_SHOW=always FOREMAN_COLOR=truecolor COLUMNS=120 "$FOREMAN" 2>&1)"; ST=$?
  assert_eq "$ST" 0 "bare foreman, forced"
  assert_eq "$OUT" "$show24" "draws what help draws"

  # The error path is not a help request: it keeps its text, on stderr, and its exit code.
  OUT="$(FOREMAN_SHOW=always FOREMAN_COLOR=truecolor COLUMNS=120 "$FOREMAN" bogus 2>&1 >/dev/null)"; ST=$?
  assert_eq "$ST" 1 "an unknown command still exits 1"
  assert_missing "$OUT" "$ESC" "and draws nothing"
  assert_contains "$OUT" "foreman: unknown command 'bogus'" "it says what was wrong"
  assert_contains "$OUT" "foreman init    <batch>" "and prints the usage"
  OUT="$("$FOREMAN" '' 2>&1)"; ST=$?
  assert_eq "$ST" 0 "an empty command is help, as it always was"
  assert_eq "$OUT" "$want" "and prints the same"

  if command -v script >/dev/null 2>&1 && [ "$(show_of tty 1 FOREMAN_SHOW=always)" = show:16 ]; then
    OUT="$(env -u CI -u NO_COLOR -u WT_SESSION -u FOREMAN_COLOR -u FOREMAN_SHOW FOREMAN_INTRO=0 TERM=xterm COLORTERM=truecolor COLUMNS=100 \
      script -qec "$FOREMAN help" /dev/null </dev/null 2>/dev/null)"
    assert_contains "$OUT" "38;2;" "on a real terminal that says 24 bits, help is drawn"
    OUT="$(env -u NO_COLOR -u WT_SESSION -u FOREMAN_COLOR -u FOREMAN_SHOW CI=true TERM=xterm COLORTERM=truecolor COLUMNS=100 \
      script -qec "$FOREMAN help" /dev/null </dev/null 2>/dev/null)"
    assert_missing "$OUT" "38;2;" "but not in CI"
    assert_contains "$OUT" "foreman init    <batch>" "which still has the help"
  else
    printf '  (skipped: no `script` to give a terminal)\n'
  fi
fi

# The intro: Intro3, 36 frames over 2.5s, played in place on a terminal and left on its last frame.
if case_is "foreman-draw intro draws a frame at a time, and holds the design's key rows"; then
  DRAW="$FOREMAN_HOME/lib/foreman-draw.cjs"
  ESC=$'\033'
  strip() { sed "s/${ESC}\[[0-9;]*[mK]//g"; }
  F0="$(node "$DRAW" intro --tier 24 --cols 120 --frame 0 </dev/null)"; ST=$?
  assert_eq "$ST" 0 "--frame 0 draws and exits"
  assert_eq "$(printf '%s\n' "$F0" | wc -l | tr -d ' ')" 19 "eighteen rows and a blank line, as the help is"
  assert_eq "$(printf '%s\n' "$F0" | strip | sed -n 3p)" "                            ▄▄▄▄" "frame 0: the top of the hat"
  assert_eq "$(printf '%s\n' "$F0" | strip | sed -n 13p)" "                  ▄▄▀▀▀███████▀▀███▀██████▀▀▀▄▄" "frame 0: the dome just rising behind him"
  assert_eq "$(printf '%s\n' "$F0" | strip | sed -n 16p)" "██████████████████████████████████████████████████████████████████" "frame 0: sixty-six columns of ground"
  assert_contains "$F0" "38;2;" "in 24 bits"
  assert_eq "$(printf '%s\n' "$F0" | grep -vc "${ESC}\[0m\$")" 0 "every line ends with a reset"
  assert_missing "$F0" "${ESC}[K" "a single frame has nothing to erase"

  F35="$(node "$DRAW" intro --tier 24 --cols 120 --frame 35 </dev/null)"; ST=$?
  assert_eq "$ST" 0 "--frame 35, the last"
  S35="$(printf '%s\n' "$F35" | strip)"
  assert_eq "$(printf '%s\n' "$S35" | sed -n 1p)" "                      ▄▄▄▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▄▄▄" "frame 35: the top of the sun, as in the help"
  assert_eq "$(printf '%s\n' "$S35" | sed -n 18p)" "█████████████████████████▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀██████████████████████████" "frame 35: the ground, two columns wider than the help's"
  assert_eq "$(printf '%s\n' "$S35" | sed -n 19p)" "" "then a blank line, where the help text starts"
  assert_eq "$(node "$DRAW" intro --tier 24 --cols 120 </dev/null)" "$F35" "no --frame is the last frame, where the intro rests"
  # The rest of the sun is the help's: the rows above the ground differ only by the figure's
  # extra width on the sides, none of which shows on the first rows.
  HELP="$(node "$DRAW" help --tier 24 --cols 120 </dev/null | strip)"
  assert_eq "$(printf '%s\n' "$S35" | sed -n 1,15p)" "$(printf '%s\n' "$HELP" | sed -n 1,15p)" "the last frame is the help's sunrise, row for row down to the ground"
  assert_eq "$(printf '%s\n' "$S35" | node -e 'for (const l of require("fs").readFileSync(0, "utf8").split("\n").slice(15, 18)) process.stdout.write(Array.from(l).length + " ")')" "66 66 66 " "and the ground is the design's width"

  # The frames between: the stake driven in, the sounds, the turn.
  stripped_of() { node "$DRAW" intro --tier 24 --cols 120 --frame "$1" </dev/null | strip; }
  assert_contains "$(stripped_of 20)" "tink" "frame 20 is the first tink"
  assert_contains "$(stripped_of 25)" "TONK" "frame 25 is TONK"
  assert_missing "$(stripped_of 24)" "TONK" "and the winding back before it is not"
  assert_missing "$F0" "tink" "(frame 0 has no sound)"
  assert_contains "$(node "$DRAW" intro --tier 24 --cols 120 --frame 25 </dev/null)" "38;2;255;248;232" "the sparks are the design's white"
  # The design ends on two takes of the same pose: the hold the help starts under.
  assert_eq "$(node -e 'const d = require(process.argv[1]); const f = d.drawFrames("intro", {}, { tier: 24, cols: 120 }); console.log(f.length, new Set(f).size, f[34] === f[35])' "$DRAW")" "36 35 true" "thirty-six frames, no two alike but the last two"

  # Colour tiers, as in every scene.
  assert_contains "$(node "$DRAW" intro --tier 256 --cols 120 --frame 12 </dev/null)" "38;5;" "256 colours"
  OUT16="$(node "$DRAW" intro --tier 16 --cols 120 --frame 25 </dev/null)"
  assert_missing "$OUT16" "38;2;" "16 colours: no 24 bits"
  assert_missing "$OUT16" "38;5;" "no 256"
  assert_contains "$(printf '%s\n' "$OUT16" | strip)" "TONK" "the sound is still there"

  # Errors.
  for bad in 36 -1 x 1.5 ""; do
    OUT="$(node "$DRAW" intro --tier 24 --cols 120 --frame "$bad" </dev/null 2>&1)"; ST=$?
    assert_eq "$ST" 2 "--frame '$bad' is a usage error"
  done
  assert_contains "$OUT" "--frame" "which says what was wrong"
  OUT="$(node "$DRAW" intro --tier 24 --cols 120 --frame 36 </dev/null 2>&1)"
  assert_contains "$OUT" "0 to 35" "and what frames there are"
  OUT="$(node "$DRAW" help --tier 24 --cols 120 --frame 1 </dev/null 2>&1)"; ST=$?
  assert_eq "$ST" 2 "the help has one frame, 0"
  assert_eq "$(node "$DRAW" help --tier 24 --cols 120 --frame 0 </dev/null)" "$(node "$DRAW" help --tier 24 --cols 120 </dev/null)" "and it is the sunrise"
  OUT="$(node "$DRAW" intro --tier 24 --cols 65 --frame 0 </dev/null 2>&1)"; ST=$?
  assert_eq "$ST" 3 "one column short of the intro's sixty-six"
  assert_contains "$OUT" "too narrow" "and says so"
  OUT="$(node "$DRAW" intro --tier 24 --cols 66 --frame 0 </dev/null 2>&1)"; ST=$?
  assert_eq "$ST" 0 "and exactly enough"
  OUT="$(node "$DRAW" intro --tier 24 --cols 120 --play --frame 3 </dev/null 2>&1)"; ST=$?
  assert_eq "$ST" 2 "--play and --frame together are a usage error"

  # The module's frames: one string each, rows cleared to the end of the line for playing over
  # the last, but never at the terminal's last column, where a clear would eat a cell.
  assert_eq "$(node -e 'const d = require(process.argv[1]); console.log(d.SCENES.intro.frames, d.SCENES.intro.min, d.SCENES.help.frames)' "$DRAW")" "36 66 1" "SCENES say how many frames and how wide"
  assert_eq "$(node -e 'const d = require(process.argv[1]); console.log(d.drawFrames("intro", {}, { tier: 24, cols: 120 }).length)' "$DRAW")" 36 "drawFrames gives all of them"
  assert_eq "$(node -e 'const d = require(process.argv[1]); process.stdout.write(d.drawFrames("intro", {}, { tier: 24, cols: 120 })[0])' "$DRAW" | grep -c "${ESC}\[K")" 19 "each row of a frame to play ends by clearing the rest of the line"
  assert_eq "$(node -e 'const d = require(process.argv[1]); process.stdout.write(d.drawFrames("intro", {}, { tier: 24, cols: 66 })[0])' "$DRAW" | grep -c "${ESC}\[K")" 16 "except the three ground rows, as wide as a sixty-six column terminal"
  assert_eq "$(node -e 'const d = require(process.argv[1]); console.log(d.drawFrames("intro", {}, { tier: 24, cols: 65 }).length)' "$DRAW")" 0 "and none below the minimum"
fi

if case_is "foreman-draw's player hides the cursor, plays in place, skips on a key and puts everything back"; then
  DRAW="$FOREMAN_HOME/lib/foreman-draw.cjs"
  PLAY_JS="$WORK/play-test.cjs"
  cat > "$PLAY_JS" <<'JS'
const { EventEmitter } = require('events');
const { play } = require(process.argv[2]);
const E = '\x1b';
const HIDE = E + '[?25l', SHOW = E + '[?25h';
const frames = ['a1\na2\n', 'b1\nb2\n', 'c1\nc2\n', 'd1\nd2\n'];
const fakeOut = () => ({ chunks: [], write(s) { this.chunks.push(s); return true; }, get text() { return this.chunks.join(''); } });
const fakeIn = () => Object.assign(new EventEmitter(), {
  raw: [], resumed: 0, paused: 0,
  setRawMode(on) { this.raw.push(on); return this; },
  resume() { this.resumed++; return this; },
  pause() { this.paused++; return this; },
});
const show = (s) => JSON.stringify(s.split(E).join('<E>'));
// Runs fn just after the chunk that contains `text` is written, so a key arrives between frames
// rather than at a time the machine may be too busy to keep.
const after = (out, text, fn) => {
  const real = out.write.bind(out);
  out.write = (s) => { const r = real(s); if (s.includes(text)) setImmediate(fn); return r; };
};
async function main() {
  // A run to the end.
  let out = fakeOut(), input = fakeIn(), signals = new EventEmitter();
  const t0 = Date.now();
  let how = await play(frames, { out, input, stepMs: 30, signals });
  const took = Date.now() - t0;
  console.log('end', how, show(out.text));
  console.log('timer', took >= 80 && took < 1000);
  console.log('raw', JSON.stringify(input.raw), input.paused > 0, input.listenerCount('data'), signals.listenerCount('SIGINT'));
  console.log('writes', out.chunks.length === frames.length + 2);

  // A key on the second frame: the last frame at once.
  out = fakeOut(); input = fakeIn(); signals = new EventEmitter();
  after(out, 'b1', () => input.emit('data', Buffer.from('x')));
  how = await play(frames, { out, input, stepMs: 200, signals });
  console.log('key', how, show(out.text));
  console.log('key raw', JSON.stringify(input.raw), input.listenerCount('data'));

  // An escape sequence (an arrow key) is one key, not three.
  out = fakeOut(); input = fakeIn(); signals = new EventEmitter();
  after(out, 'a1', () => input.emit('data', Buffer.from('\x1b[A')));
  how = await play(frames, { out, input, stepMs: 200, signals });
  console.log('arrow', how, out.text.endsWith(E + '[2A' + 'd1\nd2\n' + SHOW));

  // Ctrl-C arrives as a byte in raw mode: stop, no last frame, everything put back.
  out = fakeOut(); input = fakeIn(); signals = new EventEmitter();
  after(out, 'b1', () => input.emit('data', Buffer.from('\x03')));
  how = await play(frames, { out, input, stepMs: 200, signals });
  console.log('ctrl-c', how, show(out.text));
  console.log('ctrl-c raw', JSON.stringify(input.raw), input.listenerCount('data'));

  // And as a signal, when raw mode did not take.
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    out = fakeOut(); input = fakeIn(); signals = new EventEmitter();
    after(out, 'a1', () => signals.emit(sig));
    how = await play(frames, { out, input, stepMs: 200, signals });
    console.log(sig, how, out.text.endsWith(SHOW), out.text.includes('d1'), signals.listenerCount(sig));
  }

  // A write that throws: the cursor is still shown, the terminal put back, and the error is the caller's.
  out = fakeOut(); input = fakeIn(); signals = new EventEmitter();
  let n = 0;
  const real = out.write.bind(out);
  // the third frame fails; hiding and showing the cursor do not
  out.write = (s) => { if (s === HIDE || s === SHOW || ++n < 3) return real(s); throw new Error('disk full'); };
  try { await play(frames, { out, input, stepMs: 5, signals }); console.log('error: no throw'); }
  catch (e) { console.log('error', e.message, out.text.endsWith(SHOW), JSON.stringify(input.raw), input.listenerCount('data')); }

  // No input: nothing to skip with, no raw mode asked for.
  out = fakeOut(); signals = new EventEmitter();
  how = await play(frames, { out, input: null, stepMs: 5, signals });
  console.log('no input', how, out.text.startsWith(HIDE), out.text.endsWith(SHOW));

  // One frame: drawn, cursor back.
  out = fakeOut(); input = fakeIn();
  how = await play(['only\n'], { out, input, stepMs: 5, signals: new EventEmitter() });
  console.log('one', how, show(out.text));

  // A key pressed before the first frame is drawn is still a skip; no frames is nothing to do.
  out = fakeOut(); input = fakeIn();
  how = await play([], { out, input, stepMs: 5, signals: new EventEmitter() });
  console.log('none', how, JSON.stringify(out.text), JSON.stringify(input.raw));
}
main().catch((e) => { console.log('crashed', e.stack); process.exit(1); });
JS
  OUT="$(node "$PLAY_JS" "$DRAW" 2>&1)"
  line() { printf '%s\n' "$OUT" | grep "^$1 " | head -n 1; }
  assert_eq "$(line end)" 'end done "<E>[?25la1\na2\n<E>[2Ab1\nb2\n<E>[2Ac1\nc2\n<E>[2Ad1\nd2\n<E>[?25h"' "plays in place: hide, the frames each over the last, show"
  assert_eq "$(line timer)" "timer true" "frames come at the step, not all at once"
  assert_eq "$(line raw)" "raw [true,false] true 0 0" "raw only while it plays, then restored, paused, and no listener left"
  assert_eq "$(line writes)" 'writes true' "one write per frame, so a frame is not drawn half"
  assert_eq "$(line key)" 'key skipped "<E>[?25la1\na2\n<E>[2Ab1\nb2\n<E>[2Ad1\nd2\n<E>[?25h"' "a key jumps to the last frame"
  assert_eq "$(line 'key raw')" 'key raw [true,false] 0' "and restores the terminal"
  assert_eq "$(line arrow)" 'arrow skipped true' "an arrow key is one key"
  assert_eq "$(line ctrl-c)" 'ctrl-c interrupted "<E>[?25la1\na2\n<E>[2Ab1\nb2\n<E>[?25h"' "Ctrl-C stops where it is, with the cursor back"
  assert_eq "$(line 'ctrl-c raw')" 'ctrl-c raw [true,false] 0' "and the terminal put back"
  for sig in SIGINT SIGTERM SIGHUP; do
    assert_eq "$(line $sig)" "$sig interrupted true false 0" "$sig stops it, shows the cursor, and leaves no listener"
  done
  assert_eq "$(line error)" 'error disk full true [true,false] 0' "an error shows the cursor and restores the terminal, and is raised"
  assert_eq "$(line 'no input')" 'no input done true true' "without input it plays and asks for no raw mode"
  assert_eq "$(line one)" 'one done "<E>[?25lonly\n<E>[?25h"' "a single frame is drawn between hide and show"
  assert_eq "$(line none)" 'none done "" []' "no frames is nothing: no cursor change"
  assert_eq "$(printf '%s\n' "$OUT" | grep -c '^crashed')" 0 "and the harness did not crash"
fi

if case_is "foreman-draw intro --play will not play unless stdin and stdout are terminals"; then
  DRAW="$FOREMAN_HOME/lib/foreman-draw.cjs"
  OUT="$(node "$DRAW" intro --tier 24 --cols 120 --play </dev/null 2>&1)"; ST=$?
  assert_eq "$ST" 4 "with a pipe for stdout: status 4, so the caller prints the plain sunrise"
  assert_eq "$OUT" "" "and nothing is drawn"
  if command -v script >/dev/null 2>&1 && [ "$(show_of tty 1 FOREMAN_SHOW=always)" = show:16 ]; then
    # script gives its command a terminal for both; stdin is taken away inside.
    OUT="$(script -qec "node $DRAW intro --tier 24 --cols 120 --play </dev/null; echo status=\$?" /dev/null </dev/null 2>/dev/null)"
    assert_contains "$OUT" "status=4" "stdin not a terminal, stdout a terminal: also 4"
    assert_missing "$OUT" "?25l" "and the cursor is left alone"
    # stdin a terminal, stdout a pipe.
    OUT="$(script -qec "node $DRAW intro --tier 24 --cols 120 --play | cat; echo status=\${PIPESTATUS[0]}" /dev/null </dev/null 2>/dev/null)"
    assert_contains "$OUT" "status=4" "stdin a terminal, stdout a pipe: also 4"
    assert_missing "$OUT" "?25l" "and the cursor is left alone"
    # A terminal too short for the picture and its blank line.
    OUT="$( (sleep 1) | script -qec "stty rows 12 2>/dev/null; node $DRAW intro --tier 24 --cols 120 --play; echo status=\$?" /dev/null 2>/dev/null)"
    assert_contains "$OUT" "status=4" "a terminal twelve rows high cannot hold it in place: 4"
  else
    printf '  (skipped: no `script` to give a terminal)\n'
  fi
fi

if case_is "foreman help plays the intro on a terminal, once, and then prints the help; any key skips it"; then
  ESC=$'\033'
  want="$(help_text)"
  if command -v script >/dev/null 2>&1 && [ "$(show_of tty 1 FOREMAN_SHOW=always)" = show:16 ]; then
    term_env=(env -u CI -u NO_COLOR -u WT_SESSION -u FOREMAN_COLOR -u FOREMAN_SHOW -u FOREMAN_INTRO TERM=xterm COLORTERM=truecolor COLUMNS=100)
    # The keys come from the test, not from the clock: it waits for the terminal's output to show
    # what it is waiting for (the cursor hidden, or shown again) and then sends the keys, so a
    # machine too busy to start node on time cannot make a key early or a run late. script sends an
    # end-of-file as soon as its input ends, and that arrives as a key, so the input stays open.
    intro_run() {    # intro_run WAIT_FOR KEYS COMMAND — runs COMMAND on a terminal; sets OUT
      local f="$WORK/intro-out" i
      : > "$f"
      ( for i in $(seq 200); do grep -qaF "$1" "$f" 2>/dev/null && break; sleep 0.1; done
        [ -z "$2" ] || printf "$2"
        sleep 0.2 ) | "${term_env[@]}" script -qec "$3" /dev/null > "$f" 2>/dev/null
      OUT="$(<"$f")"
      OUT="${OUT//$'\r'/}"
    }
    HIDE="${ESC}[?25l"; SHOWN="${ESC}[?25h"

    # No key: the whole thing plays.
    intro_run "$SHOWN" "" "$FOREMAN help"
    assert_eq "$(printf '%s' "$OUT" | grep -o "${ESC}\[19A" | wc -l | tr -d ' ')" 35 "thirty-five frames drawn over the first, each moving up its nineteen lines"
    assert_eq "$(printf '%s' "$OUT" | grep -o "${ESC}\[?25l" | wc -l | tr -d ' ')" 1 "the cursor is hidden once"
    assert_eq "$(printf '%s' "$OUT" | grep -o "${ESC}\[?25h" | wc -l | tr -d ' ')" 2 "and shown after it, by the player and by the dispatcher"
    stripped="$(printf '%s\n' "$OUT" | sed "s/${ESC}\[[0-9;?]*[A-Za-z]//g")"
    assert_eq "${stripped: -${#want}}" "$want" "the help text follows, unchanged"
    assert_contains "$stripped" "TONK" "the hammer came down on the way"
    last_up="${OUT##*"${ESC}[19A"}"
    assert_eq "$(printf '%s' "$last_up" | sed "s/${ESC}\[[0-9;?]*[A-Za-z]//g" | grep -c "▄▄▄▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▄▄▄")" 1 "after the last frame the sunrise is on screen once, not drawn again by the help"

    # A key as soon as it is playing: the last frame at once, and the help.
    intro_run "$HIDE" x "$FOREMAN help"
    ups="$(printf '%s' "$OUT" | grep -o "${ESC}\[19A" | wc -l | tr -d ' ')"
    assert_eq "$([ "$ups" -ge 1 ] && [ "$ups" -le 12 ] && echo yes || echo "no:$ups")" yes "a key stops the frames part way through"
    assert_eq "$(printf '%s' "$OUT" | grep -o "${ESC}\[?25h" | wc -l | tr -d ' ')" 2 "the cursor is shown again"
    stripped="$(printf '%s\n' "$OUT" | sed "s/${ESC}\[[0-9;?]*[A-Za-z]//g")"
    assert_eq "${stripped: -${#want}}" "$want" "the help follows the skip"
    assert_contains "$stripped" "█████████████████████████▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀██████████████████████████" "and the last frame was drawn"

    # Ctrl-C part way through: raw mode hands it over as a byte. It ends the command, with the
    # cursor back and the terminal out of raw mode, and no help.
    intro_run "$HIDE" '\003' "$FOREMAN help; echo status=\$?; stty -a"
    assert_contains "$OUT" "status=130" "Ctrl-C exits 130"
    flat=" ${OUT//$'\n'/ } "
    assert_contains "$flat" " icanon " "and the terminal is out of raw mode: lines are read whole"
    assert_contains "$flat" " echo " "and typed keys are shown again"
    assert_missing "$OUT" "foreman init    <batch>" "without going on to the help"
    assert_eq "$(printf '%s' "$OUT" | grep -o "${ESC}\[?25[hl]" | tr -d '\n')" "${ESC}[?25l${ESC}[?25h${ESC}[?25h" "the cursor was hidden once and shown again"

    # Off: FOREMAN_INTRO=0, CI, and a terminal too narrow for the intro but not for the sunrise. With
    # no key to wait for (script sends an end-of-file at once) a wrongly played intro would still
    # show its first frame and its cursor.
    for setting in FOREMAN_INTRO=0 CI=true; do
      OUT="$("${term_env[@]}" "$setting" FOREMAN_SHOW=always script -qec "$FOREMAN help" /dev/null </dev/null 2>/dev/null)"
      assert_missing "$OUT" "[19A" "$setting: no frames"
      assert_missing "$OUT" "?25l" "$setting: the cursor is not touched"
    done
    OUT="$("${term_env[@]}" FOREMAN_INTRO=0 script -qec "$FOREMAN help" /dev/null </dev/null 2>/dev/null)"
    assert_contains "$OUT" "38;2;" "FOREMAN_INTRO=0 still draws the sunrise"
    assert_contains "$OUT" "foreman init    <batch>" "and the help"
    OUT="$("${term_env[@]}" COLUMNS=65 script -qec "$FOREMAN help" /dev/null </dev/null 2>/dev/null)"
    assert_missing "$OUT" "[19A" "65 columns: too narrow to play"
    assert_contains "$OUT" "38;2;" "but wide enough for the static sunrise"
    OUT="$("${term_env[@]}" COLUMNS=60 script -qec "$FOREMAN help" /dev/null </dev/null 2>/dev/null)"
    assert_missing "$OUT" "38;2;" "60 columns: plain, as before"
    # Bare foreman plays too and exits 0 as help does.
    intro_run "$HIDE" x "$FOREMAN; echo status=\$?"
    assert_contains "$OUT" "status=0" "bare foreman exits 0"
    assert_contains "$OUT" "?25l" "and plays the intro"
  else
    printf '  (skipped: no `script` to give a terminal)\n'
  fi

  # Forced into a capture, stdout is a pipe: there is no terminal to play on, whatever stdin is.
  start_ms=$SECONDS
  OUT="$(FOREMAN_SHOW=always FOREMAN_COLOR=truecolor COLUMNS=120 "$FOREMAN" help </dev/null 2>&1)"; ST=$?
  assert_eq "$ST" 0 "a forced show with stdin from /dev/null exits 0"
  assert_missing "$OUT" "?25l" "with no intro"
  assert_missing "$OUT" "[19A" "and no frames"
  assert_contains "$OUT" "38;2;" "just the sunrise"
  assert_eq "$([ $((SECONDS - start_ms)) -lt 2 ] && echo fast)" fast "and it does not wait"
  OUT="$(FOREMAN_SHOW=always FOREMAN_COLOR=truecolor COLUMNS=120 FOREMAN_INTRO=1 "$FOREMAN" help 2>&1 <&-)"; ST=$?
  assert_eq "$ST" 0 "and with stdin closed"
  assert_missing "$OUT" "?25l" "no intro either"
fi

if case_is "FOREMAN_SHOW takes auto, always and never, and a batch's foreman.conf may set it"; then
  repo="$(make_repo 2 show-values-repo)"
  for v in auto always never; do
    FOREMAN_SHOW=$v run_foreman "$repo" status batch
    assert_eq "$ST" 0 "FOREMAN_SHOW=$v is accepted"
  done
  FOREMAN_SHOW=sometimes run_foreman "$repo" status batch
  assert_eq "$ST" 1 "an unknown value is refused"
  assert_contains "$OUT" "FOREMAN_SHOW must be auto, always or never (got 'sometimes')" "and the message says why"
  printf 'FOREMAN_SHOW=never\n' >> "$repo/batch/foreman.conf"
  git -C "$repo" commit --quiet -am "no show"
  run_foreman "$repo" status batch
  assert_eq "$ST" 0 "foreman.conf can set it"
fi

# ---------------------------------------------------------------------------
# A case process that ran the last case in the file ends here.
[ "$CASE_OPEN" = 1 ] && case_finish
exit 0
