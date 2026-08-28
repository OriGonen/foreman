#!/bin/bash
#
# Ralph: one ticket per iteration.
#
#   ralph run     <batch>              # run one iteration
#   ralph run     <batch> 5            # run at most 5 iterations
#   ralph run     <batch> --unlimited  # run until done or a budget stops it
#   ralph status  <batch>              # what is left, what is next
#   ralph dry-run <batch>              # print the plan and the next prompt
#
# <batch> is any directory IN THE CURRENT REPOSITORY holding tickets and a ralph.conf —
# see the toolkit's README.md and ralph-init.sh. Nothing about a batch is shared with any
# other batch: its order, its progress notes and its run logs all live in its own
# directory. This toolkit is stateless and lives outside the repository it works on.
# If exactly one directory in the repo has a ralph.conf, <batch> may be omitted.
#
# WHERE THE WORK HAPPENS  (RALPH_EXEC, set per batch in ralph.conf)
#   sandbox        the agent runs on a private clone inside an `sbx` sandbox and each
#                  iteration's commits are brought back as a git bundle. The default,
#                  and the only mode that survives a host/container native-module split
#                  (e.g. a Windows host and a Linux container sharing node_modules).
#   sandbox-mount  `sbx` bind-mounting this working tree; commits land here directly.
#   local          `claude` in this working tree, no sandbox. Simplest; no isolation.
#   fake           no agent at all — the loop, driven by a script. See lib/exec/fake.sh.
#
# This loop knows none of that. Each mode is an adapter in lib/exec/ satisfying the
# interface in ralph-exec.sh, and every `exec_*` call below crosses that seam.
#
# RESUMING
#   Just run it again. There is no state file and nothing to clean up: each iteration
#   commits the ticket's flipped Status line together with its code, so the last commit
#   and the resume point can never disagree. Whether the loop stopped on a budget, on a
#   usage limit, on Ctrl-C, or because the machine died, the next run starts at the first
#   ticket that has not landed. See ralph-next.sh.
#
# BUDGETS (all optional; 0 or unset means no limit)
#   RALPH_MAX_COST_USD=25     pause before an iteration that would take the run over $25
#   RALPH_MAX_MINUTES=180     pause before an iteration once 180 minutes have elapsed
#   <iterations> argument     pause after this many iterations (default: 1)
#   --unlimited               no iteration cap; only cost/time budgets stop it
#
# OTHER KNOBS (all settable in ralph.conf; the environment wins over it)
#   RALPH_MODEL=claude-sonnet-5    RALPH_EFFORT=high
#   RALPH_TICKET_ATTEMPTS=2        tries per ticket within one run before stopping
#   RALPH_ALLOW_DIRTY=1            skip the clean-tree preflight
#   RALPH_SANDBOX=<name>           sandbox to create/reattach to
#   RALPH_SKIP_SANDBOX_PROBE=1     skip the batch's sandbox readiness probe and its setup
#
# EXIT CODES
#   0   every ticket in the batch is done
#   10  paused, resumable — rerun the same command (budget, usage limit, Ctrl-C)
#   20  stopped, needs a human — a ticket did not land, or the tree was left dirty
#   1   preflight failure or bad usage
#
set -uo pipefail

RALPH_TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXIT_DONE=0
EXIT_PAUSED=10
EXIT_NEEDS_HUMAN=20

# ---------------------------------------------------------------------------
# Arguments: an optional batch path, then an optional mode or iteration count.
# ---------------------------------------------------------------------------
MODE=run
MAX_ITERATIONS=1   # default: one iteration. --unlimited sets this to 0 (no cap).

# The header comment above is the help text. Stop at the first non-comment line rather
# than at a fixed line number, which drifts every time the header grows.
show_help() { awk 'NR==1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --status)    MODE=status ;;
    --dry-run)   MODE=dry-run ;;
    --unlimited) MAX_ITERATIONS=0 ;;
    --help|-h)   show_help; exit 0 ;;
    -*)          echo "Usage: ${RALPH_INVOKE:-ralph} run [<batch>] [<iterations>|--unlimited]" >&2; exit 1 ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      elif [ -z "${RALPH_BATCH:-}" ] || [ "${RALPH_BATCH_FROM_ARG:-0}" = 0 ]; then
        export RALPH_BATCH="$1" RALPH_BATCH_FROM_ARG=1
      else
        echo "ralph: more than one batch given ('$RALPH_BATCH' and '$1')" >&2
        exit 1
      fi
      ;;
  esac
  shift
done
unset RALPH_BATCH_FROM_ARG

# shellcheck source=ralph-config.sh
source "$RALPH_TOOL_DIR/ralph-config.sh" || exit 1

MAX_COST="$RALPH_MAX_COST_USD"
MAX_MINUTES="$RALPH_MAX_MINUTES"
TICKET_ATTEMPTS="$RALPH_TICKET_ATTEMPTS"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# Bash has no floats. Every cost comparison and accumulation goes through awk.
fadd() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.6f", a + b }'; }
fge()  { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }
fgt()  { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >  b + 0) }'; }

# Pull one key out of a ralph-record.cjs verdict file. Fixed keys, sanitized values —
# nothing derived from model output is ever eval'd.
verdict_get() {
  local file="$1" key="$2" line
  line=$(grep -m1 "^${key}=" "$file" 2>/dev/null) || { printf '%s' ''; return; }
  printf '%s' "${line#*=}"
}

# Same, but guaranteed to yield an integer, so `$(( ))` cannot be handed an empty string
# if the recorder died before writing the file.
verdict_num() {
  local value
  value=$(verdict_get "$1" "$2")
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  printf '%s' "$value"
}

log_append() { printf '%s\n' "$*" >> "$RUN_LOG"; }

# 0 means "no limit" for every budget, which reads badly printed bare.
budget_label() {
  local value="$1" prefix="${2:-}" suffix="${3:-}"
  if fgt "$value" 0; then printf '%s%s%s' "$prefix" "$value" "$suffix"; else printf 'unlimited'; fi
}

tree_is_dirty() { [ -n "$(git status --porcelain)" ]; }
ticket_is_done() { grep -q "$RALPH_DONE_PATTERN" "$1"; }

next_sh() { bash "$RALPH_TOOL_DIR/ralph-next.sh" "$BATCH_DIR" "$@"; }

# ---------------------------------------------------------------------------
# The exec adapter: everything about where the agent runs and how its commits get here.
# Loaded once, after `say`/`warn` exist so the adapter can print through them.
# ---------------------------------------------------------------------------
# shellcheck source=ralph-exec.sh
source "$RALPH_TOOL_DIR/ralph-exec.sh" || exit 1
ralph_exec_load "$RALPH_EXEC" || exit 1

# ---------------------------------------------------------------------------
# Status / dry-run modes exit before anything is spent
# ---------------------------------------------------------------------------
progress_line() {
  local counts
  counts=$(next_sh --count) || return 1
  say "Tickets done: ${counts% *} / ${counts#* }"
}

if [ "$MODE" = "status" ]; then
  say "Batch: $BATCH_DIR${RALPH_BATCH_NAME:+ ($RALPH_BATCH_NAME)}"
  progress_line || exit 1
  say ""
  if next_ticket=$(next_sh); then
    say "Next: $next_ticket"
    say ""
    say "Remaining, in order:"
    next_sh --list | nl -w3 -s'  '
  else
    say "Nothing left — every ticket in this batch is done."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight_failed=0

for tool in git node awk; do
  command -v "$tool" >/dev/null 2>&1 || { warn "preflight: '$tool' is not on PATH"; preflight_failed=1; }
done
# What this arrangement needs, asked of the adapter rather than decided here. Both are
# cheap and start nothing: the expensive setup is exec_prepare, further down, after the
# "nothing to do" check has had its say.
if [ "$MODE" = "run" ]; then
  exec_tool="$(exec_required_tool)"
  if [ -n "$exec_tool" ] && ! command -v "$exec_tool" >/dev/null 2>&1; then
    warn "preflight: '$exec_tool' is not on PATH (RALPH_EXEC=$RALPH_EXEC)"
    preflight_failed=1
  fi
  exec_preflight || preflight_failed=1
fi

[ -d "$BATCH_DIR" ] || { warn "preflight: no batch directory at $BATCH_DIR"; preflight_failed=1; }

# Validates every ticket path and fails loudly on a typo.
next_sh --count >/dev/null || preflight_failed=1

# A dirty tree poisons the per-iteration review base: BASE_REF is HEAD, so anything
# already modified gets reviewed as though this ticket wrote it.
if [ "$RALPH_ALLOW_DIRTY" != "1" ] && tree_is_dirty; then
  warn "preflight: the working tree is dirty. Commit or set aside first, so this"
  warn "           iteration's review sees only what this iteration wrote."
  warn "           Override with RALPH_ALLOW_DIRTY=1."
  git status --short >&2
  preflight_failed=1
fi

[ "$preflight_failed" -eq 0 ] || exit 1

next_ticket=$(next_sh)
pick_status=$?
if [ "$pick_status" -eq 1 ]; then
  say "Nothing to do — every ticket in $BATCH_DIR is already done."
  exit "$EXIT_DONE"
elif [ "$pick_status" -ne 0 ]; then
  exit 1
fi

if [ "$MODE" = "dry-run" ]; then
  say "Batch: $BATCH_DIR"
  progress_line
  say ""
  say "Would run, in this order:"
  next_sh --list | nl -w3 -s'  '
  say ""
  say "Exec:    $(exec_describe)"
  say "Model:   $RALPH_MODEL   Effort: $RALPH_EFFORT"
  say "Budgets: cost=$(budget_label "$MAX_COST" '$')  time=$(budget_label "$MAX_MINUTES" '' m)  iterations=$(budget_label "$MAX_ITERATIONS")"
  say "Logs:    $RUN_JSONL"
  say "         $RUN_LOG"
  say ""
  say "=== prompt that would be sent for $next_ticket ==="
  TICKET_FILE="$next_ticket"
  BASE_REF=$(git rev-parse HEAD)
  # shellcheck source=ralph-prompt.sh
  source "$RALPH_TOOL_DIR/ralph-prompt.sh"
  printf '%s\n' "$RALPH_PROMPT"
  say "=== end prompt (nothing was sent; no sandbox was started) ==="
  exit 0
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_COST="0.000000"
RUN_INPUT=0
RUN_OUTPUT=0
RUN_CACHE_READ=0
RUN_CACHE_WRITE=0
ITERATIONS_RUN=0
LANDED=0
SECONDS=0

VERDICT_FILE="$(mktemp)"
trap 'rm -f "$VERDICT_FILE"' EXIT

# Ctrl-C should end the run between iterations rather than half-way through one. The trap
# only raises a flag; the agent is a foreground child, so an interrupt during an iteration
# still kills it — but the flag means we record that iteration, write the footer, and stop
# instead of charging into the next ticket.
PAUSE_REQUESTED=0
PAUSE_REASON=""
on_interrupt() {
  PAUSE_REQUESTED=1
  PAUSE_REASON="interrupted (Ctrl-C)"
  warn ""
  warn "Interrupt received — finishing this iteration's bookkeeping, then pausing."
}
trap on_interrupt INT TERM

mkdir -p "$(dirname "$RUN_JSONL")" "$(dirname "$RUN_LOG")"
log_append ""
log_append "#############################################################################"
log_append "# run $RUN_ID started $RUN_STARTED_AT"
log_append "# batch=$BATCH_DIR exec=$RALPH_EXEC model=$RALPH_MODEL effort=$RALPH_EFFORT"
log_append "# budgets: cost=$(budget_label "$MAX_COST" '$') time=$(budget_label "$MAX_MINUTES" '' m) iterations=$(budget_label "$MAX_ITERATIONS")"
log_append "# head at start: $(git rev-parse HEAD)"
log_append "#############################################################################"

say "run $RUN_ID  ·  $BATCH_DIR  ·  $RALPH_EXEC  ·  model $RALPH_MODEL  ·  effort $RALPH_EFFORT"
progress_line
say ""

# Whatever this arrangement has to stand up before any money is spent — creating and
# checking the sandbox, running the batch's readiness probe — happens here, once, behind
# the adapter's own interface. `local` and `fake` have nothing to do.
exec_prepare || exit 1

FINAL_STATUS="$EXIT_DONE"
CURRENT_TICKET=""
ATTEMPTS_ON_CURRENT=0

while true; do
  if [ "$PAUSE_REQUESTED" -eq 1 ]; then
    FINAL_STATUS="$EXIT_PAUSED"
    break
  fi

  # Not `if ! TICKET_FILE=$(...)`: after a `!` negation bash reports the *inverted* status
  # in $?, so the "nothing left" case (exit 1) would read as 0 and be mistaken for a
  # crash. Capture the status on its own line.
  TICKET_FILE=$(next_sh)
  pick_status=$?
  if [ "$pick_status" -ne 0 ]; then
    if [ "$pick_status" -eq 1 ]; then
      say ""
      say "Every ticket in $BATCH_DIR is done."
      FINAL_STATUS="$EXIT_DONE"
    else
      warn "ralph-next.sh failed with status $pick_status"
      FINAL_STATUS=1
    fi
    break
  fi

  # Attempt accounting is per-run and per-ticket, held in memory on purpose. A ticket that
  # stalled is worth retrying after a deliberate pause — a fresh context often gets it —
  # but not worth retrying forever inside one run.
  if [ "$TICKET_FILE" != "$CURRENT_TICKET" ]; then
    CURRENT_TICKET="$TICKET_FILE"
    ATTEMPTS_ON_CURRENT=0
  fi
  ATTEMPTS_ON_CURRENT=$((ATTEMPTS_ON_CURRENT + 1))

  # --- budget checks, BEFORE spending anything on this iteration -------------
  if [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ITERATIONS_RUN" -ge "$MAX_ITERATIONS" ]; then
    PAUSE_REASON="iteration budget reached ($MAX_ITERATIONS)"
    FINAL_STATUS="$EXIT_PAUSED"
    break
  fi
  if fgt "$MAX_COST" 0 && fge "$RUN_COST" "$MAX_COST"; then
    PAUSE_REASON="cost budget reached (\$$RUN_COST of \$$MAX_COST)"
    FINAL_STATUS="$EXIT_PAUSED"
    break
  fi
  if [ "$MAX_MINUTES" -gt 0 ] && [ "$SECONDS" -ge $((MAX_MINUTES * 60)) ]; then
    PAUSE_REASON="time budget reached (${MAX_MINUTES}m)"
    FINAL_STATUS="$EXIT_PAUSED"
    break
  fi

  ITERATIONS_RUN=$((ITERATIONS_RUN + 1))
  BASE_REF=$(git rev-parse HEAD)
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  say "── iteration $ITERATIONS_RUN  ·  $TICKET_FILE$([ "$ATTEMPTS_ON_CURRENT" -gt 1 ] && printf ' (attempt %s)' "$ATTEMPTS_ON_CURRENT")"

  # Start the agent from exactly what we have. Cheap when already in sync, and it is what
  # makes a retry after a failed iteration a genuinely clean second attempt rather than a
  # second pass over the first one's leftovers. (Only the clone arrangement has anything
  # to do here; the adapter decides.)
  if ! exec_sync_down "$BASE_REF"; then
    FINAL_STATUS="$EXIT_NEEDS_HUMAN"
    break
  fi

  # shellcheck source=ralph-prompt.sh
  source "$RALPH_TOOL_DIR/ralph-prompt.sh"

  agent_status=0
  result=$(exec_run "$RALPH_PROMPT" "$TICKET_FILE") || agent_status=$?

  # Bring the iteration's commits back before inspecting anything: the ticket's Status
  # line, and every check below, lives in the work the agent just did. The adapter sets
  # EXEC_DIRTY and EXEC_AGENT_HEAD, and returns 1 only when work it cannot move is
  # stranded on the other side of the seam.
  sync_failed=0
  exec_collect "$BASE_REF" || sync_failed=1
  dirty="$EXEC_DIRTY"

  HEAD_REF=$(git rev-parse HEAD)
  flipped=0; ticket_is_done "$TICKET_FILE" && flipped=1

  # Truncate first: if the recorder dies, a stale verdict from the previous iteration
  # would otherwise be read as this one's and counted twice.
  : > "$VERDICT_FILE"

  # Always record, including on failure — a failed iteration is exactly the one worth
  # having in the log later.
  printf '%s' "$result" | node "$RALPH_TOOL_DIR/ralph-record.cjs" \
    --jsonl "$RUN_JSONL" --log "$RUN_LOG" --verdict "$VERDICT_FILE" \
    --run-id "$RUN_ID" --iteration "$ITERATIONS_RUN" --ticket "$TICKET_FILE" \
    --batch "$BATCH_DIR" \
    --base-ref "$BASE_REF" --head-ref "$HEAD_REF" --started-at "$STARTED_AT" \
    --exit-status "$agent_status" --tree-dirty "$dirty" --status-flipped "$flipped" \
    || warn "   note: could not record iteration $ITERATIONS_RUN (usage figures will read as zero)"

  iter_cost=$(verdict_get "$VERDICT_FILE" cost_usd)
  RUN_COST=$(fadd "$RUN_COST" "${iter_cost:-0}")
  RUN_INPUT=$((RUN_INPUT + $(verdict_num "$VERDICT_FILE" input_tokens)))
  RUN_OUTPUT=$((RUN_OUTPUT + $(verdict_num "$VERDICT_FILE" output_tokens)))
  RUN_CACHE_READ=$((RUN_CACHE_READ + $(verdict_num "$VERDICT_FILE" cache_read_tokens)))
  RUN_CACHE_WRITE=$((RUN_CACHE_WRITE + $(verdict_num "$VERDICT_FILE" cache_creation_tokens)))

  limit_hit=$(verdict_get "$VERDICT_FILE" limit_hit)
  limit_reset=$(verdict_get "$VERDICT_FILE" limit_reset)
  transient=$(verdict_get "$VERDICT_FILE" transient)

  # --- decide what happens next ---------------------------------------------

  # 1. A usage or billing limit. Pause immediately: every further iteration would fail the
  #    same way, and failing repeatedly is the one thing worse than stopping.
  if [ "$limit_hit" = "1" ]; then
    PAUSE_REASON="usage limit reached${limit_reset:+ · resets $limit_reset}"
    FINAL_STATUS="$EXIT_PAUSED"
    break
  fi

  if [ "$PAUSE_REQUESTED" -eq 1 ]; then
    FINAL_STATUS="$EXIT_PAUSED"
    break
  fi

  # 2. The commits could not be brought back. Stop immediately and do NOT sync down on a
  #    retry — the work only exists inside the sandbox now, and a retry would reset the
  #    clone over it.
  if [ "$sync_failed" -eq 1 ]; then
    warn ""
    exec_recovery_note "$BASE_REF"
    FINAL_STATUS="$EXIT_NEEDS_HUMAN"
    break
  fi

  # 3. The tree was left dirty. Never auto-commit: that would be committing work no one
  #    reviewed, under a ticket that may not have finished.
  if [ "$dirty" -eq 1 ]; then
    warn ""
    warn "$TICKET_FILE left uncommitted changes behind. Stopping so you can look."
    exec_show_dirty
    FINAL_STATUS="$EXIT_NEEDS_HUMAN"
    break
  fi

  # 4. The ticket landed.
  if [ "$flipped" -eq 1 ]; then
    LANDED=$((LANDED + 1))
    if [ "$HEAD_REF" = "$BASE_REF" ]; then
      warn "   note: status flipped but HEAD did not move — check $TICKET_FILE was committed"
    fi
    say "   ✓ landed  ·  $(git log -1 --format=%h "$HEAD_REF")"
    continue
  fi

  # 5. It did not land. Retry within the run only if there is an attempt left and the
  #    failure looked transient; otherwise stop rather than spend the budget watching the
  #    same ticket fail.
  if [ "$ATTEMPTS_ON_CURRENT" -lt "$TICKET_ATTEMPTS" ] && { [ "$transient" = "1" ] || [ "$agent_status" -ne 0 ]; }; then
    warn "   ✗ did not land (exit $agent_status). Retrying — attempt $((ATTEMPTS_ON_CURRENT + 1)) of $TICKET_ATTEMPTS."
    continue
  fi

  warn ""
  warn "$TICKET_FILE is still not '$RALPH_DONE_WORD' after $ATTEMPTS_ON_CURRENT attempt(s)."
  warn "Read the tail of $RUN_LOG and of $PROGRESS_FILE, then either fix it by hand or"
  warn "adjust the ticket. Rerun to continue from here."
  FINAL_STATUS="$EXIT_NEEDS_HUMAN"
  break
done

# ---------------------------------------------------------------------------
# Footer
# ---------------------------------------------------------------------------
trap - INT TERM

billed=$((RUN_INPUT + RUN_OUTPUT))
elapsed_min=$((SECONDS / 60))

summary=$(cat <<EOF
iterations run:        $ITERATIONS_RUN
tickets landed:        $LANDED
elapsed:               ${elapsed_min}m
input tokens (billed): $RUN_INPUT
output tokens:         $RUN_OUTPUT
cache read tokens:     $RUN_CACHE_READ
cache write tokens:    $RUN_CACHE_WRITE
billed tokens total:   $billed
cost (USD, reported):  \$$RUN_COST
EOF
)

say ""
say "== run $RUN_ID  ·  $BATCH_DIR =="
say "$summary"

log_append ""
log_append "# ---- run $RUN_ID finished $(date -u +%Y-%m-%dT%H:%M:%SZ) ----"
while IFS= read -r line; do log_append "# $line"; done <<< "$summary"

case "$FINAL_STATUS" in
  "$EXIT_PAUSED")
    say ""
    say "PAUSED: ${PAUSE_REASON:-budget reached}"
    log_append "# paused: ${PAUSE_REASON:-budget reached}"
    if remaining=$(next_sh); then
      say "Next up:  $remaining"
      log_append "# next up: $remaining"
    fi
    if [ "$MAX_ITERATIONS" -gt 0 ]; then
      resume_args=" $MAX_ITERATIONS"
    else
      resume_args=" --unlimited"
    fi
    say "Resume:   $RALPH_INVOKE run $BATCH_DIR$resume_args"
    say "          (nothing to restore — the tickets' Status lines are the resume point)"
    ;;
  "$EXIT_NEEDS_HUMAN") log_append "# stopped: needs a human" ;;
  "$EXIT_DONE")        log_append "# complete" ;;
esac

log_append "#############################################################################"
say ""
say "Appended to $RUN_JSONL and $RUN_LOG"

exit "$FINAL_STATUS"
