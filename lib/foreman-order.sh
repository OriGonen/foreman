#!/bin/bash
# Has an agent read a batch's tickets and rewrite order.md: the run order, weighing
# dependencies, importance and each ticket's apparent load, plus the reasoning behind it.
#
#   foreman order <batch>
#
# Runs automatically at the end of `foreman init`. Re-run it by hand after tickets change.
#
# Read-only over the tickets themselves — the only file it writes is <batch>/order.md.
# Runs locally, never in a sandbox: it edits no code, so none of FOREMAN_EXEC's isolation
# concerns apply, and it should work even in a repo that has no sandbox set up yet.
#
# FOREMAN_ORDER_RESULT=<file>, when set, is where it leaves how it went, as facts for the
# renderer (`key<TAB>value` lines, see foreman-draw.cjs): that is how `foreman init` draws the
# result without reading what this prints. What this prints does not change.
#
# THE SHOW. At a terminal (see THE SHOW in foreman-ui.sh) this draws, with foreman-draw.cjs, a
# header, then a one-line spinner with the seconds that is redrawn while the agent reads and
# cleared when it is done or has failed, then the new order on a numbered stake line: `moved`
# beside the tickets that changed place, HUMAN and CHECK beside the ones that stop the loop or
# check another, and the batch's warnings below. Anywhere else, or when the terminal is narrower
# than 80 columns, or when a picture cannot be drawn, it prints the text it always did. A
# caller that asks for the facts draws the result itself, so it is never the show.
#
# Costs one model call, on FOREMAN_MODEL by default — ordering rarely needs the same model
# the tickets themselves run on, so set FOREMAN_ORDERING_MODEL in foreman.conf to point it at
# something cheaper without touching FOREMAN_MODEL. If `claude` is not on PATH, this prints a
# note and exits 0 rather than failing whatever called it — order.md just keeps its
# filename order.
set -uo pipefail

# This file's directory, from the shell and not `dirname` (see foreman-config.sh).
FOREMAN_TOOL_DIR="${BASH_SOURCE[0]%/*}"; [ "$FOREMAN_TOOL_DIR" != "${BASH_SOURCE[0]}" ] || FOREMAN_TOOL_DIR=.
FOREMAN_TOOL_DIR="$(cd "${FOREMAN_TOOL_DIR:-/}" && pwd)"

show_help() { awk 'NR==1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; }

# Appends a fact to FOREMAN_ORDER_RESULT, if there is one.
order_fact() {    # order_fact KEY VALUE...
  [ -n "${FOREMAN_ORDER_RESULT:-}" ] || return 0
  local key="$1" value
  shift
  printf -v value '\t%s' "$@"
  printf '%s%s\n' "$key" "$value" >> "$FOREMAN_ORDER_RESULT"
}
[ -z "${FOREMAN_ORDER_RESULT:-}" ] || : > "$FOREMAN_ORDER_RESULT" || exit 1

BATCH_INPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    -*) echo "Usage: foreman order <batch>" >&2; exit 1 ;;
    *) BATCH_INPUT="$1" ;;
  esac
  shift
done
[ -n "$BATCH_INPUT" ] || { echo "Usage: foreman order <batch>" >&2; exit 1; }

# foreman-config.sh gives us BATCH_DIR, ORDER_FILE and FOREMAN_MODEL resolved the same way
# every other foreman command resolves them — env, then this batch's foreman.conf, then
# defaults — so FOREMAN_ORDERING_MODEL set there is honoured without this script knowing
# anything about foreman.conf's format itself.
export FOREMAN_BATCH="$BATCH_INPUT"
# shellcheck source=foreman-config.sh
source "$FOREMAN_TOOL_DIR/foreman-config.sh" || exit 1
# shellcheck source=foreman-human.sh
source "$FOREMAN_TOOL_DIR/foreman-human.sh" || exit 1
# shellcheck source=foreman-tickets.sh
source "$FOREMAN_TOOL_DIR/foreman-tickets.sh" || exit 1

[ -f "$ORDER_FILE" ] || {
  warn_tag error "foreman order:" "$ORDER_FILE does not exist — run: foreman init $BATCH_DIR"
  exit 1
}

if ! command -v claude >/dev/null 2>&1; then
  order_fact result skipped
  order_fact said "'claude' is not on PATH"
  warn_tag error "foreman order:" "'claude' is not on PATH — skipping."
  echo "              $ORDER_FILE keeps its filename order; re-run \`foreman order $BATCH_DIR\` once it is." >&2
  exit 0
fi

# The batch's own ticket list, from the one place that knows how a batch answers that
# (foreman-tickets.sh) —
# including any FOREMAN_ISSUES_DIRS the conf sets. `--unordered` rather than `--all` because
# re-ordering has to see tickets added since order.md was last written.
tickets=()
while IFS= read -r f; do
  [ -n "$f" ] && tickets+=("$f")
done < <(foreman_next_answer --unordered)

if [ "${#tickets[@]}" -eq 0 ]; then
  order_fact result empty
  say_tag accent "foreman order:" "$BATCH_DIR has no tickets — nothing to order."
  foreman_issues_hint
  exit 0
fi

# Human tickets and followup tickets change how the order is chosen, so the agent is told
# about them only when this batch actually has one — an ordinary batch gets the prompt it
# always got.
human_tickets=()
has_checks=0
for t in "${tickets[@]}"; do
  foreman_ticket_status "$t"
  [ "$_FOREMAN_TICKET_HUMAN" = 1 ] && human_tickets+=("$t")
  [ -n "$_FOREMAN_TICKET_CHECKS" ] && has_checks=1
done

HUMAN_SECTION=""
if [ "${#human_tickets[@]}" -gt 0 ]; then
  HUMAN_SECTION=$(cat <<HUMAN_EOF


HUMAN TICKETS. These tickets are done by a person, not by the loop:
$(for t in "${human_tickets[@]}"; do printf -- '- %s\n' "$t"; done)
The loop stops at the first human ticket it reaches and runs nothing after it until a
person has finished it. So, for each human ticket:
- it comes after every ticket it depends on;
- every ticket that depends on it — directly, or through another ticket — comes after it;
- it goes as LATE as those two rules allow: every ticket that does not depend on it,
  directly or transitively, goes before it, so the unattended stretch before each stop is
  as long as possible.
In the prose above the order block, name each human ticket, the tickets that wait on it,
and why it sits where it does.
HUMAN_EOF
)
fi

CHECK_SECTION=""
if [ "$has_checks" -eq 1 ]; then
  CHECK_SECTION=$(cat <<CHECK_EOF


FOLLOWUP TICKETS. A ticket with a \`Checks:\` line verifies the ticket it names. It goes
IMMEDIATELY after that ticket, with nothing between them: an unrelated ticket in between
could build on work that has not been checked yet.
CHECK_EOF
)
fi

# Ordering is a much smaller job than implementing a ticket, so it defaults to FOREMAN_MODEL
# rather than automatically riding whatever the tickets themselves run on — set
# FOREMAN_ORDERING_MODEL in foreman.conf to point it at something cheaper. Effort stays fixed
# at high regardless of FOREMAN_EFFORT: reading every ticket and weighing dependencies is the
# one place in this toolkit where skimping on effort risks a bad order, even on a small model.
MODEL="${FOREMAN_ORDERING_MODEL:-$FOREMAN_MODEL}"
EFFORT=high

PROMPT=$(cat <<PROMPT_EOF
You are ordering the tickets in $BATCH_DIR for the foreman ticket loop, which implements
exactly one ticket per iteration, in the order given, committing each before moving to the
next.

Read every ticket listed below and the current $ORDER_FILE. Then edit
$ORDER_FILE in place, and change nothing else:

1. Decide a run order, weighing these in priority order: dependencies first, then
   human-ticket placement and followup-ticket adjacency (see below, when this batch has
   either), then importance, then load.
   - DEPENDENCIES. A ticket that reads or builds on something another ticket creates must
     come after it. Two tickets that touch the same file or area should be adjacent, so a
     conflict between them is a sequential edit rather than a merge.
   - IMPORTANCE. Foundational work, or anything several other tickets depend on, goes
     first. Polish and sweep-every-surface tickets go last.
   - LOAD. Each ticket's apparent size or complexity — how much it asks for, how many
     files or seams it likely touches. Prefer not to front-load a run with every large
     ticket back to back when the dependency graph allows spreading them out.
2. Replace the prose above the <!-- ORDER:BEGIN --> marker with your reasoning. Name
   tickets specifically: which dependency chains you found, why anything heavy or
   foundational landed where it did, and any dependency that crosses issue directories or
   isn't obvious from the filenames.
3. Replace the block between <!-- ORDER:BEGIN --> and <!-- ORDER:END --> with the ordered,
   repo-relative ticket paths, one per line, inside the existing code fence.
4. Do not edit any ticket file. Do not invent a ticket that is not in the list below, and
   do not drop one that is.
${HUMAN_SECTION}${CHECK_SECTION}

A ticket's \`Blocked by:\` line, when it has one, is an explicit dependency: honour it
exactly.

Tickets in $BATCH_DIR:
$(for t in "${tickets[@]}"; do printf -- '- %s\n' "$t"; done)
PROMPT_EOF
)

# The picture is the renderer's width and no narrower; the shell checks it here, so a narrow
# terminal starts no node, and a smoke case holds the two numbers together.
_order_min_cols=80

# Draws SCENE from the facts on stdin, all or nothing: what the renderer prints before it fails is
# not printed, so the plain text that follows is never preceded by half a picture. Fails when it
# cannot be drawn.
order_draw() {    # order_draw SCENE
  local out code
  out="$(node "$FOREMAN_TOOL_DIR/foreman-draw.cjs" "$1" --tier "$ORDER_TIER" --cols "$ORDER_COLS" 2>/dev/null; printf 'x%s' "$?")"
  code="${out##*x}"
  [ "$code" = 0 ] || return 1
  printf '%s' "${out%x*}"
}

# The wait, on one line: a spinner and the seconds, redrawn until the agent is done. It runs in the
# background and is only ever started on a terminal: there is nothing to redraw on a pipe.
order_spinner() {
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0 start=$SECONDS s spin text clock
  ui_paint text 1 muted "the agent is reading the tickets"
  while :; do
    s=$((SECONDS - start))
    ui_paint spin 1 warn "${frames[i++ % 10]}"
    printf -v clock '%d:%02d' $((s / 60)) $((s % 60))
    ui_paint clock 1 muted "$clock"
    printf '\r\033[2K  %s %s   %s' "$spin" "$text" "$clock"
    sleep 0.2
  done
}

ORDER_SPINNER_PID=""
# Stops the spinner, if it is running, and leaves its line empty.
order_stop_spinner() {
  [ -n "$ORDER_SPINNER_PID" ] || return 0
  kill "$ORDER_SPINNER_PID" 2>/dev/null
  wait "$ORDER_SPINNER_PID" 2>/dev/null
  ORDER_SPINNER_PID=""
  printf '\r\033[2K'
}

ORDER_OWN_FACTS=""
order_exit() {
  order_stop_spinner
  [ -z "$ORDER_OWN_FACTS" ] || rm -f "$ORDER_OWN_FACTS"
}

# Whether to show, and at what tier and width. The facts the picture is drawn from are left in a file
# of this script's own, unless a caller asked for them in its own: then it draws the result, and this
# prints text.
ORDER_SHOW=0
ORDER_TIER=""
ORDER_COLS=""
if [ -z "${FOREMAN_ORDER_RESULT:-}" ] && ui_show 1 ORDER_TIER && ui_cols ORDER_COLS 1 && [ "$ORDER_COLS" -ge "$_order_min_cols" ] &&
  ORDER_OWN_FACTS="$(mktemp "${TMPDIR:-/tmp}/foreman-order.XXXXXX" 2>/dev/null)"; then
  ORDER_SHOW=1
  FOREMAN_ORDER_RESULT="$ORDER_OWN_FACTS"
fi
trap order_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The order as it stands, for the renderer to compare with the one the agent leaves.
was=""
[ -z "${FOREMAN_ORDER_RESULT:-}" ] || was="$(foreman_next_answer --all 2>/dev/null)"

if [ "$ORDER_SHOW" -eq 1 ] && printf 'batch\t%s\ntickets\t%s\nmodel\t%s\n' "$BATCH_DIR" "${#tickets[@]}" "$MODEL" | order_draw order-head; then
  [ ! -t 1 ] || { order_spinner & ORDER_SPINNER_PID=$!; }
else
  # No picture to draw it in: today's line, and from here on a plain run.
  if [ "$ORDER_SHOW" -eq 1 ]; then ORDER_SHOW=0; FOREMAN_ORDER_RESULT=""; fi
  say_tag accent "foreman order:" "reading ${#tickets[@]} ticket(s) in $BATCH_DIR ..."
fi

# stdin is closed because claude, finding it is not a terminal, otherwise waits for input
# that never comes.
order_start=$SECONDS
RESPONSE=$(claude --model "$MODEL" --effort "$EFFORT" --permission-mode acceptEdits \
  --print --output-format json -p "$PROMPT" </dev/null)
status=$?
order_seconds=$((SECONDS - order_start))
order_stop_spinner

# Read the payload once: is_error, the cost, and the agent's own message as one line, plus
# whether that message is a login failure (see foreman-claude-reply.cjs).
{ IFS= read -r is_error; IFS= read -r cost; IFS= read -r said; IFS= read -r auth_failed; } < <(
  node "$FOREMAN_TOOL_DIR/foreman-claude-reply.cjs" <<< "$RESPONSE")

if [ "$status" -ne 0 ] || [ "$is_error" = 1 ]; then
  order_fact result failed
  order_fact said "$said"
  order_fact auth "${auth_failed:-0}"
  warn_tag error "foreman order:" "the agent call failed (exit $status) — $ORDER_FILE is unchanged."
  [ -n "$said" ] && echo "             claude said: $said"
  [ "$auth_failed" = 1 ] && echo "             your claude login has expired — run \`claude /login\`, then re-run \`foreman order $BATCH_INPUT\`."
  exit 1
fi

warnings="$(foreman_human_warnings)"

# What a plain run says, and a show that could not be drawn.
order_say_plain() {
  say_tag accent "foreman order:" "wrote $ORDER_FILE${cost:+ (cost \$$cost)}"
  echo "             review it — this is a first pass, not a guarantee."
  [ -z "$warnings" ] || printf '%s\n' "$warnings"
}
[ "$ORDER_SHOW" -eq 1 ] || order_say_plain

# What the renderer needs to say how the order changed and who it stops for: the order before
# ($1) and now, one ticket a line; each ticket a person does; and each ticket that checks another,
# with the one it checks.
order_result_lists() {    # order_result_lists WAS
  local now line target
  now="$(foreman_next_answer --all 2>/dev/null)"
  while IFS= read -r line; do
    [ -n "$line" ] && order_fact was "$line"
  done <<< "$1"
  while IFS= read -r line; do
    [ -n "$line" ] && order_fact now "$line"
  done <<< "$now"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    foreman_ticket_status "$line"
    [ "$_FOREMAN_TICKET_HUMAN" = 1 ] && order_fact human "$line"
    if [ -n "$_FOREMAN_TICKET_CHECKS" ]; then
      target="$(foreman_checked_ticket "$line")"
      [ -n "$target" ] && order_fact check "$line" "$target"
    fi
  done <<< "$now"
}

if [ -n "${FOREMAN_ORDER_RESULT:-}" ]; then
  order_fact result ordered
  [ -z "$cost" ] || order_fact cost "$cost"
  order_result_lists "$was"
  while IFS= read -r line; do
    [ -n "$line" ] && order_fact warning "${line#warning: }"
  done <<< "$warnings"
fi

if [ "$ORDER_SHOW" -eq 1 ]; then
  { cat "$ORDER_OWN_FACTS"; printf 'batch\t%s\ninvoke\t%s\nseconds\t%s\n' "$BATCH_DIR" "$FOREMAN_INVOKE" "$order_seconds"; } | order_draw order || order_say_plain
fi
exit 0
