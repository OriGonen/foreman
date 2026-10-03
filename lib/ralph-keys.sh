#!/bin/bash
# The keyboard side of `ralph run`: + and - change the iteration budget while the run is
# going. Started by ralph-loop.sh in the background, on the terminal's stdin, and killed
# when the run exits. Never sourced.
#
#   ralph-keys.sh <ctl-dir> <loop-pid>      read keys until the loop is gone
#   ralph-keys.sh --apply <keys> <ctl-dir>  apply each key in <keys> once, as if pressed
#
#   +  =    one more iteration
#   -  _    one fewer — never below the iteration already running
#
# The two talk through two integer files in <ctl-dir>, so neither has to signal the other:
#   budget     the iteration budget, 0 for unlimited. Seeded by the loop, then written only
#              here (temp file plus mv, so the loop never reads half a number).
#   iteration  the iteration now running, written by the loop. Only read here.
# The loop reads `budget` before each iteration's budget check; a key never touches the
# iteration already running.
#
# The idle loop is builtins only — `read`, `kill -0`, `printf`, `read < file`. No `$(...)`,
# no external commands: a reader waiting on a key starts no processes, which matters under
# MSYS, where starting one is the expensive thing. A key press may spawn one (the `mv`).

# Sets _KEYS_BUDGET and _KEYS_ITERATION from the control files; a missing or garbled file
# reads as 0.
_keys_read_state() {
  local dir="$1"
  _KEYS_BUDGET=0; _KEYS_ITERATION=0
  read -r _KEYS_BUDGET < "$dir/budget" 2>/dev/null
  read -r _KEYS_ITERATION < "$dir/iteration" 2>/dev/null
  [[ "$_KEYS_BUDGET" =~ ^[0-9]+$ ]] || _KEYS_BUDGET=0
  [[ "$_KEYS_ITERATION" =~ ^[0-9]+$ ]] || _KEYS_ITERATION=0
}

# One line on stderr. The leading `\r` plus erase-line takes over whatever in-place line is
# there — the `--live` ticker (ralph-stream.cjs) — which repaints itself on its next tick.
_keys_say() { printf '\r\033[2K   ⌨ %s\n' "$1" >&2; }

# Applies one key to the control files and says what it did. Anything that is not one of
# the four keys is ignored without a word.
keys_apply() {    # keys_apply KEY CTL_DIR
  local key="$1" dir="$2" budget floor
  case "$key" in
    +|=|-|_) ;;
    *) return 0 ;;
  esac
  _keys_read_state "$dir"
  budget="$_KEYS_BUDGET"
  # The iteration already running cannot be cut; before the first one, that is iteration 1.
  floor="$_KEYS_ITERATION"; [ "$floor" -ge 1 ] || floor=1

  case "$key" in
    +|=)
      if [ "$budget" -eq 0 ]; then
        _keys_say "already unlimited"
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

  if [ "$budget" != "$_KEYS_BUDGET" ]; then
    printf '%s\n' "$budget" > "$dir/budget.tmp" && mv -f "$dir/budget.tmp" "$dir/budget"
  fi
  if [ "$budget" -le "$floor" ]; then
    _keys_say "stops after this iteration ($floor of $budget)"
  else
    _keys_say "iterations: $floor of $budget"
  fi
}

if [ "${1:-}" = "--apply" ]; then
  keys="${2:-}" dir="${3:-}"
  [ -d "$dir" ] || { printf 'ralph-keys: no control directory at %s\n' "$dir" >&2; exit 1; }
  for ((i = 0; i < ${#keys}; i++)); do
    keys_apply "${keys:i:1}" "$dir"
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

while kill -0 "$LOOP_PID" 2>/dev/null; do
  key=""
  if read -rsn1 -t 1 key; then
    keys_apply "$key" "$CTL_DIR"
  elif [ $? -le 128 ]; then
    # Not a timeout: stdin is gone (end of file, or the terminal closed). Nothing more will
    # ever arrive, and spinning on it would burn a core.
    break
  fi
done
exit 0
