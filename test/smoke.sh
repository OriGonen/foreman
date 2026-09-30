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
    '**/.ralph-stall-marker' > "$repo/.gitignore"
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
  assert_contains "$OUT" "Next: 01-ticket.md" "status names the next ticket"
  assert_missing "$OUT" "[HUMAN]" "no human tickets, so no marking"
  assert_missing "$OUT" "human tickets remaining" "and no human-ticket count"
  assert_missing "$OUT" "warning:" "and no warnings — this batch has neither kind of ticket"

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
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "3" "the landing commit, plus the rename marking it done"
fi

if case_is "--unlimited runs the batch to completion"; then
  repo="$(make_repo 3 unlimited-repo)"
  run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 0 "exits 0 when every ticket is done"
  assert_contains "$OUT" "Every ticket in batch is done." "says the batch is finished"
  assert_eq "$(done_count "$repo")" "3" "all three landed"
  assert_contains "$OUT" "tickets landed:        3" "the footer counts them"
  assert_missing "$OUT" "overshot to salvage" "nothing stalled, so no such note"
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
  # `dirty` is the loop's exact stall signature (see the "stall is salvaged" case below), so
  # a bare stall is normally rescued by a checkpoint turn rather than stopping here. Forcing
  # the checkpoint to fail too is what still exercises this stop — and the failure path is
  # the one an untested stop let rot before (ticket 01's wrong recovery text).
  repo="$(make_repo 2 dirty-repo)"
  RALPH_FAKE_BEHAVIOUR=dirty RALPH_FAKE_CHECKPOINT_BEHAVIOUR=fail \
    run_ralph "$repo" run batch --unlimited

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
  RALPH_FAKE_PROMPT_LOG="$log" RALPH_FAKE_BEHAVIOUR=dirty:land \
    run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 0 "the batch still finishes"
  assert_contains "$OUT" "stalled" "the stall is named as such"
  assert_contains "$OUT" "salvaged by a checkpoint turn" "and so is the salvage"
  assert_eq "$(done_count "$repo")" "2" "both tickets land"
  assert_contains "$(git -C "$repo" log --format=%s)" "wip: batch/issues/01-ticket.md" \
    "the checkpoint's own commit is in the history"

  # The real checkpoint prompt is what the fake adapter saw — a sentinel phrase, not a side
  # channel — and it never consumed a slot of RALPH_FAKE_BEHAVIOUR's list.
  cp="$(awk '/^===== fake prompt checkpoint /{f=1;next} /^===== fake prompt /{f=0} f' "$log")"
  assert_contains "$cp" "CHECKPOINT TURN" "the checkpoint prompt is recognisable"
  assert_contains "$cp" "$base" "and diffs against the stalled turn's own base"
  assert_contains "$cp" "Remaining:" "and asks for the handoff note"
  assert_contains "$cp" "do not write, edit, or plan any more" "and not to continue the work"

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
  RALPH_FAKE_COST=0.02 RALPH_MAX_COST_USD=0.01 RALPH_FAKE_BEHAVIOUR=dirty \
    run_ralph "$repo" run batch --unlimited

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
  RALPH_FAKE_BEHAVIOUR=dirty RALPH_FAKE_CHECKPOINT_BEHAVIOUR=discard \
    run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 20 "stops for a human"
  assert_contains "$OUT" "is gone" "says plainly that the work is gone"
  assert_missing "$OUT" "left uncommitted changes behind, and the checkpoint" \
    "not conflated with the still-dirty failure, which has something to inspect"
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "1" "nothing new was committed"
fi

if case_is "the dirty-tree recovery note matches the mode actually in force"; then
  # Askable of a mode without running it, the same way ralph_exec_required_tool already is —
  # so this asserts each adapter's wording directly rather than only by triggering a real
  # stall under that mode (expensive or impossible for the two that need a real sandbox).
  note_for() {
    bash -c '
      source "$1/lib/ralph-exec.sh"
      RALPH_SANDBOX="ralph-note-test"
      RALPH_INVOKE="ralph"
      ralph_exec_dirty_recovery_note "$2" deadbeef batch/issues/01-ticket.md batch
    ' _ "$RALPH_HOME" "$1"
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
  assert_contains "$note" "sbx exec ralph-note-test git commit" "sandbox: commit inside the sandbox"
  assert_contains "$note" "sbx cp ralph-note-test:" "sandbox: and transport the commit back out"
  assert_contains "$note" "run batch" "sandbox: then rerun"
  assert_missing "$note" "git add -A && git commit -m 'wip:" "sandbox: never the host-commit line"
fi

if case_is "syncing refuses over a dirty tree rather than resetting it"; then
  repo="$(make_repo 2 refuse-sync-repo)"

  # A clean tree syncs exactly as before, with no extra output.
  run_ralph "$repo" run batch 1
  assert_eq "$ST" 10 "clean tree: the iteration runs and pauses on the iteration budget"
  assert_eq "$(done_count "$repo")" "1" "clean tree: the ticket landed"
  assert_missing "$OUT" "Refusing to sync" "clean tree: no refusal text"

  # Leave the second ticket's tree dirty, as a stall would — and force the checkpoint turn
  # that would normally salvage a stall to fail too, so the tree is still dirty for the
  # rerun below to find. (The salvage path itself is covered by "a stall is salvaged by a
  # checkpoint turn and the ticket continues".)
  RALPH_FAKE_BEHAVIOUR=dirty RALPH_FAKE_CHECKPOINT_BEHAVIOUR=fail \
    run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 20 "the unsalvaged stall stops for a human"
  head_after_stall="$(git -C "$repo" rev-parse HEAD)"
  commits_after_stall="$(git -C "$repo" log --oneline | wc -l)"

  # The unsalvaged stall above left a marker, which a rerun would (rightly) trust and act
  # on — that path has its own cases below. Deleting the marker by hand is always safe, and
  # is exactly how to reach the refusal this case is about: a dirty tree nobody can vouch for.
  rm -f "$repo/batch/.ralph-stall-marker"

  # Rerunning is the natural response to any stop. RALPH_ALLOW_DIRTY=1 only waives the
  # PREFLIGHT gate on the review base (a different concern); it must not waive this
  # refusal, which exists so that "just rerun it" can never destroy the tree.
  log="$WORK/refuse-sync-prompts.txt"
  RALPH_ALLOW_DIRTY=1 RALPH_FAKE_PROMPT_LOG="$log" RALPH_FAKE_BEHAVIOUR=land \
    run_ralph "$repo" run batch --unlimited
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
  RALPH_FAKE_BEHAVIOUR=dirty RALPH_FAKE_CHECKPOINT_BEHAVIOUR=fail \
    run_ralph "$repo" run batch >/dev/null 2>&1
  printf '%s' "$repo"
}

if case_is "a rerun salvages the stalled work its own previous run left behind"; then
  repo="$(make_repo 2 rerun-salvage-repo)"
  marker="$repo/batch/.ralph-stall-marker"
  base="$(git -C "$repo" rev-parse HEAD)"

  RALPH_FAKE_BEHAVIOUR=dirty RALPH_FAKE_CHECKPOINT_BEHAVIOUR=fail \
    run_ralph "$repo" run batch
  assert_eq "$ST" 20 "the unsalvaged stall stops for a human"
  [ -f "$marker" ] && pass || fail "the unsalvaged stall records a marker"
  assert_contains "$(cat "$marker" 2>/dev/null)" "batch/issues/01-ticket.md" "it names the ticket"
  assert_contains "$(cat "$marker" 2>/dev/null)" "$base" "and the base ref"
  assert_contains "$(cat "$marker" 2>/dev/null)" "ralph-rerun-salvage-repo" "and the sandbox"
  [ -n "$(git -C "$repo" status --porcelain)" ] && pass || fail "the work is still uncommitted"

  # No RALPH_ALLOW_DIRTY here: "just rerun it" has to be true as typed.
  log="$WORK/rerun-salvage-prompts.txt"
  RALPH_FAKE_PROMPT_LOG="$log" RALPH_FAKE_BEHAVIOUR=land \
    run_ralph "$repo" run batch --unlimited
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
  marker="$repo/batch/.ralph-stall-marker"
  [ -f "$marker" ] && pass || fail "the stall left a marker to delete"
  rm -f "$marker"

  head_before="$(git -C "$repo" rev-parse HEAD)"
  log="$WORK/rerun-no-marker-prompts.txt"
  RALPH_ALLOW_DIRTY=1 RALPH_FAKE_PROMPT_LOG="$log" RALPH_FAKE_BEHAVIOUR=land \
    run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 20 "no marker: refuses and stops for a human"
  assert_contains "$OUT" "Refusing to sync" "says why"
  assert_contains "$OUT" "git add -A && git commit -m 'wip:" "and prints the recovery note"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_before" "nothing was committed"
  [ -f "$log" ] && fail "no agent turn of any kind may run" || pass
  [ -n "$(git -C "$repo" status --porcelain)" ] && pass || fail "the work is untouched"

  # Without the override the preflight has its say first, exactly as it always did.
  run_ralph "$repo" run batch
  assert_eq "$ST" 1 "a dirty tree nobody vouches for still fails the preflight"
fi

if case_is "a marker that does not match the dirty tree is never trusted"; then
  # Each of these is a marker the loop wrote about a DIFFERENT situation than the one it
  # finds now: another sandbox's stall, another commit's, another ticket's. The sandbox is
  # per repository, so a dirty tree may be another batch's stall or a human's own session.
  for field in sandbox base_ref ticket; do
    repo="$(stalled_repo "rerun-mismatch-$field-repo")"
    marker="$repo/batch/.ralph-stall-marker"
    case "$field" in
      sandbox)  sed -i 's|^sandbox=.*|sandbox=some-other-sandbox|' "$marker" ;;
      base_ref) sed -i 's|^base_ref=.*|base_ref=0000000000000000000000000000000000000000|' "$marker" ;;
      ticket)   sed -i 's|^ticket=.*|ticket=batch/issues/02-ticket.md|' "$marker" ;;
    esac

    head_before="$(git -C "$repo" rev-parse HEAD)"
    log="$WORK/rerun-mismatch-$field-prompts.txt"
    RALPH_ALLOW_DIRTY=1 RALPH_FAKE_PROMPT_LOG="$log" RALPH_FAKE_BEHAVIOUR=land \
      run_ralph "$repo" run batch --unlimited
    assert_eq "$ST" 20 "$field mismatch: refuses"
    assert_contains "$OUT" "Refusing to sync" "$field mismatch: says why"
    assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_before" "$field mismatch: nothing committed"
    [ -f "$log" ] && fail "$field mismatch: no agent turn may run" || pass
    [ -n "$(git -C "$repo" status --porcelain)" ] && pass || fail "$field mismatch: work untouched"
  done
fi

if case_is "a rerun whose rescue fails stops for a human and keeps the marker"; then
  repo="$(stalled_repo rerun-rescue-fails-repo)"
  marker="$repo/batch/.ralph-stall-marker"
  head_before="$(git -C "$repo" rev-parse HEAD)"

  RALPH_FAKE_BEHAVIOUR=land RALPH_FAKE_CHECKPOINT_BEHAVIOUR=fail \
    run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 20 "a rescue that cannot commit stops for a human"
  assert_contains "$OUT" "could not" "and says the checkpoint turn failed"
  assert_contains "$OUT" "git add -A && git commit -m 'wip:" "with the adapter's recovery note"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head_before" "nothing was committed"
  assert_eq "$(done_count "$repo")" "0" "the ticket's own turn never ran"
  [ -f "$marker" ] && pass || fail "the stall is still unsalvaged, so it is still marked"

  # ...which is what makes the next rerun's rescue possible once the cause is fixed.
  RALPH_FAKE_BEHAVIOUR=land run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 0 "a later rerun rescues it"
  assert_eq "$(done_count "$repo")" "2" "and finishes the batch"
  [ -e "$marker" ] && fail "the marker is gone" || pass
fi

if case_is "a marker is removed once the tree is clean, and a salvaged stall leaves none"; then
  repo="$(stalled_repo rerun-clean-repo)"
  marker="$repo/batch/.ralph-stall-marker"

  # The operator rescues it by hand, as the recovery note says, and reruns.
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "wip: by hand"
  RALPH_FAKE_BEHAVIOUR=land run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 0 "a hand-rescued tree runs normally"
  assert_missing "$OUT" "Refusing to sync" "no refusal"
  [ -e "$marker" ] && fail "a clean tree retires the marker" || pass

  # A stall the checkpoint turn DID salvage was never left unsalvaged, so it never marks.
  repo="$(make_repo 2 salvaged-no-marker-repo)"
  RALPH_FAKE_BEHAVIOUR=dirty:land run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 0 "a salvaged stall finishes the batch"
  [ -e "$repo/batch/.ralph-stall-marker" ] && fail "a salvaged stall records no marker" || pass
fi

if case_is "--live draws what the agent is doing, and only that"; then
  # Once exec_run is invoked the terminal is silent until it returns. Writes and shell
  # commands are the two signals worth drawing; reads, greps and globs are the majority of
  # the traffic and say nothing about progress.
  # Two tickets, one iteration: the second is what the dry-run below has left to plan for.
  repo="$(make_repo 2 live-repo)"
  RALPH_FAKE_BEHAVIOUR=stream run_ralph "$repo" run batch --live

  assert_contains "$OUT" "Write src/foo.js" "a file write is drawn"
  assert_contains "$OUT" "Bash npm test" "and a shell command"
  assert_missing "$OUT" "src/quiet-read.js" "a read is not"
  # A tool_use event carries the WHOLE input — a Write carries the entire file body.
  assert_missing "$OUT" "SECRET-BODY-CONTENT" "the input object never reaches the terminal"
  assert_missing "$OUT" "TAIL-SENTINEL" "and a long argument is truncated"
  assert_eq "$(done_count "$repo")" "1" "the ticket still lands"

  # Which --output-format the adapter would ask for is the other decision `fake` cannot
  # exercise, so dry-run reports the state that decides it.
  run_ralph "$repo" dry-run batch
  assert_contains "$OUT" "Live:    off" "dry-run says a plain run is not watched"
  run_ralph "$repo" dry-run batch --live
  assert_contains "$OUT" "Live:    on" "and that a --live one is"
fi

if case_is "a --live run that produces no result object still says what it saw"; then
  # Verified against a real sandbox: when the agent fails to start, `sbx` prints its own
  # banner and `ERROR: agent exited with code 1`, and claude's error text never appears.
  # All of it is non-JSON, so the filter drops every line and the payload is empty — and the
  # recorder only dumps a raw payload when there is one, leaving the human with "payload was
  # not valid JSON" and nothing to read. The tail is what keeps that diagnosable.
  repo="$(make_repo 1 live-noresult)"
  RALPH_FAKE_BEHAVIOUR=stream-no-result run_ralph "$repo" run batch --live

  runlog="$(cat "$repo/batch/ralph-runs.log")"
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

  RALPH_FAKE_COST=0.25 run_ralph "$plain" run batch --unlimited
  plain_out="$OUT"; plain_st="$ST"
  RALPH_FAKE_COST=0.25 run_ralph "$lively" run batch --unlimited --live
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
  RALPH_FAKE_PROMPT_LOG="$log" RALPH_FAKE_BEHAVIOUR=partial-turn:land \
    run_ralph "$repo" run batch --unlimited

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

  run_ralph "$repo" report batch
  assert_contains "$OUT" "progressed 1" "the report counts it as its own outcome"
  run_ralph "$repo" report batch --failures
  assert_contains "$OUT" "every recorded iteration landed" "and does not flag it as a problem"
fi

if case_is "a ticket that never stops chunking is called mis-sized"; then
  repo="$(make_repo 2 continuation-cap-repo)"
  RALPH_MAX_CONTINUATIONS=3 RALPH_FAKE_BEHAVIOUR=partial-turn \
    run_ralph "$repo" run batch --unlimited

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
  RALPH_MAX_CONTINUATIONS=2 RALPH_FAKE_BEHAVIOUR=dirty \
    run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 20 "stops for a human rather than salvaging forever"
  assert_contains "$OUT" "has needed 2 extra turns without landing" "counts the stalls as continuations too"
  assert_contains "$OUT" "(0 progressed, 2 stalled)" "and says they were all stalls"
  assert_contains "$OUT" "split it into smaller tickets" "still advises splitting the ticket"
  assert_eq "$(done_count "$repo")" "0" "nothing landed"
fi

if case_is "a progressed iteration does not consume a ticket's attempts"; then
  repo="$(make_repo 2 progress-attempts-repo)"
  RALPH_TICKET_ATTEMPTS=2 RALPH_FAKE_BEHAVIOUR=partial-turn:noop \
    run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 20 "the unproductive iteration stops the run"
  assert_contains "$OUT" "after 1 attempt(s)" "only the unproductive one was counted"
fi

if case_is "a stalled iteration does not consume a ticket's attempts"; then
  repo="$(make_repo 2 stall-attempts-repo)"
  RALPH_FAKE_BEHAVIOUR=dirty:noop run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 20 "the unproductive iteration after the salvage stops the run"
  assert_contains "$OUT" "salvaged by a checkpoint turn" "the stall itself was salvaged, not attempted"
  # If the stall had spent an attempt, this would read "after 2 attempt(s)" instead.
  assert_contains "$OUT" "after 1 attempt(s)" "only the unproductive attempt after it was counted"
fi

if case_is "a checkpoint turn is recorded as its own row and its cost is in the run total"; then
  repo="$(make_repo 2 checkpoint-cost-repo)"
  RALPH_FAKE_COST=0.10 RALPH_FAKE_BEHAVIOUR=dirty:land \
    run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 0 "the batch still finishes"
  assert_eq "$(done_count "$repo")" "2" "both tickets land"

  # 4 turns actually ran (stall, its checkpoint, and one landing turn per ticket), but the
  # checkpoint is not one of the 3 iterations the operator commissioned.
  assert_contains "$OUT" "iterations run:        3" "the checkpoint turn does not advance the iteration count"
  assert_contains "$OUT" "cost (USD, reported):  \$0.400000" "but its cost is folded into the run total"

  jsonl="$repo/batch/ralph-runs.jsonl"
  assert_eq "$(grep -c . "$jsonl")" "4" "all 4 turns are recorded"
  assert_eq "$(grep -c '"kind":"checkpoint"' "$jsonl")" "1" "one of them is its own, distinguishable row"

  run_ralph "$repo" report batch
  assert_contains "$OUT" "stalled 1" "the report counts the stall as its own outcome"
  assert_contains "$OUT" "checkpoint turns 1" "and the checkpoint as its own bucket"
  assert_contains "$OUT" '$0.4000' "totalling all 4 turns' cost"

  run_ralph "$repo" report batch --failures
  assert_contains "$OUT" "every recorded iteration landed" "a salvaged stall is not flagged as a failure"
fi

if case_is "the prompt tells the agent how to hand a ticket off"; then
  repo="$(make_repo 1 handoff-prompt-repo)"
  printf 'RALPH_CONTEXT_BUDGET_TOKENS=123456\n' >> "$repo/batch/ralph.conf"
  git -C "$repo" commit --quiet -am "context budget"

  run_ralph "$repo" dry-run batch
  assert_eq "$ST" 0 "dry-run exits 0"
  assert_contains "$OUT" "123456 tokens of context" "the budget comes from ralph.conf"
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
  RALPH_FAKE_BEHAVIOUR=permission-denied run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 20 "exits needs-a-human"
  assert_contains "$OUT" "stopped by a permission denial" "names the real cause"
  assert_contains "$OUT" 'Bash(git commit:*)' "and the exact ralph.conf line that fixes it"
  assert_missing "$OUT" "left uncommitted changes behind" "not reported as a plain dirty tree"
  # The stall branch sits BELOW this one: a denied `git commit` dirties the tree as a
  # consequence, and a checkpoint turn salvaging it would report the symptom, never the
  # cause.
  assert_missing "$OUT" "stalled" "and no checkpoint turn is attempted either"
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "1" "committed nothing"

  runlog="$(cat "$repo/batch/ralph-runs.log")"
  assert_contains "$runlog" "PERMISSION DENIED SIGNAL DETECTED" "recorded as its own signal"
fi

if case_is "the permission mode defaults to what the execution mode needs"; then
  # Not reachable through `fake`, which never invokes `claude` — which is exactly why
  # dry-run reports the effective mode. Inside a sandbox the container is the boundary and
  # the gate only costs a paid iteration; on a real machine `local` keeps its gate.
  repo="$(make_repo 1 perms-repo)"

  printf 'RALPH_EXEC=local\n' >> "$repo/batch/ralph.conf"
  git -C "$repo" commit --quiet -am "local mode"
  run_ralph "$repo" dry-run batch
  assert_eq "$ST" 0 "dry-run exits 0"
  assert_contains "$OUT" "Perms:   acceptEdits" "local keeps the permission gate"

  printf 'RALPH_EXEC=sandbox\n' >> "$repo/batch/ralph.conf"
  git -C "$repo" commit --quiet -am "sandbox mode"
  run_ralph "$repo" dry-run batch
  assert_contains "$OUT" "Perms:   bypassPermissions" "a sandbox mode does not"

  printf 'RALPH_PERMISSION_MODE=plan\n' >> "$repo/batch/ralph.conf"
  git -C "$repo" commit --quiet -am "explicit mode"
  run_ralph "$repo" dry-run batch
  assert_contains "$OUT" "Perms:   plan" "an explicit setting beats the default"

  RALPH_PERMISSION_MODE=manual run_ralph "$repo" dry-run batch
  assert_contains "$OUT" "Perms:   manual" "and the environment beats ralph.conf"
fi

if case_is "doctor flags a local batch whose agent could never commit"; then
  repo="$WORK/perm-doctor-repo"
  mkdir -p "$repo/batch/issues"
  git -C "$repo" init --quiet
  printf '# Ticket 1\n\n**Status:** todo\n' > "$repo/batch/issues/01-ticket.md"
  printf 'RALPH_EXEC=local\n' > "$repo/batch/ralph.conf"

  run_ralph "$repo" doctor
  assert_eq "$ST" 1 "doctor reports something to fix"
  assert_contains "$OUT" "no way for the agent to commit" "says what is wrong"
  assert_contains "$OUT" 'Bash(git add:*)' "and the line to add"

  printf 'RALPH_CLAUDE_ARGS=(--allowed-tools "Bash(git add:*)" "Bash(git commit:*)")\n' \
    >> "$repo/batch/ralph.conf"
  run_ralph "$repo" doctor
  assert_missing "$OUT" "no way for the agent to commit" "and is satisfied once it is there"
fi

if case_is "a usage limit pauses the run"; then
  repo="$(make_repo 3 limit-repo)"
  RALPH_FAKE_BEHAVIOUR=limit run_ralph "$repo" run batch --unlimited

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
  RALPH_FAKE_BEHAVIOUR=session-limit run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 10 "exits paused, not stopped"
  assert_contains "$OUT" "usage limit reached" "reads as a limit, not a mystery stop"
  assert_contains "$OUT" "4:50pm" "carries the reset time through to the pause message"
  assert_contains "$OUT" "Resume:" "tells you how to resume"
fi

if case_is "the cost budget stops the run before spending over it"; then
  repo="$(make_repo 5 cost-repo)"
  RALPH_FAKE_COST=0.50 RALPH_MAX_COST_USD=1 run_ralph "$repo" run batch --unlimited

  assert_eq "$ST" 10 "pauses on the cost budget"
  assert_contains "$OUT" "cost budget reached" "says why"
  assert_eq "$(done_count "$repo")" "2" "stops once the budget is reached, not after"
  assert_missing "$OUT" "overshot to salvage" "nothing stalled here, so no salvage note"
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
  # The one thing the agent cannot discover for itself: --print gives it no second turn, so
  # a backgrounded verify command ends the iteration waiting for a result that never comes.
  assert_contains "$prompts" "single non-interactive turn" "it says the session is one-shot"
  assert_contains "$prompts" "in the foreground" "and that checks must be waited on"
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
  assert_contains "$order" "ready-for-human" "the prose points at human tickets"
  assert_contains "$order" "followup" "the prose points at followup tickets"
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

if case_is "a landed ticket with every box ticked is renamed DONE_"; then
  repo="$(make_repo 2 done-rename-repo)"
  run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 0 "the batch finishes"
  d="$repo/batch/issues"
  [ -f "$d/DONE_01-ticket.md" ] && [ -f "$d/DONE_02-ticket.md" ] && pass || fail "both tickets carry the prefix"
  [ -e "$d/01-ticket.md" ] && fail "the old name is gone" || pass
  assert_contains "$OUT" "marked done" "the rename is announced"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "the rename was committed, tree is clean"
  assert_contains "$(git -C "$repo" log --format=%s)" "chore: mark 01-ticket.md done" "as its own commit"
  assert_eq "$(done_count "$repo")" "2" "renamed tickets still count as done"

  run_ralph "$repo" next batch --count
  assert_eq "$OUT" "2 2" "--count agrees"
  run_ralph "$repo" run batch
  assert_eq "$ST" 0 "a rerun has nothing left to do and renames nothing further"
fi

if case_is "a ticket with an unticked box, or not yet done, keeps its name"; then
  repo="$(make_repo 2 done-rename-boxes-repo)"
  printf '# Ticket 1\n\n**Status:** todo\n\n- [x] one\n  - [ ] two\n' > "$repo/batch/issues/01-ticket.md"
  printf '# Ticket 2\n\n**Status:** todo\n\n- [x] one\n* [X] two\n' > "$repo/batch/issues/02-ticket.md"
  git -C "$repo" commit --quiet -am "boxes"

  run_ralph "$repo" run batch --unlimited
  d="$repo/batch/issues"
  [ -f "$d/01-ticket.md" ] && pass || fail "unticked box: the name is kept"
  assert_contains "$OUT" "unchecked boxes" "and says why"
  [ -f "$d/DONE_02-ticket.md" ] && pass || fail "every box ticked: renamed"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "tree clean"

  repo="$(make_repo 1 done-rename-noop-repo)"
  RALPH_FAKE_BEHAVIOUR=noop run_ralph "$repo" run batch 1
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

  run_ralph "$repo" run batch 1
  [ -f "$repo/batch/issues/DONE_03-ticket.md" ] && pass || fail "ticket 3 ran first and was renamed"
  run_ralph "$repo" next batch --all
  assert_eq "$(printf '%s\n' "$OUT" | head -1)" "batch/issues/DONE_03-ticket.md" "order.md resolves the renamed file"
  run_ralph "$repo" next batch
  assert_eq "$OUT" "batch/issues/01-ticket.md" "and the next ticket is still 01"
fi

if case_is "renamed tickets keep their place in filename order"; then
  repo="$(make_repo 3 done-rename-sort-repo)"
  git -C "$repo" mv batch/issues/01-ticket.md batch/issues/DONE_01-ticket.md
  run_ralph "$repo" next batch --all
  assert_eq "$(printf '%s\n' "$OUT" | head -1)" "batch/issues/DONE_01-ticket.md" "DONE_01 sorts as 01"
  assert_eq "$(printf '%s\n' "$OUT" | tail -1)" "batch/issues/03-ticket.md" "and 03 is still last"
fi

if case_is "RALPH_DONE_PREFIX empty leaves ticket files alone"; then
  repo="$(make_repo 1 done-rename-off-repo)"
  RALPH_DONE_PREFIX= run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 0 "the batch finishes"
  [ -f "$repo/batch/issues/01-ticket.md" ] && pass || fail "the ticket kept its name"
fi

if case_is "a ticket marked done counts as done, like an implemented one"; then
  repo="$(make_repo 2 done-word-repo)"
  printf '# Ticket 1\n\n**Status:** done\n\n- [x] one\n' > "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "01 done by hand"

  run_ralph "$repo" next batch --count
  assert_eq "$OUT" "1 2" "done is counted like implemented"
  run_ralph "$repo" next batch
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

runs_rows() { grep -c . "$1/batch/ralph-runs.jsonl" 2>/dev/null || printf 0; }

if case_is "a human ticket at the head of the order stops the run before anything is spent"; then
  repo="$(make_repo 3 human-head-repo)"
  make_human_ticket "$repo" 1
  head="$(git -C "$repo" rev-parse HEAD)"
  log="$WORK/human-head-prompts.txt"

  RALPH_FAKE_PROMPT_LOG="$log" run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 30 "exits waiting-on-a-human"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head" "no new commits"
  [ -e "$repo/batch/ralph-runs.jsonl" ] && fail "no run-log rows were written" || pass
  [ -e "$repo/batch/ralph-runs.log" ] && fail "and no run log at all" || pass
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

  run_ralph "$repo" run batch
  assert_eq "$ST" 30 "still stops"
  assert_missing "$OUT" "Fill in every section" "there is no handoff step to give"
  assert_contains "$OUT" "  2. Commit your work." "and the steps renumber"
  assert_contains "$OUT" "  4. Rerun:" "ending at the rerun"
fi

if case_is "a run that reaches a human ticket mid-batch lands what is before it and stops"; then
  repo="$(make_repo 4 human-mid-repo)"
  make_human_ticket "$repo" 3
  log="$WORK/human-mid-prompts.txt"

  RALPH_FAKE_PROMPT_LOG="$log" run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 30 "exits waiting-on-a-human"
  assert_eq "$(done_count "$repo")" "2" "tickets 1 and 2 landed"
  assert_contains "$OUT" "tickets landed:        2" "the usual footer is printed"
  assert_contains "$OUT" "batch/issues/03-ticket.md is a human ticket" "then the note"
  assert_eq "$(grep -c '^===== fake prompt' "$log")" "2" "only the two agent tickets were prompted"
  assert_missing "$(cat "$log")" "04-ticket.md" "nothing after the human ticket was prompted"
  assert_contains "$(tail -3 "$repo/batch/ralph-runs.log")" \
    "# stopped: waiting on a human — batch/issues/03-ticket.md" "the run log says why it stopped"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "the tree is clean"
fi

if case_is "the human gate is checked before the iteration budget"; then
  repo="$(make_repo 2 human-budget-repo)"
  make_human_ticket "$repo" 2

  run_ralph "$repo" run batch
  assert_eq "$ST" 30 "waiting on a human, not paused on the budget"
  assert_eq "$(done_count "$repo")" "1" "the first ticket landed"
  assert_missing "$OUT" "PAUSED" "and nothing says the budget stopped it"
  assert_contains "$OUT" "run batch 1" "the rerun command keeps the iteration count"
fi

if case_is "rerunning a human ticket without finishing it stops again, for free"; then
  repo="$(make_repo 4 human-rerun-repo)"
  make_human_ticket "$repo" 3
  run_ralph "$repo" run batch --unlimited
  head="$(git -C "$repo" rev-parse HEAD)"
  rows="$(runs_rows "$repo")"
  log="$WORK/human-rerun-prompts.txt"

  RALPH_FAKE_PROMPT_LOG="$log" run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 30 "stops the same way"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head" "HEAD did not move"
  assert_eq "$(runs_rows "$repo")" "$rows" "nothing was recorded"
  [ -e "$log" ] && fail "no prompt was sent" || pass
  assert_contains "$OUT" "batch/issues/03-ticket.md is a human ticket" "says the same thing"
fi

if case_is "setting a human ticket to done lets a rerun continue with the next ticket"; then
  repo="$(make_repo 3 human-resume-repo)"
  make_human_ticket "$repo" 2
  run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 30 "stopped at the human ticket"

  finish_human_ticket "$repo" 2
  log="$WORK/human-resume-prompts.txt"
  RALPH_FAKE_PROMPT_LOG="$log" run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 0 "the batch finishes"
  assert_eq "$(grep -c '^===== fake prompt' "$log")" "1" "one prompt: the ticket after it"
  assert_contains "$(cat "$log")" "03-ticket.md" "and it was ticket 3"
fi

if case_is "dry-run at a human ticket says it would stop there and prints no prompt"; then
  repo="$(make_repo 2 human-dry-repo)"
  make_human_ticket "$repo" 1

  run_ralph "$repo" dry-run batch
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

  run_ralph "$repo" run batch
  assert_eq "$ST" 10 "the default word no longer stops there: the ticket is an agent's"

  repo="$(make_repo 2 human-word2-repo)"
  make_human_ticket "$repo" 1
  sed -i 's/ready-for-human/needs-owner/' "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "a different word"
  RALPH_HUMAN_WORD=needs-owner run_ralph "$repo" run batch
  assert_eq "$ST" 30 "RALPH_HUMAN_WORD=needs-owner stops on that word"
  assert_contains "$OUT" "'**Status:** needs-owner'" "and the note quotes it"

  repo="$(make_repo 2 human-off-repo)"
  make_human_ticket "$repo" 1
  log="$WORK/human-off-prompts.txt"
  RALPH_HUMAN_WORD= RALPH_FAKE_PROMPT_LOG="$log" run_ralph "$repo" run batch
  assert_eq "$ST" 10 "an empty word hands the ticket to the agent like any other"
  assert_contains "$(cat "$log")" "01-ticket.md" "which was prompted"
fi

if case_is "a done ticket is never a human ticket"; then
  repo="$(make_repo 2 human-done-repo)"
  make_human_ticket "$repo" 1
  finish_human_ticket "$repo" 1
  run_ralph "$repo" dry-run batch
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
  run_ralph "$repo" run batch --unlimited
  finish_human_ticket "$repo" 3
  printf '%s' "$repo"
}

if case_is "a followup ticket that sends its human ticket back ends the run at exit 30"; then
  repo="$(checked_repo check-sendback-repo)"
  log="$WORK/check-sendback-prompts.txt"

  RALPH_FAKE_BEHAVIOUR=send-back RALPH_FAKE_PROMPT_LOG="$log" run_ralph "$repo" run batch --unlimited
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
  run_ralph "$repo" run batch --unlimited
  assert_eq "$ST" 30 "a plain rerun stops the same way"
  assert_contains "$OUT" "↩ It was sent back by 04-ticket.md" "and says again that it was sent back"
  assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head" "HEAD did not move"
  assert_eq "$(runs_rows "$repo")" "$rows" "nothing was recorded"
fi

if case_is "a human ticket is renamed only once its followup ticket has landed"; then
  repo="$(checked_repo check-rename-repo)"

  RALPH_FAKE_BEHAVIOUR=noop run_ralph "$repo" run batch 1
  assert_eq "$ST" 20 "a followup ticket that does nothing does not land"
  [ -e "$repo/batch/issues/03-ticket.md" ] && pass || fail "so the human ticket keeps its name"
  [ -e "$repo/batch/issues/DONE_03-ticket.md" ] && fail "and is not prefixed" || pass

  run_ralph "$repo" run batch 1
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
  run_ralph "$repo" run batch 2
  assert_contains "$OUT" "batch/issues/02-ticket.md waits for batch/issues/03-ticket.md" "found through the prefix"
  [ -e "$repo/batch/issues/DONE_02-ticket.md" ] && pass || fail "and renamed when the followup landed"

  # The human ticket carries the prefix; the followup ticket names it without.
  repo="$(make_repo 2 check-prefix2-repo)"
  make_human_ticket "$repo" 1
  make_followup_ticket "$repo" 2 1
  finish_human_ticket "$repo" 1
  git -C "$repo" mv batch/issues/01-ticket.md batch/issues/DONE_01-ticket.md
  git -C "$repo" commit --quiet -m "renamed by hand"
  RALPH_FAKE_BEHAVIOUR=send-back run_ralph "$repo" run batch
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

  run_ralph "$repo" status batch
  assert_eq "$ST" 0 "status still exits 0"
  assert_contains "$OUT" "human tickets remaining: 1" "the progress line counts it"
  assert_contains "$OUT" "  3  03-ticket.md   [HUMAN]" "the human ticket is marked"
  assert_contains "$OUT" "  4  04-ticket.md   [CHECKS 03-ticket.md]" "and its checker names it"
  assert_contains "$OUT" \
    "The loop will run 2 ticket(s), then stop at 03-ticket.md for a human." \
    "and says where it will stop"
  assert_missing "$OUT" "warning:" "both pieces are in place, so nothing to warn about"

  run_ralph "$repo" dry-run batch
  assert_eq "$ST" 0 "dry-run exits 0"
  assert_contains "$OUT" "  3  03-ticket.md   [HUMAN]" "dry-run marks the same way"
  assert_contains "$OUT" "  4  04-ticket.md   [CHECKS 03-ticket.md]" "checker included"
fi

if case_is "status names the human ticket when it is next, with its note"; then
  repo="$(make_repo 2 status-next-human-repo)"
  make_human_ticket "$repo" 1

  run_ralph "$repo" status batch
  assert_eq "$ST" 0 "status exits 0"
  assert_contains "$OUT" "Next: 01-ticket.md   [HUMAN" "Next: is marked"
  assert_contains "$OUT" "batch/issues/01-ticket.md is a human ticket. The loop stops here." \
    "and the note follows"
  assert_contains "$OUT" "batch/handoff/01-ticket.md" "naming the handoff file"
fi

if case_is "warning: a human ticket with no followup ticket"; then
  repo="$(make_repo 1 warn-nocheck-repo)"
  make_human_ticket "$repo" 1

  run_ralph "$repo" status batch
  assert_eq "$ST" 0 "warnings never change the exit code"
  assert_contains "$OUT" \
    "warning: batch/issues/01-ticket.md is a human ticket with no ticket that Checks: it — run /ralph-human-followup-tickets" \
    "warns about the missing checker"
fi

if case_is "warning: a human ticket with no handoff file"; then
  repo="$(make_repo 1 warn-nohandoff-repo)"
  make_human_ticket "$repo" 1 none

  run_ralph "$repo" status batch
  assert_eq "$ST" 0 "warnings never change the exit code"
  assert_contains "$OUT" "warning: batch/issues/01-ticket.md has no Handoff: file — run /ralph-human-followup-tickets" \
    "warns about the missing handoff"
fi

if case_is "warning: a Handoff: line naming a file that does not exist"; then
  repo="$(make_repo 1 warn-missinghandoff-repo)"
  make_human_ticket "$repo" 1
  rm "$repo/batch/handoff/01-ticket.md"
  git -C "$repo" commit --quiet -am "the handoff file went missing"

  run_ralph "$repo" status batch
  assert_eq "$ST" 0 "warnings never change the exit code"
  assert_contains "$OUT" "warning: batch/issues/01-ticket.md has no Handoff: file — run /ralph-human-followup-tickets" \
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

  run_ralph "$repo" status batch
  assert_eq "$ST" 0 "warnings never change the exit code"
  assert_contains "$OUT" \
    "warning: batch/issues/03-ticket.md should come right after batch/issues/01-ticket.md in order.md" \
    "warns that the checker is out of place"
fi

if case_is "warning: a Checks: line naming no ticket in the batch"; then
  repo="$(make_repo 2 warn-unresolved-repo)"
  sed -i 's/^\*\*Status:\*\* todo/&\n**Checks:** 99-nowhere.md/' "$repo/batch/issues/02-ticket.md"
  git -C "$repo" commit --quiet -am "ticket 2 checks nothing that exists"

  run_ralph "$repo" status batch
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

  RALPH_HUMAN_WORD= run_ralph "$repo" status batch
  assert_eq "$ST" 0 "still exits 0"
  assert_missing "$OUT" "is a human ticket with no ticket" "warning 1 is skipped"
  assert_missing "$OUT" "has no Handoff:" "warning 2 is skipped"
  assert_contains "$OUT" "which is not a ticket in this batch" "warning 4 still applies"
fi

if case_is "dry-run at a human ticket still shows the marked listing and warnings"; then
  repo="$(make_repo 1 warn-dryrun-repo)"
  make_human_ticket "$repo" 1

  run_ralph "$repo" dry-run batch
  assert_eq "$ST" 0 "exits 0"
  assert_contains "$OUT" "  1  01-ticket.md   [HUMAN]" "the listing is marked"
  assert_contains "$OUT" \
    "warning: batch/issues/01-ticket.md is a human ticket with no ticket that Checks: it — run /ralph-human-followup-tickets" \
    "and the warning is printed"
  assert_contains "$OUT" "Would stop before batch/issues/01-ticket.md" "still says it would stop"
fi

if case_is "the start-of-run sweep renames a finished ticket and leaves a dirty tree alone"; then
  repo="$(make_repo 2 sweep-repo)"
  sed -i 's/^\*\*Status:\*\* todo/**Status:** done\n\n- [x] the thing/' "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "ticket 1 done by hand"

  run_ralph "$repo" status batch
  run_ralph "$repo" dry-run batch
  [ -e "$repo/batch/issues/01-ticket.md" ] && pass || fail "status and dry-run rename nothing"

  run_ralph "$repo" run batch 1
  [ -e "$repo/batch/issues/DONE_01-ticket.md" ] && pass || fail "a run renames it before picking a ticket"
  assert_contains "$OUT" "✓ marked done" "and says so"
  assert_contains "$(git -C "$repo" log --format=%s)" "chore: mark 01-ticket.md done" "in a commit of its own"

  repo="$(make_repo 2 sweep-unticked-repo)"
  sed -i 's/^\*\*Status:\*\* todo/**Status:** done\n\n- [ ] the thing/' "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "ticket 1 done by hand, boxes unticked"
  run_ralph "$repo" run batch 1
  [ -e "$repo/batch/issues/01-ticket.md" ] && pass || fail "an unticked ticket keeps its name"

  repo="$(make_repo 3 sweep-dirty-repo)"
  sed -i 's/^\*\*Status:\*\* todo/**Status:** done/' "$repo/batch/issues/01-ticket.md"
  git -C "$repo" commit --quiet -am "ticket 1 done by hand"
  printf 'uncommitted\n' > "$repo/scratch.txt"
  RALPH_ALLOW_DIRTY=1 run_ralph "$repo" run batch 1
  [ -e "$repo/batch/issues/01-ticket.md" ] && pass || fail "a dirty tree is not swept"
  assert_missing "$(git -C "$repo" log --format=%s)" "mark 01-ticket.md done" "and no rename commit was made"
fi

# ---------------------------------------------------------------------------
# Ordering
# ---------------------------------------------------------------------------

# A stub `claude` on PATH for `ralph order`: captures the `-p` prompt to
# RALPH_ORDER_PROMPT_LOG and prints a placeholder response, so ordering runs with no model
# and no cost. Prints the stub's own directory — put it first on PATH.
make_claude_stub() {
  local dir="$WORK/claude-stub"
  mkdir -p "$dir"
  cat > "$dir/claude" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    -p) shift; [ -n "${RALPH_ORDER_PROMPT_LOG:-}" ] && printf '%s' "$1" > "$RALPH_ORDER_PROMPT_LOG" ;;
  esac
  shift
done
echo '{"total_cost_usd":0}'
STUB
  chmod +x "$dir/claude"
  printf '%s' "$dir"
}

# order.md need only exist for `ralph order` to run — it always re-derives the ticket list
# itself (--unordered). But `ralph_human_warnings` reads the batch through `--all`, which DOES
# honour order.md, so the block has to list every ticket already in batch/issues, or an empty
# block reads as an empty batch.
write_order_stub() {    # write_order_stub REPO
  local repo="$1"
  { echo '<!-- ORDER:BEGIN -->'
    for f in "$repo"/batch/issues/*.md; do echo "batch/issues/$(basename "$f")"; done
    echo '<!-- ORDER:END -->'; } > "$repo/batch/order.md"
  git -C "$repo" add -A && git -C "$repo" commit --quiet -m "order.md stub"
}

if case_is "ralph order runs with a stub claude, spending no money and needing no model"; then
  repo="$(make_repo 2 order-stub-repo)"
  write_order_stub "$repo"
  log="$WORK/order-stub-prompt.txt"

  PATH="$(make_claude_stub):$PATH" RALPH_ORDER_PROMPT_LOG="$log" run_ralph "$repo" order batch
  assert_eq "$ST" 0 "ralph order exits 0 against the stub"
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

  PATH="$(make_claude_stub):$PATH" RALPH_ORDER_PROMPT_LOG="$log" run_ralph "$repo" order batch
  assert_eq "$ST" 0 "ralph order still exits 0"
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

  PATH="$(make_claude_stub):$PATH" RALPH_ORDER_PROMPT_LOG="$log" run_ralph "$repo" order batch
  assert_eq "$ST" 0 "ralph order exits 0"
  prompt="$(cat "$log")"
  assert_missing "$prompt" "HUMAN TICKETS" "no human-tickets section"
  assert_missing "$prompt" "FOLLOWUP TICKETS" "no followup-tickets section"
  assert_contains "$prompt" "Blocked by" "the Blocked by: sentence is still there"
fi

if case_is "ralph order warns about a human ticket with no followup ticket, and still exits 0"; then
  repo="$(make_repo 1 order-warn-repo)"
  make_human_ticket "$repo" 1
  write_order_stub "$repo"

  PATH="$(make_claude_stub):$PATH" run_ralph "$repo" order batch
  assert_eq "$ST" 0 "warnings never change the exit code"
  assert_contains "$OUT" \
    "warning: batch/issues/01-ticket.md is a human ticket with no ticket that Checks: it — run /ralph-human-followup-tickets" \
    "and the warning is printed after ordering"
fi

# ---------------------------------------------------------------------------
# install.sh and the skill copy
# ---------------------------------------------------------------------------

# A throwaway copy of this checkout's bin/lib/skills/install.sh, so a test can edit its
# SKILL.md (simulating a pulled update) without touching the real repo. Prints its path.
make_ralph_checkout() {
  local name="${1:-checkout}" dir
  dir="$WORK/$name"
  mkdir -p "$dir"
  cp -r "$RALPH_HOME/bin" "$RALPH_HOME/lib" "$RALPH_HOME/skills" "$RALPH_HOME/install.sh" "$dir/"
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

skill_copy_dir() { printf '%s/skills/ralph-human-followup-tickets' "$1"; }

if case_is "install.sh installs the shims and a marked copy of the skill"; then
  checkout="$(make_ralph_checkout install-basic-checkout)"
  run_install "$checkout" install-basic

  assert_eq "$ST" 0 "install.sh exits 0"
  [ -f "$INSTALL_BIN/ralph" ] && pass || fail "the bash shim was written"
  [ -f "$INSTALL_BIN/ralph.cmd" ] && pass || fail "the cmd shim was written"
  [ -f "$(skill_copy_dir "$INSTALL_CONFIG")/SKILL.md" ] && pass || fail "the skill's SKILL.md was copied"
  [ -f "$(skill_copy_dir "$INSTALL_CONFIG")/.ralph-installed-from" ] && pass || fail "the copy carries the marker"
  assert_contains "$OUT" "installed skill" "and says so"
fi

if case_is "re-running install.sh after the checkout's SKILL.md changes replaces the copy, no --force needed"; then
  checkout="$(make_ralph_checkout install-update-checkout)"
  run_install "$checkout" install-update
  assert_eq "$ST" 0 "the first install exits 0"

  printf '\n<!-- a line the pulled update added -->\n' >> "$checkout/skills/ralph-human-followup-tickets/SKILL.md"
  run_install "$checkout" install-update
  assert_eq "$ST" 0 "the second install exits 0 without --force"
  assert_contains "$(cat "$(skill_copy_dir "$INSTALL_CONFIG")/SKILL.md")" \
    "a line the pulled update added" "the installed copy picked up the change"
fi

if case_is "a skill directory without the marker refuses and writes nothing; --force overwrites it"; then
  checkout="$(make_ralph_checkout install-foreign-checkout)"
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
  [ -f "$(skill_copy_dir "$INSTALL_CONFIG")/.ralph-installed-from" ] && pass || fail "the copy now carries the marker"
fi

if case_is "--uninstall removes a marked copy and leaves an unmarked one alone"; then
  checkout="$(make_ralph_checkout install-uninstall-checkout)"

  run_install "$checkout" install-uninstall-marked
  assert_eq "$ST" 0 "the install exits 0"
  run_install "$checkout" install-uninstall-marked --uninstall
  assert_eq "$ST" 0 "uninstall exits 0"
  [ -e "$(skill_copy_dir "$INSTALL_CONFIG")" ] && fail "the marked copy was removed" || pass
  [ -e "$INSTALL_BIN/ralph" ] && fail "the shims were removed too" || pass

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
  checkout="$(make_ralph_checkout install-noskill-checkout)"
  run_install "$checkout" install-noskill --no-skill

  assert_eq "$ST" 0 "install.sh exits 0"
  [ -f "$INSTALL_BIN/ralph" ] && pass || fail "the shims were still installed"
  [ -e "$(skill_copy_dir "$INSTALL_CONFIG")" ] && fail "no skill directory was created" || pass
fi

if case_is "ralph doctor warns when the installed skill copy is stale, and is silent otherwise"; then
  repo="$WORK/doctor-skill-repo"
  mkdir -p "$repo"
  git -C "$repo" init --quiet
  git -C "$repo" config user.name ralph-test
  git -C "$repo" config user.email test@ralph.invalid

  doctor_home="$WORK/doctor-skill-home"
  doctor_config="$WORK/doctor-skill-config"
  doctor_bin="$WORK/doctor-skill-bin"
  mkdir -p "$doctor_home" "$doctor_config"

  run_doctor() { OUT="$(cd "$repo" && HOME="$doctor_home" CLAUDE_CONFIG_DIR="$doctor_config" "$RALPH" doctor 2>&1)"; ST=$?; }

  run_doctor
  assert_missing "$OUT" "ralph-human-followup-tickets" "silent before the skill is installed"

  HOME="$doctor_home" CLAUDE_CONFIG_DIR="$doctor_config" bash "$RALPH_HOME/install.sh" --to "$doctor_bin" >/dev/null

  run_doctor
  assert_missing "$OUT" "STALE" "silent — the installed copy matches this checkout"

  printf '\n<!-- drift -->\n' >> "$(skill_copy_dir "$doctor_config")/SKILL.md"
  run_doctor
  assert_contains "$OUT" "STALE" "warns once the installed copy drifts"
  assert_contains "$OUT" "ralph-human-followup-tickets" "names the skill"
  assert_contains "$OUT" "install.sh" "and says to re-run it"
fi

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
