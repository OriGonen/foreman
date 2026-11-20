#!/bin/bash
# foreman dry-run: the plan and the prompt that would be sent, as a picture or as plain text.
# Sourced by foreman-loop.sh after the preflight and the human-ticket gate, with the mode set to
# dry-run and next_ticket chosen; it always exits. `dry-run --json` is built from
# dry_run_json_facts (foreman-status.sh). The renderer minimum, _dryrun_min_cols, stays in
# foreman-loop.sh, where a smoke case reads it.

dry_run_facts() {    # dry_run_facts NEXT_TICKET
  local next="$1" counts ticket state human line first=1
  counts=$(next_sh --count) || return 1
  printf 'batch\t%s\ndone\t%s\ntotal\t%s\n' "$BATCH_DIR" "${counts% *}" "${counts#* }"
  [ -z "${FOREMAN_BATCH_NAME:-}" ] || printf 'name\t%s\n' "$FOREMAN_BATCH_NAME"
  while IFS= read -r ticket; do
    [ -n "$ticket" ] || continue
    foreman_ticket_status "$ticket"
    human=""; [ "$_FOREMAN_TICKET_HUMAN" != 1 ] || human=human
    state=todo; [ "$first" != 1 ] || state=next
    first=0
    printf 'ticket\t%s\t%s\t%s\t%s\n' "$state" "${ticket##*/}" "$human" "$_FOREMAN_TICKET_CHECKS"
  done < <(next_sh --list)
  printf 'exec\t%s\nperms\t%s\nmodel\t%s\neffort\t%s\n' "$(exec_describe)" "$FOREMAN_PERMISSION_MODE" "$FOREMAN_MODEL" "$FOREMAN_EFFORT"
  if [ "$FOREMAN_STREAM" = 1 ]; then printf 'live\ton\n'; else printf 'live\toff\n'; fi
  printf 'cost\t%s\ntime\t%s\niterations\t%s\n' "$(budget_label "$MAX_COST" '$')" "$(budget_label "$MAX_MINUTES" '' m)" "$(budget_label "$MAX_ITERATIONS")"
  printf 'logs\t%s\nlogs\t%s\n' "$RUN_JSONL" "$RUN_LOG"
  while IFS= read -r line; do
    [ -n "$line" ] && printf 'warning\t%s\n' "${line#warning: }"
  done < <(foreman_human_warnings)
  printf 'screen\t%s\n' "$DRYRUN_ROWS"
  if foreman_ticket_needs_human "$next"; then
    printf 'stop\t%s\n' "${next##*/}"
    line="$(foreman_handoff_path "$next")"
    [ -z "$line" ] || printf 'handoff\t%s\n' "$line"
    return 0
  fi
  TICKET_FILE="$next"
  BASE_REF=$(git rev-parse HEAD) || return 1
  # shellcheck source=foreman-prompt.sh
  source "$FOREMAN_TOOL_DIR/foreman-prompt.sh" || return 1
  printf 'promptfor\t%s\n' "$next"
  while IFS= read -r line || [ -n "$line" ]; do
    printf 'prompt\t%s\n' "$line"
  done <<< "$FOREMAN_PROMPT"
}

# Draws the picture, all or nothing: what the renderer prints before it fails is not printed, so the
# plain text that follows is never preceded by half a picture. Fails when it cannot be drawn.
dry_run_picture() {    # dry_run_picture NEXT_TICKET
  local facts out code
  facts="$(dry_run_facts "$1" 2>/dev/null)" || return 1
  out="$(node "$FOREMAN_TOOL_DIR/foreman-draw.cjs" dryrun --tier "$DRYRUN_TIER" --cols "$DRYRUN_COLS" <<< "$facts" 2>/dev/null; printf 'x%s' "$?")"
  code="${out##*x}"
  [ "$code" = 0 ] || return 1
  out="${out%x*}"
  printf '%s' "$out"
}

if [ "$MODE" = "dry-run" ]; then
  if [ "$STATUS_JSON" = 1 ]; then
    dry_run_json_facts "$next_ticket" | node "$FOREMAN_TOOL_DIR/foreman-json.cjs" dry-run
    exit "${PIPESTATUS[1]}"
  fi
  if ui_show 1 DRYRUN_TIER && ui_cols DRYRUN_COLS 1 && [ "$DRYRUN_COLS" -ge "$_dryrun_min_cols" ] &&
    ui_rows DRYRUN_ROWS 1 && dry_run_picture "$next_ticket"; then
    exit 0
  fi
  say_tag accent "Batch:" "$BATCH_DIR"
  progress_line
  say ""
  say "Would run, in this order:"
  next_sh --list | print_remaining_marked
  dry_run_warnings="$(foreman_human_warnings)"
  if [ -n "$dry_run_warnings" ]; then
    say ""
    printf '%s\n' "$dry_run_warnings"
  fi
  say ""
  say "Exec:    $(exec_describe)"
  say "Model:   $FOREMAN_MODEL   Effort: $FOREMAN_EFFORT"
  # The effective permission mode, which is a per-mode default unless the batch set one —
  # and the only place outside a real `claude` call where you can see which one won.
  say "Perms:   $FOREMAN_PERMISSION_MODE"
  # The other decision `fake` cannot exercise, for the same reason: it never invokes `claude`
  # and so never chooses an --output-format.
  if [ "$FOREMAN_STREAM" = "1" ]; then
    say "Live:    on (stream-json; file writes and shell commands drawn to stderr)"
  else
    say "Live:    off (json; add --live to watch the iteration)"
  fi
  say "Budgets: cost=$(budget_label "$MAX_COST" '$')  time=$(budget_label "$MAX_MINUTES" '' m)  iterations=$(budget_label "$MAX_ITERATIONS")"
  say "Logs:    $RUN_JSONL"
  say "         $RUN_LOG"
  say ""
  if foreman_ticket_needs_human "$next_ticket"; then
    say "Would stop before $next_ticket: it is a human ticket. No prompt would be sent."
    exit 0
  fi
  say "=== prompt that would be sent for $next_ticket ==="
  TICKET_FILE="$next_ticket"
  BASE_REF=$(git rev-parse HEAD)
  # shellcheck source=foreman-prompt.sh
  source "$FOREMAN_TOOL_DIR/foreman-prompt.sh"
  printf '%s\n' "$FOREMAN_PROMPT"
  say "=== end prompt (nothing was sent; no sandbox was started) ==="
  exit 0
fi
