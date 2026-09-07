#!/bin/bash
# End-to-end tests for the loop, driven by the `fake` exec adapter — no sandbox, no model,
# no money. Each case builds a throwaway repo with a batch of tickets in it, runs ralph
# against it, and asserts on the exit code, what landed, and what the run log says.
#
#   bash test/smoke.sh            run everything
#   bash test/smoke.sh dirty      run the cases whose name contains "dirty"
#
# The fixtures live under $TMPDIR and are removed on exit unless RALPH_KEEP_FIXTURES=1.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_HOME="$(cd "$TEST_DIR/.." && pwd)"
RALPH="$RALPH_HOME/bin/ralph"
FILTER="${1:-}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ralph-smoke-XXXXXX")"
cleanup() { [ "${RALPH_KEEP_FIXTURES:-0}" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

passed=0
failed=0
CASE=""

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
# A repo with one batch of $1 tickets, none of them done. Prints its path.
make_repo() {
  local count="${1:-2}" name="${2:-repo}" repo i
  repo="$WORK/$name"
  mkdir -p "$repo/batch/issues"
  git -C "$repo" init --quiet
  git -C "$repo" config core.autocrlf false
  git -C "$repo" config user.name ralph-test
  git -C "$repo" config user.email test@ralph.invalid

  for i in $(seq 1 "$count"); do
    cat > "$repo/batch/issues/0$i-ticket.md" <<TICKET
# Ticket $i

**Status:** todo

Do the $i-th thing.
TICKET
  done

  cp "$RALPH_HOME/lib/ralph.conf.template" "$repo/batch/ralph.conf"
  printf 'RALPH_EXEC=fake\n' >> "$repo/batch/ralph.conf"
  printf '%s\n' '**/ralph-runs.jsonl' '**/ralph-runs.log' '**/.ralph-iter.bundle' \
    > "$repo/.gitignore"
  printf 'ralph.conf text eol=lf\n' > "$repo/.gitattributes"

  git -C "$repo" add -A >/dev/null
  git -C "$repo" commit --quiet -m "tickets"
  printf '%s' "$repo"
}

# Run ralph in $1 with the rest as arguments. Captures stdout+stderr in $OUT, status in $ST.
run_ralph() {
  local repo="$1"; shift
  OUT="$(cd "$repo" && "$RALPH" "$@" 2>&1)"
  ST=$?
}

done_count() { grep -l '^\*\*Status:\*\* implemented' "$1"/batch/issues/*.md 2>/dev/null | grep -c . ; }

case_is() {
  CASE="$1"
  case "$CASE" in *"$FILTER"*) printf '\n%s\n' "$CASE"; return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

if case_is "status and dry-run spend nothing and need no runner"; then
  repo="$(make_repo 3 status-repo)"

  run_ralph "$repo" status batch
  assert_eq "$ST" 0 "status exits 0"
  assert_contains "$OUT" "Tickets done: 0 / 3" "status counts the tickets"
  assert_contains "$OUT" "batch/issues/01-ticket.md" "status names the next ticket"

  run_ralph "$repo" dry-run batch
  assert_eq "$ST" 0 "dry-run exits 0"
  assert_contains "$OUT" "Exec:    fake (no agent is run)" "dry-run describes the adapter"
  assert_contains "$OUT" "=== end prompt" "dry-run prints the prompt"
  assert_contains "$OUT" "Commit everything to the current branch" "the adapter supplies the commit note"
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "1" "dry-run committed nothing"
fi

if case_is "one iteration is the default, and it lands one ticket"; then
  repo="$(make_repo 3 default-repo)"
  run_ralph "$repo" run batch

  assert_eq "$ST" 10 "stops paused on the iteration budget"
  assert_contains "$OUT" "iteration budget reached (1)" "says why it paused"
  assert_eq "$(done_count "$repo")" "1" "exactly one ticket landed"
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "2" "exactly one new commit"
fi

if case_is "--unlimited runs the batch to completion"; then
  repo="$(make_repo 3 unlimited-repo)"
  run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 0 "exits 0 when every ticket is done"
  assert_contains "$OUT" "Every ticket in batch is done." "says the batch is finished"
  assert_eq "$(done_count "$repo")" "3" "all three landed"
  assert_contains "$OUT" "tickets landed:        3" "the footer counts them"
fi

if case_is "resuming picks up at the first ticket that has not landed"; then
  repo="$(make_repo 3 resume-repo)"
  run_ralph "$repo" run batch 2
  assert_eq "$(done_count "$repo")" "2" "two landed in the first run"

  run_ralph "$repo" run batch --unlimited
  assert_contains "$OUT" "batch/issues/03-ticket.md" "the second run starts at ticket 3"
  assert_eq "$(done_count "$repo")" "3" "the batch finishes"
fi

if case_is "a ticket that does not land stops the run for a human"; then
  repo="$(make_repo 2 noop-repo)"
  RALPH_FAKE_BEHAVIOUR=noop run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 20 "exits needs-a-human"
  assert_contains "$OUT" "is still not 'implemented'" "names the stuck ticket"
  assert_eq "$(done_count "$repo")" "0" "nothing landed"
fi

if case_is "a transient failure is retried within the run"; then
  repo="$(make_repo 2 retry-repo)"
  RALPH_FAKE_BEHAVIOUR=transient:land run_ralph "$repo" run batch --unlimited

  assert_contains "$OUT" "(attempt 2)" "the same ticket is attempted twice"
  assert_eq "$(done_count "$repo")" "2" "both tickets land in the end"
fi

if case_is "attempts are capped per ticket"; then
  repo="$(make_repo 2 attempts-repo)"
  RALPH_TICKET_ATTEMPTS=3 RALPH_FAKE_BEHAVIOUR=transient run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 20 "gives up rather than looping"
  assert_contains "$OUT" "after 3 attempt(s)" "stops at RALPH_TICKET_ATTEMPTS"
  assert_missing "$OUT" "(attempt 4)" "never makes a fourth attempt"
fi

if case_is "a crash with no signal at all is not retried"; then
  # The narrowing that pays for itself: an unparseable failure carrying neither a transient
  # nor a context signal is indistinguishable from a logic failure, and a blind second
  # attempt at one of those costs a whole iteration to learn nothing.
  repo="$(make_repo 2 crash-repo)"
  RALPH_FAKE_BEHAVIOUR=crash run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 20 "stops rather than retrying"
  assert_missing "$OUT" "(attempt 2)" "makes no second attempt"
  assert_eq "$(done_count "$repo")" "0" "nothing landed"
fi

if case_is "running out of context is retried even when no JSON came back"; then
  repo="$(make_repo 2 ctx-retry-repo)"
  log="$WORK/ctx-prompts.txt"
  RALPH_FAKE_PROMPT_LOG="$log" RALPH_FAKE_BEHAVIOUR=context:land \
    run_ralph "$repo" run batch --unlimited

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
  RALPH_TICKET_ATTEMPTS=2 RALPH_FAKE_BEHAVIOUR=context run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 20 "gives up after the attempts"
  assert_contains "$OUT" "too large for one iteration" "says what is actually wrong"
  assert_missing "$OUT" "is still not 'implemented'" "not the generic message"
fi

if case_is "a real context payload is not mistaken for a transient one"; then
  # The real payload carries "api_error_status", whose field NAME contains the transient
  # pattern 'api_error'. Classification order is the only thing keeping these apart.
  repo="$(make_repo 2 ctx-json-repo)"
  RALPH_TICKET_ATTEMPTS=1 RALPH_FAKE_BEHAVIOUR=context-json run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 20 "stops for a human"
  assert_contains "$OUT" "too large for one iteration" "diagnosed as a context failure"
  runlog="$(cat "$repo/batch/ralph-runs.log")"
  assert_contains "$runlog" "CONTEXT EXHAUSTED SIGNAL DETECTED" "recorded as context exhaustion"
  assert_missing "$runlog" "TRANSIENT ERROR SIGNAL DETECTED" "and not as a transient error"
fi

if case_is "a dirty tree stops the run and is never auto-committed"; then
  repo="$(make_repo 2 dirty-repo)"
  RALPH_FAKE_BEHAVIOUR=dirty run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 20 "exits needs-a-human"
  assert_contains "$OUT" "left uncommitted changes behind" "says what happened"
  assert_contains "$OUT" "Inspect with: git diff" "the adapter says where to look"
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "1" "committed nothing"
fi

if case_is "a usage limit pauses the run"; then
  repo="$(make_repo 3 limit-repo)"
  RALPH_FAKE_BEHAVIOUR=limit run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 10 "exits paused, not stopped"
  assert_contains "$OUT" "usage limit reached" "says why"
  assert_contains "$OUT" "Resume:" "tells you how to resume"
fi

if case_is "the cost budget stops the run before spending over it"; then
  repo="$(make_repo 5 cost-repo)"
  RALPH_FAKE_COST=0.50 RALPH_MAX_COST_USD=1 run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 10 "pauses on the cost budget"
  assert_contains "$OUT" "cost budget reached" "says why"
  assert_eq "$(done_count "$repo")" "2" "stops once the budget is reached, not after"
fi

if case_is "the run is recorded for ralph report"; then
  repo="$(make_repo 2 report-repo)"
  RALPH_FAKE_COST=0.25 run_ralph "$repo" run batch --unlimited

  assert_eq "$(grep -c . "$repo/batch/ralph-runs.jsonl")" "2" "one record per iteration"

  run_ralph "$repo" report batch
  assert_eq "$ST" 0 "report reads the log"
  assert_contains "$OUT" "iterations 2  ·  landed 2" "report agrees with the run"
  assert_contains "$OUT" '$0.5000' "report totals the cost"

  run_ralph "$repo" report batch --failures
  assert_contains "$OUT" "every recorded iteration landed" "nothing is flagged"
fi

if case_is "the prompt carries the ticket, the order file and the progress tail"; then
  repo="$(make_repo 2 prompt-repo)"
  log="$WORK/prompts.txt"
  RALPH_FAKE_PROMPT_LOG="$log" run_ralph "$repo" run batch 1

  prompts="$(cat "$log")"
  assert_contains "$prompts" "@batch/issues/01-ticket.md" "the ticket is attached"
  assert_contains "$prompts" "batch/progress.txt" "the progress file is named"
  assert_contains "$prompts" "nothing recorded yet" "the first prompt says so"
  assert_contains "$prompts" "'**Status:**' line to 'implemented'" "it says what to write when done"
fi

if case_is "an unknown exec mode is rejected before anything runs"; then
  repo="$(make_repo 1 badexec-repo)"
  RALPH_EXEC=nonesuch run_ralph "$repo" run batch

  assert_eq "$ST" 1 "refuses to start"
  assert_contains "$OUT" "RALPH_EXEC must be one of:" "lists the modes that exist"
  assert_contains "$OUT" "fake" "the list is generated from lib/exec/"
fi

if case_is "doctor asks the adapter what this repo needs"; then
  repo="$(make_repo 1 doctor-repo)"
  run_ralph "$repo" doctor

  assert_eq "$ST" 0 "a fake batch needs no runner on PATH"
  assert_contains "$OUT" "0 of 1 done" "the batch is listed with its progress"
  assert_missing "$OUT" "sbx is not on PATH" "does not ask for a sandbox it will not use"
fi

if case_is "init scaffolds a batch from its own ticket list"; then
  repo="$(make_repo 2 init-repo)"
  rm -f "$repo/batch/order.md"
  run_ralph "$repo" init batch --no-order

  assert_eq "$ST" 0 "init exits 0"
  order="$(cat "$repo/batch/order.md")"
  assert_contains "$order" "batch/issues/01-ticket.md" "the order block lists ticket 1"
  assert_contains "$order" "batch/issues/02-ticket.md" "the order block lists ticket 2"
  assert_contains "$OUT" "created  batch/progress.txt" "progress.txt is scaffolded"
fi

if case_is "init and --unordered honour RALPH_ISSUES_DIRS"; then
  # The bug this fixes: init used to scan a hard-coded `issues/`, so a batch whose conf
  # points elsewhere was scaffolded from an empty directory.
  repo="$WORK/issuesdir-repo"
  mkdir -p "$repo/batch/specs"
  git -C "$repo" init --quiet
  git -C "$repo" config core.autocrlf false
  printf '# Spec %s\n\n**Status:** todo\n' 1 > "$repo/batch/specs/01-spec.md"
  printf '# Spec %s\n\n**Status:** todo\n' 2 > "$repo/batch/specs/02-spec.md"
  printf '# not a ticket\n' > "$repo/batch/specs/README.md"
  printf 'RALPH_EXEC=fake\nRALPH_ISSUES_DIRS="specs"\n' > "$repo/batch/ralph.conf"

  run_ralph "$repo" next batch --unordered
  assert_eq "$ST" 0 "--unordered exits 0"
  assert_contains "$OUT" "batch/specs/01-spec.md" "it finds the specs directory"
  assert_missing "$OUT" "README.md" "it applies the exclusion list"

  run_ralph "$repo" init batch --no-order
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

  run_ralph "$repo" next batch --all
  assert_eq "$OUT" "batch/issues/03-ticket.md" "--all follows the order file"

  run_ralph "$repo" next batch --unordered
  assert_contains "$OUT" "batch/issues/01-ticket.md" "--unordered sees tickets the order file omits"
  assert_eq "$(printf '%s\n' "$OUT" | grep -c .)" "3" "and sees all of them"
fi

if case_is "a && in a check command survives into the prompt"; then
  # Bash's ${var//pat/repl} treats & in the replacement as "the text that matched" — a
  # RALPH_TEST_CMD containing && used to render as two copies of __VERIFY_BLOCK__'s own
  # marker text instead of the command. dry-run exits before exec_prepare, so no sandbox
  # is touched.
  repo="$(make_repo 1 ampersand-repo)"
  printf 'RALPH_TEST_CMD="node a.js && node b.js"\n' >> "$repo/batch/ralph.conf"
  git -C "$repo" commit --quiet -am "add test cmd"

  run_ralph "$repo" dry-run batch
  assert_eq "$ST" 0 "dry-run exits 0"
  assert_contains "$OUT" "node a.js && node b.js" "the command survives verbatim"
  assert_missing "$OUT" "__VERIFY_BLOCK__" "the marker is not left behind"
fi

if case_is "RALPH_ISSUES_DIRS='.' means the batch directory, not the repo root"; then
  # A relative RALPH_ISSUES_DIRS entry used to resolve against the repo root first, so "."
  # meant the repo's own top level rather than the batch directory.
  repo="$WORK/dot-issues-repo"
  mkdir -p "$repo/batch"
  git -C "$repo" init --quiet
  git -C "$repo" config core.autocrlf false
  printf '# decoy repo-root file\n' > "$repo/CLAUDE.md"
  printf '# Ticket 1\n\n**Status:** todo\n' > "$repo/batch/01-ticket.md"
  printf '# Ticket 2\n\n**Status:** todo\n' > "$repo/batch/02-ticket.md"
  printf 'RALPH_EXEC=fake\nRALPH_ISSUES_DIRS="."\n' > "$repo/batch/ralph.conf"

  run_ralph "$repo" next batch --unordered
  assert_eq "$ST" 0 "--unordered exits 0"
  assert_contains "$OUT" "01-ticket.md" "it lists the first ticket"
  assert_contains "$OUT" "02-ticket.md" "and the second"
  assert_missing "$OUT" "CLAUDE.md" "it does not pick up the repo-root decoy"
fi

if case_is "a batch whose tickets are not where RALPH_ISSUES_DIRS looks says where it looked"; then
  repo="$WORK/misplaced-tickets-repo"
  mkdir -p "$repo/batch"
  git -C "$repo" init --quiet
  git -C "$repo" config core.autocrlf false
  printf '# Ticket 1\n\n**Status:** todo\n' > "$repo/batch/01-ticket.md"
  printf 'RALPH_EXEC=fake\n' > "$repo/batch/ralph.conf"

  run_ralph "$repo" status batch
  assert_contains "$OUT" "batch/issues" "names the resolved (default) issues path"
  assert_contains "$OUT" "(missing)" "and says it does not exist"
  assert_contains "$OUT" 'RALPH_ISSUES_DIRS="."' "suggests the one-line fix"
fi

if case_is "--unordered is quiet about an empty batch, the other modes are not"; then
  repo="$WORK/empty-repo"
  mkdir -p "$repo/batch/issues"
  git -C "$repo" init --quiet
  printf 'RALPH_EXEC=fake\n' > "$repo/batch/ralph.conf"

  run_ralph "$repo" next batch --unordered
  assert_eq "$ST" 0 "--unordered exits 0 on an empty batch"
  assert_eq "$OUT" "" "and prints nothing"

  run_ralph "$repo" next batch --count
  assert_eq "$ST" 2 "--count still calls an empty batch malformed"
fi

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
