#!/bin/bash
# What `foreman status` prints (plain text, the picture, and --json facts) and the facts
# `foreman dry-run --json` is made of. Sourced by
# foreman-loop.sh after the exec adapter is loaded — never run directly. It runs in the loop's
# own shell, so every global and helper the loop has by then is in scope, and its `exit`s are
# the loop's: `status` ends here, before the preflight and before anything is spent.
#
# Not here, because the run path uses them too: progress_line and _status_min_cols stay in the
# loop (the footer calls the first; a smoke case reads the second out of foreman-loop.sh).

# What the batch's run log says was spent: the sum of every record's cost_usd, or nothing at all
# when the log is missing or has no record in it (a line that is not one is not counted).
status_spent() {
  [ -f "$RUN_JSONL" ] || return 0
  node -e '
    let spent = 0, seen = false;
    for (const line of require("fs").readFileSync(process.argv[1], "utf8").split(/\r?\n/)) {
      try {
        const record = JSON.parse(line);
        if (record && typeof record === "object") { seen = true; spent += Number(record.cost_usd) || 0; }
      } catch { /* not a record */ }
    }
    if (seen) console.log(spent);
  ' "$RUN_JSONL" 2>/dev/null
}

status_facts() {
  local counts done_count total humans=0 ticket state human base next="" spent until_count=0 stop="" pos=0 line
  counts=$(next_sh --count) || return 1
  done_count="${counts% *}"; total="${counts#* }"
  printf 'batch\t%s\ndone\t%s\ntotal\t%s\ninvoke\t%s\n' "$BATCH_DIR" "$done_count" "$total" "$FOREMAN_INVOKE"
  [ -z "${FOREMAN_BATCH_NAME:-}" ] || printf 'name\t%s\n' "$FOREMAN_BATCH_NAME"
  spent="$(status_spent)"
  [ -z "$spent" ] || printf 'spent\t%s\n' "$spent"
  while IFS= read -r ticket; do
    [ -n "$ticket" ] || continue
    foreman_ticket_status "$ticket"
    human=""; state=todo
    if [ "$_FOREMAN_TICKET_DONE" = 1 ]; then
      state=done
    else
      if [ -z "$next" ]; then next="$ticket"; state=next; fi
      if [ "$_FOREMAN_TICKET_HUMAN" = 1 ]; then
        human=human; humans=$((humans + 1))
        # The loop runs the tickets before the first human one, when that is not the next.
        if [ -z "$stop" ] && [ "$state" != next ]; then stop="${ticket##*/}"; until_count=$pos; fi
      fi
      pos=$((pos + 1))
    fi
    base="${ticket##*/}"
    [ -z "$FOREMAN_DONE_PREFIX" ] || base="${base#"$FOREMAN_DONE_PREFIX"}"
    printf 'ticket\t%s\t%s\t%s\t%s\n' "$state" "$base" "$human" "$_FOREMAN_TICKET_CHECKS"
  done < <(next_sh --all)
  printf 'humans\t%s\n' "$humans"
  if [ -n "$stop" ]; then printf 'until\t%s\nstop\t%s\n' "$until_count" "$stop"; fi
  if [ -n "$next" ] && foreman_ticket_needs_human "$next"; then
    line="$(foreman_handoff_path "$next")"
    [ -z "$line" ] || printf 'handoff\t%s\n' "$line"
    line="$(foreman_was_sent_back "$next")"
    [ -z "$line" ] || printf 'sentback\t%s\n' "$line"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] && printf 'warning\t%s\n' "${line#warning: }"
  done < <(foreman_human_warnings)
}

# `status --json`: the same facts, plus the ones the plain output never needed (each ticket's file,
# handoff and whether it landed), for foreman-json.cjs to put into an object — see its header for
# the lines. Everything it says is worked out here, the way status_facts works it out; the node
# side only adds what it reads from files. Needs the ticket snapshot held.
status_json_facts() {
  local counts ticket state humans=0 next="" until_count=0 stop="" pos=0 line done_t human_t checks_t root
  counts=$(next_sh --count) || return 1
  foreman_mixed_path root "$REPO_ROOT"
  printf 'repo\t%s\nbatch\t%s\nname\t%s\nstatusline\t%s\ndoneprefix\t%s\nrunjsonl\t%s\nrunlog\t%s\ndone\t%s\ntotal\t%s\n' \
    "$root" "$BATCH_DIR" "$BATCH_NAME" "$FOREMAN_STATUS_LINE" "$FOREMAN_DONE_PREFIX" \
    "${RUN_JSONL//\\//}" "${RUN_LOG//\\//}" "${counts% *}" "${counts#* }"
  while IFS= read -r ticket; do
    [ -n "$ticket" ] || continue
    foreman_ticket_status "$ticket"
    done_t="$_FOREMAN_TICKET_DONE"; human_t="$_FOREMAN_TICKET_HUMAN"; checks_t="$_FOREMAN_TICKET_CHECKS"
    state=todo
    if [ "$done_t" = 1 ]; then
      state=done
    else
      if [ -z "$next" ]; then next="$ticket"; state=next; fi
      if [ "$human_t" = 1 ]; then
        humans=$((humans + 1))
        # The loop runs the tickets before the first human one, when that is not the next.
        if [ -z "$stop" ] && [ "$state" != next ]; then stop="${ticket//\\//}"; until_count=$pos; fi
      fi
      pos=$((pos + 1))
    fi
    line="$(foreman_handoff_path "$ticket")"
    printf 'ticket\t%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "${ticket//\\//}" "$done_t" "$human_t" "$checks_t" "${line//\\//}"
  done < <(next_sh --all)
  printf 'humans\t%s\n' "$humans"
  # Where a run in flight would keep its control directory in this batch (see where the run makes
  # it), and whether the run its `pid` file names is alive, by the rule `foreman stop` and the start
  # guard use (run_pid_alive): foreman-json.cjs only reads the rest of the directory's files.
  ctl_rel_dir "$BATCH_DIR" line
  printf 'runctl\t%s\n' "${line//\\//}"
  ctl_read_pid "$REPO_ROOT/$line"
  if run_pid_alive "$CTL_PID_MSYS" "$CTL_PID_WIN"; then printf 'runalive\t1\n'; else printf 'runalive\t0\n'; fi
  if [ -n "$stop" ]; then printf 'until\t%s\t%s\n' "$until_count" "$stop"; fi
  if [ -n "$next" ] && foreman_ticket_needs_human "$next"; then
    line="$(foreman_was_sent_back "$next")"
    [ -z "$line" ] || printf 'sentback\t%s\n' "$line"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] && printf 'warning\t%s\n' "${line#warning: }"
  done < <(foreman_human_warnings)
}

# One line of text as one `key<TAB>value` line: backslash, newline, tab and carriage return become
# `\\`, `\n`, `\t` and `\r`, and foreman-json.cjs turns them back. Only bash builtins, so nothing
# starts. The prompt goes this way because it is the one value that must reach the app exactly as
# the plain output prints it, blank lines and all.
fact_escape() {    # fact_escape TEXT
  local s="$1" bs='\' nl=$'\n' tab=$'\t' cr=$'\r'
  s="${s//"$bs"/"$bs$bs"}"; s="${s//"$nl"/"${bs}n"}"; s="${s//"$tab"/"${bs}t"}"; s="${s//"$cr"/"${bs}r"}"
  printf '%s' "$s"
}

# `dry-run --json`: the facts the plain dry-run prints, in the lines foreman-json.cjs reads (see its
# header). The tickets still to do, each with what the run would do with it: `run` (the budget
# reaches it, and no human ticket comes first), `stop` (the first human ticket, where a run stops;
# `stopreach` says whether the iteration budget gets that far) or `later`. Nothing is sent and no
# sandbox starts: this is as far as the plain dry-run goes, and it builds the same prompt. NEXT is
# the ticket the prompt is for, empty when nothing is left. One iteration is one attempt at the next
# ticket, so the reach is the best case: a ticket that does not land in one turn takes more.
dry_run_json_facts() {    # dry_run_json_facts NEXT
  local next="$1" counts ticket state line root ran=0 stopped=0 reach=0
  counts=$(next_sh --count) || return 1
  foreman_mixed_path root "$REPO_ROOT"
  printf 'repo\t%s\nbatch\t%s\nname\t%s\nstatusline\t%s\ndoneprefix\t%s\ndone\t%s\ntotal\t%s\n' \
    "$root" "$BATCH_DIR" "$BATCH_NAME" "$FOREMAN_STATUS_LINE" "$FOREMAN_DONE_PREFIX" "${counts% *}" "${counts#* }"
  while IFS= read -r ticket; do
    [ -n "$ticket" ] || continue
    foreman_ticket_status "$ticket"
    if [ "$stopped" = 1 ]; then
      state=later
    elif [ "$_FOREMAN_TICKET_HUMAN" = 1 ]; then
      state=stop; stopped=1
      if [ "$MAX_ITERATIONS" -le 0 ] || [ "$ran" -lt "$MAX_ITERATIONS" ]; then reach=1; fi
    elif [ "$MAX_ITERATIONS" -gt 0 ] && [ "$ran" -ge "$MAX_ITERATIONS" ]; then
      state=later
    else
      state=run; ran=$((ran + 1))
    fi
    line="$(foreman_handoff_path "$ticket")"
    printf 'ticket\t%s\t%s\t0\t%s\t%s\t%s\n' "$state" "${ticket//\\//}" "$_FOREMAN_TICKET_HUMAN" "$_FOREMAN_TICKET_CHECKS" "${line//\\//}"
  done < <(next_sh --list)
  printf 'stopreach\t%s\n' "$reach"
  printf 'exec\t%s\nperms\t%s\nmodel\t%s\neffort\t%s\n' "$(exec_describe)" "$FOREMAN_PERMISSION_MODE" "$FOREMAN_MODEL" "$FOREMAN_EFFORT"
  if [ "$FOREMAN_STREAM" = 1 ]; then printf 'live\ton\n'; else printf 'live\toff\n'; fi
  printf 'cost\t%s\nminutes\t%s\niterations\t%s\n' "$MAX_COST" "$MAX_MINUTES" "$MAX_ITERATIONS"
  printf 'budgets\tcost=%s  time=%s  iterations=%s\n' "$(budget_label "$MAX_COST" '$')" "$(budget_label "$MAX_MINUTES" '' m)" "$(budget_label "$MAX_ITERATIONS")"
  printf 'logjsonl\t%s\nlogrun\t%s\n' "${RUN_JSONL//\\//}" "${RUN_LOG//\\//}"
  while IFS= read -r line; do
    [ -n "$line" ] && printf 'warning\t%s\n' "${line#warning: }"
  done < <(foreman_human_warnings)
  if [ -n "$next" ] && ! foreman_ticket_needs_human "$next"; then
    TICKET_FILE="$next"
    BASE_REF=$(git rev-parse HEAD) || return 1
    # shellcheck source=foreman-prompt.sh
    source "$FOREMAN_TOOL_DIR/foreman-prompt.sh" || return 1
    printf 'promptfor\t%s\n' "${next//\\//}"
    printf 'prompt\t%s\n' "$(fact_escape "$FOREMAN_PROMPT")"
  fi
}

# Draws the picture, all or nothing: what the renderer prints before it fails is not printed, so the
# plain text that follows is never preceded by half a picture. Fails when it cannot be drawn.
status_picture() {
  local facts out code
  facts="$(status_facts)" || return 1
  out="$(node "$FOREMAN_TOOL_DIR/foreman-draw.cjs" status --tier "$STATUS_TIER" --cols "$STATUS_COLS" <<< "$facts" 2>/dev/null; printf 'x%s' "$?")"
  code="${out##*x}"
  [ "$code" = 0 ] || return 1
  out="${out%x*}"
  printf '%s' "$out"
}

if [ "$MODE" = "status" ]; then
  if [ "$STATUS_JSON" = 1 ]; then
    foreman_tickets_hold || exit 1
    status_json_facts | node "$FOREMAN_TOOL_DIR/foreman-json.cjs" status
    exit "${PIPESTATUS[1]}"
  fi
  if ui_show 1 STATUS_TIER && ui_cols STATUS_COLS 1 && [ "$STATUS_COLS" -ge "$_status_min_cols" ] &&
    foreman_tickets_hold 2>/dev/null && status_picture; then
    exit 0
  fi
  say_tag accent "Batch:" "$BATCH_DIR${FOREMAN_BATCH_NAME:+ ($FOREMAN_BATCH_NAME)}"
  # Nothing here changes a ticket, so the list is worked out once and every question below is
  # answered from it.
  foreman_tickets_hold || exit 1
  progress_line || exit 1
  say ""
  if next_ticket=$(next_sh); then
    if foreman_ticket_needs_human "$next_ticket"; then
      ui_paint human_flag 1 warn "[HUMAN — the loop will not run until you do it]"
      say_tag accent "Next:" "${next_ticket##*/}   $human_flag"
    else
      say_tag accent "Next:" "${next_ticket##*/}"
    fi
    say ""
    say "Remaining, in order:"
    next_sh --list | print_remaining_marked
    say ""
    if foreman_ticket_needs_human "$next_ticket"; then
      human_ticket_note "$next_ticket"
    else
      human_ticket=""
      pos=0
      while IFS= read -r t; do
        pos=$((pos + 1))
        if foreman_ticket_needs_human "$t"; then human_ticket="$t"; break; fi
      done < <(next_sh --list)
      if [ -n "$human_ticket" ]; then
        say "The loop will run $((pos - 1)) ticket(s), then stop at ${human_ticket##*/} for a human."
      fi
    fi
  else
    say "Nothing left — every ticket in this batch is done."
  fi
  warnings="$(foreman_human_warnings)"
  if [ -n "$warnings" ]; then
    say ""
    printf '%s\n' "$warnings"
  fi
  exit 0
fi
