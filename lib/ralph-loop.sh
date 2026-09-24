#!/bin/bash
#
# Ralph: one ticket per iteration.
#
#   ralph run     <batch>              # run one iteration
#   ralph run     <batch> 5            # run at most 5 iterations
#   ralph run     <batch> --unlimited  # run until done or a budget stops it
#   ralph run     <batch> --live       # show what the agent is doing, as it does it
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
#   The one exception is a stall the checkpoint turn could not salvage, which leaves a
#   disposable marker (.ralph-stall-marker) in the batch directory. A rerun that finds the
#   tree dirty and the marker matching runs a checkpoint turn before syncing; anything else
#   refuses to sync. Deleting the marker only costs that rescue. See "The stall marker".
#
# BUDGETS (all optional; 0 or unset means no limit)
#   RALPH_MAX_COST_USD=25     pause before an iteration that would take the run over $25
#   RALPH_MAX_MINUTES=180     pause before an iteration once 180 minutes have elapsed
#   <iterations> argument     pause after this many iterations (default: 1)
#   --unlimited               no iteration cap; only cost/time budgets stop it
#
# OTHER KNOBS (all settable in ralph.conf; the environment wins over it)
#   RALPH_MODEL=claude-sonnet-5    RALPH_EFFORT=high
#   RALPH_TICKET_ATTEMPTS=2        unproductive tries per ticket in one run before stopping
#   RALPH_MAX_CONTINUATIONS=5      consecutive iterations that may commit progress on one
#                                  ticket without landing it before stopping for a human
#   RALPH_CONTEXT_BUDGET_TOKENS=200000   what the prompt tells the agent to work inside
#   RALPH_ALLOW_DIRTY=1            skip the clean-tree preflight (not the per-iteration
#                                  refusal to sync over a dirty tree — that one has no
#                                  override, on purpose: it is what makes a rerun safe)
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
    # Exported rather than set, so it lands in ralph-config.sh's environment snapshot and
    # beats a RALPH_STREAM in the batch's ralph.conf — the same precedence every other knob
    # has. It has to be a real flag: the parser below rejects any unknown `-*`.
    --live)      export RALPH_STREAM=1 ;;
    --help|-h)   show_help; exit 0 ;;
    -*)          echo "Usage: ${RALPH_INVOKE:-ralph} run [<batch>] [<iterations>|--unlimited] [--live]" >&2; exit 1 ;;
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
MAX_CONTINUATIONS="$RALPH_MAX_CONTINUATIONS"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# Bash has no floats. Every cost comparison and accumulation goes through awk.
fadd() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.6f", a + b }'; }
fsub() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.6f", a - b }'; }
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

# Adds one verdict file's cost and token figures into the run's running totals. Shared by
# the main turn and a checkpoint turn salvaging a stall — both spend real money, and the
# totals must never track only one of them.
accumulate_usage() {
  local verdict_file="$1" cost
  cost=$(verdict_get "$verdict_file" cost_usd)
  RUN_COST=$(fadd "$RUN_COST" "${cost:-0}")
  RUN_INPUT=$((RUN_INPUT + $(verdict_num "$verdict_file" input_tokens)))
  RUN_OUTPUT=$((RUN_OUTPUT + $(verdict_num "$verdict_file" output_tokens)))
  RUN_CACHE_READ=$((RUN_CACHE_READ + $(verdict_num "$verdict_file" cache_read_tokens)))
  RUN_CACHE_WRITE=$((RUN_CACHE_WRITE + $(verdict_num "$verdict_file" cache_creation_tokens)))
}

# Shared by a deliberate handoff and a stall a checkpoint turn salvaged: both feed the one
# continuation cap (RALPH_MAX_CONTINUATIONS), because a ticket that alternates between the
# two shapes of "committed but not landed" must still be bounded by a single number. Prints
# the stop and returns 0 once the cap is reached; returns 1 (nothing printed) otherwise.
#
# The message says "needed N extra turns" rather than "has progressed N times": a ticket
# that stalls repeatedly reaches this cap without ever progressing deliberately. The
# breakdown of how many were which comes from STALLS_ON_CURRENT — display and telemetry
# only, never a budget of its own (CONTEXT.md's "Stall count").
continuation_cap_reached() {
  [ "$MAX_CONTINUATIONS" -gt 0 ] && [ "$CONTINUATIONS_ON_CURRENT" -ge "$MAX_CONTINUATIONS" ] || return 1
  local progressed_count=$((CONTINUATIONS_ON_CURRENT - STALLS_ON_CURRENT))
  warn ""
  warn "$TICKET_FILE has needed $CONTINUATIONS_ON_CURRENT extra turns without landing ($progressed_count progressed, $STALLS_ON_CURRENT stalled)."
  warn "Like running out of context, that is a size problem rather than something a further"
  warn "attempt fixes — split it into smaller tickets rather than rerunning as-is. Every chunk"
  warn "is committed; nothing has been lost, and $PROGRESS_FILE says where it got to."
  return 0
}

# A checkpoint turn is a short salvage, not a second attempt at the ticket, so it is kept
# narrow by its prompt plus this low turn limit rather than by a tool allowlist — both sbx
# adapters default to a permission mode that bypasses the gate, where an allowlist plausibly
# does not bite at all. Not a ralph.conf knob on purpose: see
# docs/adr/0001-checkpoint-turn-over-session-resume.md.
CHECKPOINT_MAX_TURNS=6

# 0 means "no limit" for every budget, which reads badly printed bare.
budget_label() {
  local value="$1" prefix="${2:-}" suffix="${3:-}"
  if fgt "$value" 0; then printf '%s%s%s' "$prefix" "$value" "$suffix"; else printf 'unlimited'; fi
}

tree_is_dirty() { [ -n "$(git status --porcelain)" ]; }
ticket_is_done() { grep -q "$RALPH_DONE_PATTERN" "$1"; }

# ---------------------------------------------------------------------------
# Marking a finished ticket's file
#
# A landed ticket whose checklist is fully ticked is renamed to ${RALPH_DONE_PREFIX}<name>
# and the rename committed, so a directory listing shows what is finished. Both halves of
# "complete" are required: the status line says the agent believes it is done, the boxes say
# what it actually checked off. A ticket with the one and not the other keeps its name.
# A ticket with no checkboxes has none unticked. Renamed by the LOOP rather than asked of
# the agent: the loop is about to re-read the ticket by its path, and a rename is exactly
# the sort of thing that goes wrong quietly inside a turn.
#
# Never fatal. The ticket has landed either way; a failed rename only costs the prefix, and
# a failed commit is undone so the tree is not left dirty for the next iteration to trip on.
# ---------------------------------------------------------------------------
ticket_has_unchecked_boxes() { grep -q '^[[:space:]]*[-*+][[:space:]][[:space:]]*\[ \]' "$1"; }

mark_ticket_done_on_disk() {    # mark_ticket_done_on_disk TICKET
  local ticket="$1" base renamed
  [ -n "$RALPH_DONE_PREFIX" ] || return 0
  base="$(basename "$ticket")"
  case "$base" in "$RALPH_DONE_PREFIX"*) return 0 ;; esac
  [ -f "$ticket" ] && ticket_is_done "$ticket" || return 0

  if ticket_has_unchecked_boxes "$ticket"; then
    warn "   note: $ticket is '$RALPH_DONE_WORD' but has unchecked boxes — leaving its name alone"
    return 0
  fi

  renamed="$(dirname "$ticket")/$RALPH_DONE_PREFIX$base"
  if [ -e "$renamed" ]; then
    warn "   note: $renamed already exists — not renaming $ticket"
    return 0
  fi

  if ! git mv -- "$ticket" "$renamed" 2>/dev/null; then
    warn "   note: could not rename $ticket (is it tracked?) — leaving it as is"
    return 0
  fi
  # Only the two paths: a bare `git commit` would sweep up anything else staged, which
  # RALPH_ALLOW_DIRTY makes possible.
  if ! git commit --quiet -m "chore: mark $base done" -- "$ticket" "$renamed" >/dev/null 2>&1; then
    git mv -- "$renamed" "$ticket" >/dev/null 2>&1
    warn "   note: could not commit the rename of $ticket — left it as is"
    return 0
  fi
  say "   ✓ marked done  ·  $renamed"
}

next_sh() { bash "$RALPH_TOOL_DIR/ralph-next.sh" "$BATCH_DIR" "$@"; }

# ---------------------------------------------------------------------------
# The stall marker
#
# "Just rerun it" is only true if a rerun can rescue the tree a stall left behind, and at
# the start of a run nobody knows who left it dirty: the sandbox is per REPOSITORY, so
# several batches share one clone, and a human may have a session in it too. Committing
# that blind, under whatever ticket this run happened to pick first, is exactly the
# unreviewed commit the loop has always refused. So the rescue is gated on proof the loop
# wrote itself — a file in the batch directory, recording the ticket, the base ref and the
# sandbox at the moment a stall was left unsalvaged (`key=value` lines, never eval'd).
#
# Deliberately a disposable file, not state: its absence, or any mismatch, always degrades
# to the safe path (refuse to sync, print the recovery note), so deleting it by hand costs
# only the automatic rescue. It bends the toolkit's no-state rule the same way the batch's
# bundle file does — one file in the batch directory, never a registry.
# ---------------------------------------------------------------------------
stall_marker_get() {
  local line
  line=$(grep -m1 "^$1=" "$STALL_MARKER_FILE" 2>/dev/null) || { printf '%s' ''; return; }
  printf '%s' "${line#*=}"
}

write_stall_marker() {    # write_stall_marker TICKET BASE
  printf 'ticket=%s\nbase_ref=%s\nsandbox=%s\n' "$1" "$2" "$RALPH_SANDBOX" > "$STALL_MARKER_FILE" ||
    warn "   note: could not record the stall, so a rerun will refuse rather than rescue it"
}

# Does the marker vouch for the tree this run is about to find, for TICKET? All three must
# agree: the sandbox (one marker must never be trusted in another sandbox's clone), the ref
# the stalled turn started from (HEAD has not moved since, so nothing else has landed on
# top of the stall), and the ticket this run is about to work on.
stall_marker_matches() {    # stall_marker_matches TICKET
  [ -f "$STALL_MARKER_FILE" ] || return 1
  [ -n "$1" ] || return 1
  [ "$(stall_marker_get sandbox)" = "$RALPH_SANDBOX" ] || return 1
  [ "$(stall_marker_get base_ref)" = "$(git rev-parse HEAD)" ] || return 1
  [ "$(stall_marker_get ticket)" = "$1" ]
}

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
#
# Not when the stall marker vouches for it: that tree is about to be checkpointed before any
# iteration starts (see "Start of run" in the loop), so it is not the reviewer's problem.
if [ "$RALPH_ALLOW_DIRTY" != "1" ] && tree_is_dirty && ! stall_marker_matches "$(next_sh 2>/dev/null)"; then
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
  # The effective permission mode, which is a per-mode default unless the batch set one —
  # and the only place outside a real `claude` call where you can see which one won.
  say "Perms:   $RALPH_PERMISSION_MODE"
  # The other decision `fake` cannot exercise, for the same reason: it never invokes `claude`
  # and so never chooses an --output-format.
  if [ "$RALPH_STREAM" = "1" ]; then
    say "Live:    on (stream-json; file writes and shell commands drawn to stderr)"
  else
    say "Live:    off (json; add --live to watch the iteration)"
  fi
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
# Whether this run commissioned a checkpoint turn while the cost or time budget had
# ALREADY been reached — a budget is checked before an iteration starts, but a stall is
# only discovered after one, so the stalled turn itself can be what pushes the run past
# the budget the checkpoint turn then runs anyway (see ticket 06 /
# docs/adr/0001-checkpoint-turn-over-session-resume.md: a budget limits what to commission,
# not whether to keep work already paid for). Run-level, not per-ticket: the closing
# message reports it regardless of which ticket triggered it.
SALVAGED_OVER_COST=0
SALVAGED_OVER_TIME=0

VERDICT_FILE="$(mktemp)"
# The agent's payload, on its way from exec_run to the recorder. It goes through a file
# because exec_run is now the head of a pipeline rather than a command substitution — see
# the call site for why that matters.
PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "$VERDICT_FILE" "$PAYLOAD_FILE"' EXIT

# The one thing that differs between a plain run and a watched one, on this side of the
# seam. ralph-stream.cjs is in the pipeline either way — in plain mode it is a pass-through
# — so there is one code path here rather than two.
STREAM_ARGS=()
[ "$RALPH_STREAM" = "1" ] && STREAM_ARGS=(--live)

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
# Whether the PREVIOUS attempt on the current ticket ran out of context. A boolean, held
# in memory beside the attempt count: the next attempt is told that it happened, never
# what the failed one said. There is no narrative here to anchor a retry on a wrong
# approach, and nothing self-reported to have to trust.
PREV_CONTEXT_EXHAUSTED=0
# How many consecutive iterations have committed progress on the current ticket without
# landing it, and the HEAD this ticket was FIRST attempted from. The second is what the
# landing iteration is asked to review against, so a ticket that took three passes is
# reviewed as one diff rather than three unrelated slices.
CONTINUATIONS_ON_CURRENT=0
TICKET_BASE_REF=""
# How many of THIS ticket's continuations were stalls a checkpoint turn salvaged, rather
# than a deliberate handoff. Display and telemetry only (CONTEXT.md's "Stall count") — it
# has no budget of its own; both shapes are bounded by CONTINUATIONS_ON_CURRENT alone.
STALLS_ON_CURRENT=0
# Whether the MOST RECENT continuation on the current ticket was a stall a checkpoint turn
# salvaged, rather than a deliberate handoff. Unlike STALLS_ON_CURRENT (a running count),
# this only ever describes the last one — a ticket that stalled once and then handed off
# deliberately is not told the second time that its handoff was reconstructed.
LAST_CONTINUATION_STALLED=0
# Whether the start-of-run check of the stall marker has happened yet. It happens once, before
# the first sync of the run, and never again: after that, the loop itself is the only thing
# that can have left the tree dirty, and it stops rather than iterate over one.
START_OF_RUN_CHECKED=0
# Set when a marker was found beside a dirty tree it does not vouch for, so the refusal can
# say why no rescue was attempted rather than leaving the operator to guess.
STALL_MARKER_UNTRUSTED=0

# What to say when a checkpoint turn left the tree clean without committing. Said the same
# way wherever it happens: nothing is left to point a recovery note at.
checkpoint_discarded_note() {
  warn ""
  warn "$TICKET_FILE's uncommitted work is gone: the checkpoint turn left the tree clean"
  warn "without ever committing anything. There is nothing to recover — the work will"
  warn "need to be redone, not salvaged."
}

# Runs one checkpoint turn for TICKET_FILE against BASE_REF and reports how it went in
# CHECKPOINT_OUTCOME, leaving HEAD_REF and EXEC_DIRTY as it found them afterwards. What to
# SAY about each outcome, and what it means for the run, is the caller's — a stall found
# mid-run and one found at the start of the next run react differently.
#
#   salvaged   the work is committed and the tree is clean
#   stranded   the commit could not be brought back from the other side of the seam
#   discarded  the tree came back clean without a commit — the diff is gone
#   failed     the work is still uncommitted
#
# Its cost is added to the run total and it is recorded as its own row whatever the outcome:
# the money was spent either way.
run_checkpoint_turn() {
  # ralph-prompt.sh defines ralph_checkpoint_prompt; the loop sources it per iteration, so
  # before the first iteration it has not been loaded yet.
  if ! declare -F ralph_checkpoint_prompt >/dev/null 2>&1; then
    # shellcheck source=ralph-prompt.sh
    source "$RALPH_TOOL_DIR/ralph-prompt.sh"
  fi

  # Deliberately NOT preceded by exec_sync_down. exec_run and exec_sync_down are already
  # separate calls in this seam, so "run the agent without syncing first" needs no new
  # adapter function — three of the four adapters have a no-op exec_sync_down anyway.
  local checkpoint_prompt checkpoint_started_at checkpoint_agent_status checkpoint_result
  local checkpoint_sync_failed=0
  local -a checkpoint_args_saved
  checkpoint_prompt="$(ralph_checkpoint_prompt "$TICKET_FILE" "$BASE_REF")"
  checkpoint_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Guarded expansion, same as RALPH_CLAUDE_ARGS's other two call sites (local.sh,
  # _sbx.sh): under bash < 4.4 and `set -u`, expanding an array that is declared but
  # empty still raises "unbound variable" without the `+` guard.
  checkpoint_args_saved=(${RALPH_CLAUDE_ARGS+"${RALPH_CLAUDE_ARGS[@]}"})
  RALPH_CLAUDE_ARGS+=(--max-turns "$CHECKPOINT_MAX_TURNS")
  exec_run "$checkpoint_prompt" "$TICKET_FILE" |
    node "$RALPH_TOOL_DIR/ralph-stream.cjs" ${STREAM_ARGS+"${STREAM_ARGS[@]}"} > "$PAYLOAD_FILE"
  checkpoint_agent_status=${PIPESTATUS[0]}
  checkpoint_result=$(cat "$PAYLOAD_FILE")
  RALPH_CLAUDE_ARGS=(${checkpoint_args_saved+"${checkpoint_args_saved[@]}"})

  # Bring back whatever the checkpoint turn committed (only the clone-based sandbox has
  # any transporting to do here) and see whether it actually rescued the work.
  exec_collect "$BASE_REF" || checkpoint_sync_failed=1
  HEAD_REF=$(git rev-parse HEAD)

  # Recorded as its OWN row (kind=checkpoint), never folded into the iteration it
  # salvaged — so per-iteration cost/duration figures are not distorted by a second turn
  # hidden inside them, and a human reading the log can tell the two apart.
  : > "$VERDICT_FILE"
  printf '%s' "$checkpoint_result" | node "$RALPH_TOOL_DIR/ralph-record.cjs" \
    --jsonl "$RUN_JSONL" --log "$RUN_LOG" --verdict "$VERDICT_FILE" \
    --run-id "$RUN_ID" --iteration "$ITERATIONS_RUN" --ticket "$TICKET_FILE" \
    --batch "$BATCH_DIR" --kind checkpoint \
    --base-ref "$BASE_REF" --head-ref "$HEAD_REF" --started-at "$checkpoint_started_at" \
    --exit-status "$checkpoint_agent_status" --tree-dirty "$EXEC_DIRTY" --status-flipped 0 \
    || warn "   note: could not record the checkpoint turn (usage figures will read as zero)"

  accumulate_usage "$VERDICT_FILE"

  if [ "$checkpoint_sync_failed" -eq 1 ]; then
    CHECKPOINT_OUTCOME=stranded
  elif [ "$EXEC_DIRTY" -eq 0 ] && [ "$HEAD_REF" != "$BASE_REF" ]; then
    CHECKPOINT_OUTCOME=salvaged
  elif [ "$EXEC_DIRTY" -eq 0 ]; then
    CHECKPOINT_OUTCOME=discarded
  else
    CHECKPOINT_OUTCOME=failed
  fi
}

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
    PREV_CONTEXT_EXHAUSTED=0
    CONTINUATIONS_ON_CURRENT=0
    TICKET_BASE_REF=""
    STALLS_ON_CURRENT=0
    LAST_CONTINUATION_STALLED=0
  fi

  # --- start of run: is the tree a previous run's unsalvaged stall? ------------
  # Before the first sync of the run, and before any budget check: what is being rescued was
  # paid for by an earlier run, and a budget limits what to commission, not whether to keep
  # work already paid for. exec_tree_dirty is ticket 02's read-only question, so asking it
  # here moves nothing.
  if [ "$START_OF_RUN_CHECKED" -eq 0 ]; then
    START_OF_RUN_CHECKED=1
    if [ -e "$STALL_MARKER_FILE" ]; then
      if ! exec_tree_dirty; then
        # Clean: someone rescued it by hand, or nothing was ever there. Either way the
        # marker no longer vouches for anything.
        rm -f "$STALL_MARKER_FILE"
      elif stall_marker_matches "$TICKET_FILE"; then
        BASE_REF=$(git rev-parse HEAD)
        stalled_from="$BASE_REF"
        # Gone before the checkpoint turn runs, not after it succeeds: in a repo that has not
        # ignored it, `git add -A` would sweep the marker into the very commit that is meant
        # to hold only the ticket's work. A rescue that fails writes it again.
        rm -f "$STALL_MARKER_FILE"

        say "── found $TICKET_FILE's stalled work from an earlier run, still uncommitted"
        warn "The earlier run stopped on a stall the checkpoint turn could not salvage, and"
        warn "left a marker vouching for this tree. Running a checkpoint turn to commit it"
        warn "before syncing, rather than resetting over it."
        exec_show_dirty

        run_checkpoint_turn

        case "$CHECKPOINT_OUTCOME" in
          salvaged)
            # Exactly what the same rescue mid-run would have recorded: the ticket is now a
            # continuation of a stall, reviewed from the commit the stall began at.
            say "   ⋯ stalled, salvaged by a checkpoint turn  ·  $(git log -1 --format=%h "$HEAD_REF")"
            CONTINUATIONS_ON_CURRENT=$((CONTINUATIONS_ON_CURRENT + 1))
            STALLS_ON_CURRENT=$((STALLS_ON_CURRENT + 1))
            LAST_CONTINUATION_STALLED=1
            ATTEMPTS_ON_CURRENT=0
            TICKET_BASE_REF="$stalled_from"
            say ""
            ;;
          stranded)
            warn ""
            exec_recovery_note "$BASE_REF"
            FINAL_STATUS="$EXIT_NEEDS_HUMAN"
            break
            ;;
          discarded)
            checkpoint_discarded_note
            FINAL_STATUS="$EXIT_NEEDS_HUMAN"
            break
            ;;
          *)
            write_stall_marker "$TICKET_FILE" "$BASE_REF"
            warn ""
            warn "The checkpoint turn could not commit $TICKET_FILE's stalled work either."
            warn "Stopping so you can look."
            exec_show_dirty
            exec_dirty_recovery_note "$BASE_REF" "$TICKET_FILE" "$BATCH_DIR" >&2
            FINAL_STATUS="$EXIT_NEEDS_HUMAN"
            break
            ;;
        esac
      else
        # Dirty, and the marker does not vouch for it: another batch's stall, a stall from
        # before HEAD moved, or a human's own work. Nothing here proves it is this ticket's,
        # so the refusal below applies, exactly as if there were no marker.
        STALL_MARKER_UNTRUSTED=1
      fi
    fi
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
  [ -n "$TICKET_BASE_REF" ] || TICKET_BASE_REF="$BASE_REF"
  STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  say "── iteration $ITERATIONS_RUN  ·  $TICKET_FILE$([ "$ATTEMPTS_ON_CURRENT" -gt 1 ] && printf ' (attempt %s)' "$ATTEMPTS_ON_CURRENT")"

  # Ask before touching anything: on the clone-based sandbox, syncing is a hard reset plus
  # a wipe of untracked files, and rerunning is the most natural response to any stop there
  # is. Refuse rather than destroy work nobody has looked at yet.
  if exec_tree_dirty; then
    warn ""
    warn "The agent's tree already has uncommitted changes in it. Refusing to sync over them."
    if [ "$STALL_MARKER_UNTRUSTED" -eq 1 ]; then
      warn "(A stall marker was found, but it does not match this tree — a different sandbox,"
      warn "commit or ticket — so nothing here can be shown to be $TICKET_FILE's own.)"
    fi
    exec_show_dirty
    warn ""
    warn "If the changes look sound, keep them as a checkpoint and rerun to continue:"
    exec_dirty_recovery_note "$BASE_REF" "$TICKET_FILE" "$BATCH_DIR" >&2
    FINAL_STATUS="$EXIT_NEEDS_HUMAN"
    break
  fi

  # Start the agent from exactly what we have. Cheap when already in sync, and it is what
  # makes a retry after a failed iteration a genuinely clean second attempt rather than a
  # second pass over the first one's leftovers. (Only the clone arrangement has anything
  # to do here; the adapter decides.)
  if ! exec_sync_down "$BASE_REF"; then
    FINAL_STATUS="$EXIT_NEEDS_HUMAN"
    break
  fi

  # A previous attempt on THIS ticket ran out of context. Say so — working smaller is the
  # one change that might make the difference on a second pass, and a fresh context on its
  # own will not produce it.
  RALPH_CONTEXT_RETRY=0
  [ "$ATTEMPTS_ON_CURRENT" -gt 1 ] && [ "$PREV_CONTEXT_EXHAUSTED" = "1" ] && RALPH_CONTEXT_RETRY=1

  # A previous iteration handed this ticket off part-finished. Tell the prompt, and give it
  # the ticket's own first base to review against rather than this iteration's.
  RALPH_CONTINUATION=0
  [ "$CONTINUATIONS_ON_CURRENT" -gt 0 ] && RALPH_CONTINUATION=1

  # That handoff was a checkpoint turn salvaging a stall, not a deliberate one: the
  # `Remaining:` list it wrote was reconstructed from the diff by a turn that never saw the
  # reasoning behind it, and the turn that produced the diff ran out of room. Say both.
  RALPH_STALL_CONTINUATION=0
  [ "$RALPH_CONTINUATION" = "1" ] && [ "$LAST_CONTINUATION_STALLED" = "1" ] && RALPH_STALL_CONTINUATION=1

  RALPH_REVIEW_BASE="$TICKET_BASE_REF"

  # shellcheck source=ralph-prompt.sh
  source "$RALPH_TOOL_DIR/ralph-prompt.sh"

  # `${PIPESTATUS[0]}` is load-bearing: `set -o pipefail` is on, so a plain `$?` here would
  # conflate the filter's status with the agent's, and every branch below turns on the
  # agent's. Everything after these three lines — the recorder call, the verdict, the branch
  # order — is untouched by whether the run is being watched.
  exec_run "$RALPH_PROMPT" "$TICKET_FILE" |
    node "$RALPH_TOOL_DIR/ralph-stream.cjs" ${STREAM_ARGS+"${STREAM_ARGS[@]}"} > "$PAYLOAD_FILE"
  agent_status=${PIPESTATUS[0]}
  result=$(cat "$PAYLOAD_FILE")

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

  accumulate_usage "$VERDICT_FILE"

  limit_hit=$(verdict_get "$VERDICT_FILE" limit_hit)
  limit_reset=$(verdict_get "$VERDICT_FILE" limit_reset)
  transient=$(verdict_get "$VERDICT_FILE" transient)
  parse_ok=$(verdict_get "$VERDICT_FILE" parse_ok)
  context_exhausted=$(verdict_get "$VERDICT_FILE" context_exhausted)
  permission_denied=$(verdict_get "$VERDICT_FILE" permission_denied)
  is_error=$(verdict_get "$VERDICT_FILE" is_error)
  PREV_CONTEXT_EXHAUSTED="${context_exhausted:-0}"

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

  # 3. A tool call was denied for want of permission. This has to be decided ABOVE the
  #    dirty-tree branch: the denial is usually `git commit` itself, so the tree is dirty as
  #    a CONSEQUENCE, and letting that branch win means the terminal reports the symptom and
  #    never names the cause. Retrying is pointless — the next iteration is configured
  #    identically and will be denied identically — so stop and say what to change.
  if [ "$permission_denied" = "1" ]; then
    warn ""
    warn "$TICKET_FILE was stopped by a permission denial, not by its own work."
    warn "\`claude --print\` has no one to approve a tool call, so anything outside the"
    warn "allowlist is denied outright — including the \`git commit\` this prompt asks for,"
    warn "after the ticket's work has been done and paid for."
    warn ""
    warn "Add this line to $RALPH_CONF, then rerun:"
    warn "  RALPH_CLAUDE_ARGS=(--allowed-tools \"Bash(git add:*)\" \"Bash(git commit:*)\")"
    warn "(Or set RALPH_PERMISSION_MODE=bypassPermissions there if you want no gate at all.)"
    exec_show_dirty
    FINAL_STATUS="$EXIT_NEEDS_HUMAN"
    break
  fi

  # 4. The tree was left dirty. Never auto-commit: that would be committing work no one
  #    reviewed, under a ticket that may not have finished.
  if [ "$dirty" -eq 1 ]; then
    # A STALL: the turn ended cleanly, nothing reported an error, the ticket is unflipped,
    # and HEAD never moved — the exact signature of a turn that ran out of room before
    # reaching its own checkpoint step (prompt step 5), rather than one that failed.
    # Salvage it with a checkpoint turn: a short, single-purpose turn that commits the diff
    # as `wip:` and hands off, converting the stall into a progression the loop already
    # knows how to continue. See docs/adr/0001-checkpoint-turn-over-session-resume.md.
    if [ "$agent_status" -eq 0 ] && [ "$is_error" != "1" ] && [ "$flipped" -eq 0 ] &&
       [ "$HEAD_REF" = "$BASE_REF" ]; then
      # The stalled turn just run is itself what may have pushed the run past a budget —
      # discovering a stall is only possible AFTER the turn that stalled, so the budget
      # check that gated its start could not have known. Note it (using the same tests as
      # the top-of-loop check) before committing to the checkpoint turn anyway: the budget
      # limits what to commission, not whether to keep work already paid for.
      if fgt "$MAX_COST" 0 && fge "$RUN_COST" "$MAX_COST"; then SALVAGED_OVER_COST=1; fi
      if [ "$MAX_MINUTES" -gt 0 ] && [ "$SECONDS" -ge $((MAX_MINUTES * 60)) ]; then
        SALVAGED_OVER_TIME=1
      fi

      warn ""
      warn "$TICKET_FILE stalled: the turn ended cleanly with its work uncommitted, as though"
      warn "it ran out of room before reaching its own checkpoint step. Running a checkpoint"
      warn "turn to commit what is there, rather than stopping."
      exec_show_dirty

      run_checkpoint_turn

      case "$CHECKPOINT_OUTCOME" in
        stranded)
          warn ""
          exec_recovery_note "$BASE_REF"
          FINAL_STATUS="$EXIT_NEEDS_HUMAN"
          break
          ;;
        salvaged)
          say "   ⋯ stalled, salvaged by a checkpoint turn  ·  $(git log -1 --format=%h "$HEAD_REF")"
          CONTINUATIONS_ON_CURRENT=$((CONTINUATIONS_ON_CURRENT + 1))
          STALLS_ON_CURRENT=$((STALLS_ON_CURRENT + 1))
          LAST_CONTINUATION_STALLED=1
          ATTEMPTS_ON_CURRENT=0
          if continuation_cap_reached; then
            FINAL_STATUS="$EXIT_NEEDS_HUMAN"
            break
          fi
          continue
          ;;
        discarded)
          # The tree WAS dirty going into this turn — that is how the stall was detected —
          # and came back clean with HEAD still unmoved. Doing nothing would have left it
          # exactly as dirty as before, so something discarded the diff instead of committing
          # it. There is nothing left to point a recovery note at — and nothing for a marker
          # to vouch for.
          checkpoint_discarded_note
          FINAL_STATUS="$EXIT_NEEDS_HUMAN"
          break
          ;;
      esac

      # The checkpoint turn could not commit it either. This leaves the run exactly where
      # it would have been without the attempt: stopped for a human, with the same
      # adapter-correct recovery note the original stall would have printed.
      #
      # And it is the one moment the loop can say, for a later run to rely on, that this
      # dirty tree is its own unfinished business — see "The stall marker" above.
      write_stall_marker "$TICKET_FILE" "$BASE_REF"
      warn ""
      warn "$TICKET_FILE left uncommitted changes behind, and the checkpoint turn could not"
      warn "commit them either. Stopping so you can look."
      exec_show_dirty
      exec_dirty_recovery_note "$BASE_REF" "$TICKET_FILE" "$BATCH_DIR" >&2
      FINAL_STATUS="$EXIT_NEEDS_HUMAN"
      break
    fi

    # Dirty for some other reason — not the stall's exact signature (an error was reported,
    # the ticket flipped anyway, or HEAD moved but something was still left uncommitted). No
    # checkpoint turn: it exists only for the stall it was built for. Stop, as always.
    warn ""
    warn "$TICKET_FILE left uncommitted changes behind. Stopping so you can look."
    exec_show_dirty
    FINAL_STATUS="$EXIT_NEEDS_HUMAN"
    break
  fi

  # 5. The ticket landed.
  if [ "$flipped" -eq 1 ]; then
    LANDED=$((LANDED + 1))
    if [ "$HEAD_REF" = "$BASE_REF" ]; then
      warn "   note: status flipped but HEAD did not move — check $TICKET_FILE was committed"
    fi
    say "   ✓ landed  ·  $(git log -1 --format=%h "$HEAD_REF")"
    mark_ticket_done_on_disk "$TICKET_FILE"
    continue
  fi

  # 6. It did not land, but HEAD moved and nothing reported an error: the agent committed a
  #    checkpoint and handed the rest off (prompt step 5). `claude --print` is ONE turn, and
  #    a ticket whose work exceeds that turn's output budget ends exactly like this — exit
  #    0, subtype success, no error anywhere, the deliverable half-written. That is progress,
  #    not a failure, so continue on the SAME ticket instead of falling through to the stop
  #    below and making the next run start the work from scratch.
  #
  #    The attempt counter is RESET rather than spent: it counts unproductive attempts, which
  #    is what it was always for, and burning a ticket's retry budget for making progress is
  #    backwards. The continuation cap is what keeps this from looping forever.
  if [ "$HEAD_REF" != "$BASE_REF" ] && [ "$agent_status" -eq 0 ] && [ "$is_error" != "1" ]; then
    CONTINUATIONS_ON_CURRENT=$((CONTINUATIONS_ON_CURRENT + 1))
    LAST_CONTINUATION_STALLED=0
    ATTEMPTS_ON_CURRENT=0
    say "   ⋯ progressed  ·  $(git log -1 --format=%h "$HEAD_REF")"

    if continuation_cap_reached; then
      FINAL_STATUS="$EXIT_NEEDS_HUMAN"
      break
    fi
    continue
  fi

  # 7. It did not land. Retry within the run only if there is an attempt left and the
  #    failure is one a second attempt could plausibly survive; otherwise stop rather than
  #    spend the budget watching the same ticket fail the same way.
  #
  #    Three cases qualify, and the distinctions matter:
  #      - transient: the model was briefly unavailable. The classic retry.
  #      - context exhausted: the conversation outgrew the window. Deliberately NOT gated
  #        on parse_ok — an overflow often kills the CLI before it emits any JSON, and that
  #        is exactly the case a fresh context might carry. The retry is told about it.
  #      - a non-zero exit from a run that DID produce a parseable payload: the CLI got far
  #        enough to report, so the failure is a described one rather than a crash.
  #    A crash with no payload and neither signal is not retried: nothing distinguishes it
  #    from a genuine logic failure, and blind second attempts at those cost a full
  #    iteration to learn nothing.
  if [ "$ATTEMPTS_ON_CURRENT" -lt "$TICKET_ATTEMPTS" ] &&
     { [ "$transient" = "1" ] || [ "$context_exhausted" = "1" ] ||
       { [ "$agent_status" -ne 0 ] && [ "$parse_ok" = "1" ]; }; }; then
    warn "   ✗ did not land (exit $agent_status)$([ "$context_exhausted" = "1" ] && printf ', out of context')."
    warn "     Retrying — attempt $((ATTEMPTS_ON_CURRENT + 1)) of $TICKET_ATTEMPTS."
    continue
  fi

  warn ""
  if [ "$context_exhausted" = "1" ]; then
    # A second blind retry cannot fix a structural size mismatch, so say what it is rather
    # than leaving it to be re-derived from the log.
    warn "$TICKET_FILE ran out of context on its last attempt. That usually means the ticket is"
    warn "too large for one iteration — split it into smaller tickets rather than rerunning as-is."
  else
    warn "$TICKET_FILE is still not '$RALPH_DONE_WORD' after $ATTEMPTS_ON_CURRENT attempt(s)."
  fi
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

# Reported unconditionally on FINAL_STATUS: a budget reached mid-salvage can still end the
# run EXIT_DONE (the ticket that stalled was the batch's last) rather than EXIT_PAUSED, and
# the overshoot happened either way. Staying silent here is exactly the promise-breaking
# silence ticket 06 exists to close.
if [ "$SALVAGED_OVER_COST" -eq 1 ] || [ "$SALVAGED_OVER_TIME" -eq 1 ]; then
  overshoot_note="Note: a budget was overshot to salvage stalled work — a checkpoint turn ran"
  overshoot_note2="anyway rather than leave already-paid-for work stranded uncommitted."
  say ""
  say "$overshoot_note"
  say "$overshoot_note2"
  log_append "# $overshoot_note"
  log_append "# $overshoot_note2"
  if [ "$SALVAGED_OVER_COST" -eq 1 ]; then
    cost_over=$(fsub "$RUN_COST" "$MAX_COST")
    line="  cost: \$$RUN_COST of \$$MAX_COST budget (over by \$$cost_over)"
    say "$line"
    log_append "# $line"
  fi
  if [ "$SALVAGED_OVER_TIME" -eq 1 ]; then
    line="  time: ${elapsed_min}m of ${MAX_MINUTES}m budget (over by $((elapsed_min - MAX_MINUTES))m)"
    say "$line"
    log_append "# $line"
  fi
fi

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
