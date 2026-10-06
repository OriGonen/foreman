#!/bin/bash
# The keyboard side of `ralph run`: + and - change the iteration budget while the run is
# going, and L turns the live view on and off. Started by ralph-loop.sh in the background,
# on the terminal's stdin, and killed when the run exits. Never sourced.
#
#   ralph-keys.sh <ctl-dir> <loop-pid>      read keys until the loop is gone
#   ralph-keys.sh --apply <keys> <ctl-dir>  apply each key in <keys> once, as if pressed
#
#   +  =    one more iteration
#   -  _    one fewer — never below the iteration already running
#   L  l    live view on / off: what --live draws, from the next tick of the iteration running
#
# The two talk through small files in <ctl-dir>, so neither has to signal the other:
#   budget     the iteration budget, 0 for unlimited. Seeded by the loop, then written only
#              here (temp file plus mv, so the loop never reads half a number).
#   live       1 while the live view is on, else 0. Seeded by the loop, then written only
#              here; read by ralph-stream.cjs once a second.
#   iteration  the iteration now running, written by the loop. Only read here.
#   screen     "ROWS COLS" while the loop has a status bar open, written by the loop (and
#              here, on a resize). No file, no bar: each key press prints a line instead.
# The loop reads `budget` before each iteration's budget check; a key never touches the
# iteration already running.
#
# THE STATUS BAR (ralph-ui.sh draws it; the loop opens and closes it). The reader repaints it
# after every key, and whenever the loop starts a new iteration — it checks once a second.
#
# The idle loop is builtins only — `read`, `kill -0`, `printf`, `read < file`. No `$(...)`,
# no external commands: a reader waiting on a key starts no processes, which matters under
# MSYS, where starting one is the expensive thing. A key press may spawn one (the `mv`), and
# so may a resize (`stty size`).

# This file's directory, from the shell and not `dirname` (see ralph-config.sh).
_keys_dir="${BASH_SOURCE[0]%/*}"; [ "$_keys_dir" != "${BASH_SOURCE[0]}" ] || _keys_dir=.
# shellcheck source=ralph-ui.sh
source "$_keys_dir/ralph-ui.sh" || exit 1

# Sets _KEYS_BUDGET, _KEYS_ITERATION and _KEYS_LIVE from the control files; a missing or
# garbled file reads as 0.
_keys_read_state() {
  local dir="$1"
  _KEYS_BUDGET=0; _KEYS_ITERATION=0; _KEYS_LIVE=0
  read -r _KEYS_BUDGET 2>/dev/null < "$dir/budget"
  read -r _KEYS_ITERATION 2>/dev/null < "$dir/iteration"
  read -r _KEYS_LIVE 2>/dev/null < "$dir/live"
  [[ "$_KEYS_BUDGET" =~ ^[0-9]+$ ]] || _KEYS_BUDGET=0
  [[ "$_KEYS_ITERATION" =~ ^[0-9]+$ ]] || _KEYS_ITERATION=0
  [ "$_KEYS_LIVE" = 1 ] || _KEYS_LIVE=0
}

# Writes VALUE to <ctl-dir>/NAME whole: a temp file plus mv, so no reader sees half of it.
_keys_write() {    # _keys_write DIR NAME VALUE
  printf '%s\n' "$3" > "$1/$2.tmp" && mv -f "$1/$2.tmp" "$1/$2"
}

# Applies one key to the control files and sets _KEYS_SAID to what it did, in words — empty
# for anything that is not one of the six keys, which is ignored.
keys_apply() {    # keys_apply KEY CTL_DIR
  local key="$1" dir="$2" budget floor
  _KEYS_SAID=""
  case "$key" in
    +|=|-|_|L|l) ;;
    *) return 0 ;;
  esac
  _keys_read_state "$dir"

  if [ "$key" = L ] || [ "$key" = l ]; then
    if [ "$_KEYS_LIVE" = 1 ]; then
      _keys_write "$dir" live 0 && _KEYS_SAID="live view off"
    else
      _keys_write "$dir" live 1 && _KEYS_SAID="live view on"
    fi
    return 0
  fi

  budget="$_KEYS_BUDGET"
  # The iteration already running cannot be cut; before the first one, that is iteration 1.
  floor="$_KEYS_ITERATION"; [ "$floor" -ge 1 ] || floor=1

  case "$key" in
    +|=)
      if [ "$budget" -eq 0 ]; then
        _KEYS_SAID="already unlimited"
        return 0
      fi
      budget=$((budget + 1))
      ;;
    -|_)
      # From unlimited, one fewer than "no cap" is "stop after this one".
      if [ "$budget" -eq 0 ]; then
        budget="$floor"
      elif [ "$budget" -gt "$floor" ]; then
        budget=$((budget - 1))
      fi
      ;;
  esac

  [ "$budget" = "$_KEYS_BUDGET" ] || _keys_write "$dir" budget "$budget"
  if [ "$budget" -le "$floor" ]; then
    _KEYS_SAID="stops after this iteration ($floor of $budget)"
  else
    _KEYS_SAID="iterations: $floor of $budget"
  fi
}

# Sets _KEYS_BAR to the status bar's text for the state in <ctl-dir>, fitted to COLS:
#   ── iteration 2 of 4  ·  live off  ·  + more  - fewer  L live
# The key hints go first when it does not fit, then the end of the line.
keys_bar_text() {    # keys_bar_text CTL_DIR COLS
  local cols="$2" head hints rule
  _keys_read_state "$1"
  if [ "$_KEYS_ITERATION" -eq 0 ]; then
    head="before iteration 1"
  else
    head="iteration $_KEYS_ITERATION"
  fi
  if [ "$_KEYS_BUDGET" -eq 0 ]; then
    head+=" (unlimited)"
  else
    head+=" of $_KEYS_BUDGET"
    [ "$_KEYS_ITERATION" -lt "$_KEYS_BUDGET" ] || head+="${_UI_SEP}stops after this one"
  fi
  if [ "$_KEYS_LIVE" = 1 ]; then head+="${_UI_SEP}live on"; else head+="${_UI_SEP}live off"; fi
  hints="+ more  - fewer  L live"

  # Room for the rule, its space, and one column spare: writing the last column of the
  # bottom row would wrap on some terminals.
  cols=$((cols - 4))
  if [ $((${#head} + ${#_UI_SEP} + ${#hints})) -le "$cols" ]; then
    ui_paint hints 2 muted "$hints"
    head+="$_UI_SEP$hints"
  elif [ "${#head}" -gt "$cols" ] && [ "$cols" -gt 0 ]; then
    head="${head:0:cols}"
  fi
  ui_paint rule 2 accent '──'
  _KEYS_BAR="$rule $head"
}

if [ "${1:-}" = "--apply" ]; then
  keys="${2:-}" dir="${3:-}"
  [ -d "$dir" ] || { printf 'ralph-keys: no control directory at %s\n' "$dir" >&2; exit 1; }
  for ((i = 0; i < ${#keys}; i++)); do
    keys_apply "${keys:i:1}" "$dir"
    [ -z "$_KEYS_SAID" ] || ui_key_echo "$_KEYS_SAID"
  done
  exit 0
fi

CTL_DIR="${1:-}" LOOP_PID="${2:-}"
if [ ! -d "$CTL_DIR" ] || ! [[ "$LOOP_PID" =~ ^[0-9]+$ ]]; then
  printf 'usage: ralph-keys.sh <ctl-dir> <loop-pid>  |  ralph-keys.sh --apply <keys> <ctl-dir>\n' >&2
  exit 1
fi

# Echo off and no line buffering for as long as the reader runs, rather than only inside
# each `read`: between two reads a key would otherwise echo, or sit in the line buffer
# until Enter. Signals stay on, so Ctrl-C still reaches the loop. Restored on the way out;
# the loop restores its own saved copy too, in case this is killed too hard to trap.
saved_stty=""
if saved_stty="$(stty -g 2>/dev/null)"; then
  stty -echo -icanon 2>/dev/null
fi
restore_tty() { [ -z "$saved_stty" ] || stty "$saved_stty" 2>/dev/null; }
trap restore_tty EXIT
# A background job of a non-interactive shell starts with SIGINT ignored, so Ctrl-C does
# not reach this at all; TERM is what the loop sends when the run ends.
trap 'exit 0' INT TERM HUP

# The bar, if the loop opened one: its size, and what was last drawn, so an idle second
# that changed nothing draws nothing.
ROWS=0 COLS=0 DRAWN=""
read -r ROWS COLS 2>/dev/null < "$CTL_DIR/screen"
[[ "$ROWS" =~ ^[0-9]+$ ]] && [[ "$COLS" =~ ^[0-9]+$ ]] || ROWS=0

repaint() {
  [ "$ROWS" -gt 0 ] || return 0
  keys_bar_text "$CTL_DIR" "$COLS"
  [ "$_KEYS_BAR" != "$DRAWN" ] || return 0
  ui_bar_draw "$ROWS" "$_KEYS_BAR"
  DRAWN="$_KEYS_BAR"
}

# A resize moves the bottom row. Blank the old bar, scroll over the new size, and tell the
# loop (it closes the bar on the way out). The trap only raises a flag: bash runs it between
# commands, and the work is done at the top of the loop below.
RESIZED=0
trap 'RESIZED=1' WINCH
on_resize() {
  local rows cols
  RESIZED=0
  read -r rows cols < <(stty size 2>/dev/null)
  [[ "$rows" =~ ^[0-9]+$ ]] && [[ "$cols" =~ ^[0-9]+$ ]] && [ "$rows" -ge 3 ] || return 0
  [ "$rows" != "$ROWS" ] || [ "$cols" != "$COLS" ] || return 0
  # Taller: the old bar is now a row inside the scrolling area. Shorter: it is the new
  # bottom row, or gone, and is drawn over either way.
  [ "$rows" -le "$ROWS" ] || ui_bar_draw "$ROWS" ""
  ui_bar_open "$rows"
  ROWS="$rows" COLS="$cols" DRAWN=""
  _keys_write "$CTL_DIR" screen "$ROWS $COLS"
}

repaint
while kill -0 "$LOOP_PID" 2>/dev/null; do
  [ "$RESIZED" = 0 ] || [ "$ROWS" -eq 0 ] || on_resize
  key=""
  if read -rsn1 -t 1 key; then
    keys_apply "$key" "$CTL_DIR"
    if [ "$ROWS" -gt 0 ]; then
      repaint
    elif [ -n "$_KEYS_SAID" ]; then
      ui_key_echo "$_KEYS_SAID"
    fi
  elif [ $? -le 128 ]; then
    # Not a timeout: stdin is gone (end of file, or the terminal closed). Nothing more will
    # ever arrive, and spinning on it would burn a core.
    break
  else
    # A timeout, or a signal: the loop may have started the next iteration.
    repaint
  fi
done
exit 0
