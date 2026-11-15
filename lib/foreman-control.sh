#!/bin/bash
# Steers a run that is in flight from outside its terminal: `foreman keys` and `foreman stop`.
#
#   foreman keys <batch> <+|-|L>...      press keys, as if in the run's terminal
#   foreman stop [<batch>]               finish the iteration in flight, then pause
#   foreman stop --now [<batch>]         end the run at once, as Ctrl-C in its terminal does
#
# Both work through the run's control directory (see foreman-keys.sh) and nothing else: the keys
# are applied by `foreman-keys.sh --apply`, so a key does exactly what it does in the terminal, and
# stop is `foreman-keys.sh --stop`, which sets the budget to the iteration in flight — the run
# finishes it and ends with exit 10, "budget reached", as pressing - down to it would. Both are free:
# nothing is sent to an agent.
#
#   +  =    one more iteration
#   -  _    one fewer — never below the iteration already running
#   L  l    live view on / off
#
# They can only reach a run whose control directory is `<batch>/.foreman-run/`, which is where the
# loop puts it when the repository ignores `**/.foreman-run/` (see foreman-loop.sh). Without a run
# in flight there, each exits 1 with one line saying so. A run is in flight when the pid in the
# directory's `pid` file is alive.
#
# `stop --now` is for a run that has no terminal to press Ctrl-C in: the app starts it detached, with
# no console. Ctrl-C does three things, and this does the same three from outside, keeping the loop's
# own INT handling (on_interrupt in foreman-loop.sh) for what happens after:
#
#   1. a `stop` file in the control directory, which the loop reads once its agent's turn is over
#      (check_stop_file) and answers with the same on_interrupt. It is what carries the stop when a
#      signal cannot: a loop that was started by a script's `&` ignores SIGINT from its birth.
#   2. SIGINT to the loop and to everything below it — the agent, the feed, whatever the agent ran —
#      which is what the terminal sends to the whole foreground group. Where a program cannot take
#      the signal (MSYS cannot hand one to a native Windows process) this does nothing to it.
#   3. after FOREMAN_STOP_GRACE seconds (default 5), whatever below the loop is still running is
#      ended hard: `taskkill /F /T` on its Windows pid where there is one (that takes a native
#      process's own children with it), `kill -9` otherwise. Never the loop itself: that would skip its
#      INT handling, and with it the footer, the record and the stall marker.
#
# Then it waits up to FOREMAN_STOP_WAIT seconds (default 60) for the loop to finish its bookkeeping
# and exit, and exits 0 once it has. If the loop is still there, it says so and exits 1; it does not
# kill it. The run's exit code is Ctrl-C's: 10, paused, and the next run's review turn picks the
# ticket up. See .scratch/gui/notes/09-stop-now.md for what was tried.
set -uo pipefail

# This file's directory, from the shell and not `dirname` (see foreman-config.sh).
FOREMAN_TOOL_DIR="${BASH_SOURCE[0]%/*}"; [ "$FOREMAN_TOOL_DIR" != "${BASH_SOURCE[0]}" ] || FOREMAN_TOOL_DIR=.
FOREMAN_TOOL_DIR="$(cd "${FOREMAN_TOOL_DIR:-/}" && pwd)"

CMD="${1:-}"
[ $# -gt 0 ] && shift

BATCH_INPUT=""
KEYS=""
NOW=0
case "$CMD" in
  keys)
    # The first word is the batch and the rest are keys. A key is never mistaken for an option:
    # `-` is one of them.
    if [ $# -lt 2 ]; then
      echo "Usage: foreman keys <batch> <+|-|L>..." >&2
      exit 1
    fi
    BATCH_INPUT="$1"; shift
    while [ $# -gt 0 ]; do KEYS+="$1"; shift; done
    if ! [[ "$KEYS" =~ ^[-+=_Ll]+$ ]]; then
      echo "foreman keys: the keys are + (one more iteration), - (one fewer) and L (live view on/off), not '$KEYS'" >&2
      exit 1
    fi
    ;;
  stop)
    while [ $# -gt 0 ]; do
      case "$1" in
        --now) NOW=1 ;;
        -*) echo "Usage: foreman stop [<batch>] [--now]" >&2; exit 1 ;;
        *) BATCH_INPUT="$1" ;;
      esac
      shift
    done
    ;;
  *)
    echo "Usage: foreman keys <batch> <+|-|L>...  |  foreman stop [<batch>] [--now]" >&2
    exit 1
    ;;
esac

# Which batch, as every command resolves it: an omitted one is the only batch in the repository.
[ -z "$BATCH_INPUT" ] || export FOREMAN_BATCH="$BATCH_INPUT"
# shellcheck source=foreman-config.sh
source "$FOREMAN_TOOL_DIR/foreman-config.sh" || exit 1

CTL="$REPO_ROOT/$BATCH_DIR/.foreman-run"
[ "$BATCH_DIR" != . ] || CTL="$REPO_ROOT/.foreman-run"

loop_pid=""
read -r loop_pid _ 2>/dev/null < "$CTL/pid"
if ! [[ "$loop_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$loop_pid" 2>/dev/null; then
  echo "foreman $CMD: no run in flight in $BATCH_DIR, or its control directory is not in the batch (that needs **/.foreman-run/ in .gitignore)" >&2
  exit 1
fi

# Every pid below $1 (its children, theirs, and so on), one per line, deepest last. From /proc, which
# MSYS has too (and shows a native process under the MSYS process that started it); `ps` where there
# is none. Read with builtins: this runs once, and a few hundred small reads are cheaper than starting
# a process per process.
stop_descendants() {    # stop_descendants PID
  local root="$1" p line rest a b i grew
  local -a all=() par=() found=("$root")
  if [ -r /proc/self/stat ]; then
    for p in /proc/[0-9]*; do
      p="${p#/proc/}"
      read -r line 2>/dev/null < "/proc/$p/stat" || continue
      rest="${line##*) }"
      read -r a b _ <<< "$rest"
      [[ "$b" =~ ^[0-9]+$ ]] || continue
      all+=("$p"); par+=("$b")
    done
  else
    while read -r a b; do
      [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]] || continue
      all+=("$a"); par+=("$b")
    done < <(ps -A -o pid= -o ppid= 2>/dev/null)
  fi
  grew=1
  while [ "$grew" -eq 1 ]; do
    grew=0
    for i in "${!all[@]}"; do
      [ -n "${all[$i]}" ] || continue
      for p in "${found[@]}"; do
        if [ "${par[$i]}" = "$p" ]; then
          found+=("${all[$i]}"); printf '%s\n' "${all[$i]}"
          all[i]=""; grew=1
          break
        fi
      done
    done
  done
}

# Ends PID without its signal handlers: the Windows way where it has a Windows pid (and takes the
# native children of a native process with it), `kill -9` where it has not.
stop_force() {    # stop_force PID
  local winpid=""
  read -r winpid 2>/dev/null < "/proc/$1/winpid"
  if [[ "$winpid" =~ ^[0-9]+$ ]] && command -v taskkill >/dev/null 2>&1; then
    MSYS_NO_PATHCONV=1 taskkill /F /T /PID "$winpid" >/dev/null 2>&1
  fi
  kill -9 "$1" 2>/dev/null
  return 0
}

# Whether any of the pids is still running.
stop_any_alive() {
  local p
  for p in "$@"; do kill -0 "$p" 2>/dev/null && return 0; done
  return 1
}

stop_now() {
  local grace="${FOREMAN_STOP_GRACE:-5}" wait_s="${FOREMAN_STOP_WAIT:-60}" n p
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=5
  [[ "$wait_s" =~ ^[0-9]+$ ]] || wait_s=60
  local -a below=() left=()

  # 1. The file first, so that a loop that gets there before the signal still finds it.
  printf '%s\n' "$$" > "$CTL/stop.tmp" && mv -f "$CTL/stop.tmp" "$CTL/stop" ||
    { echo "foreman stop: could not write $CTL/stop" >&2; exit 1; }

  # 2. The signal, to the loop and to everything under it, as the terminal sends it to its group.
  mapfile -t below < <(stop_descendants "$loop_pid")
  kill -INT "$loop_pid" 2>/dev/null
  for p in ${below[@]+"${below[@]}"}; do kill -INT "$p" 2>/dev/null; done

  # 3. Whatever has not taken it by the end of the grace period is ended. Early if nothing is left.
  n=$((grace * 5))
  while [ "$n" -gt 0 ] && kill -0 "$loop_pid" 2>/dev/null && stop_any_alive ${below[@]+"${below[@]}"}; do
    sleep 0.2
    n=$((n - 1))
  done
  for p in ${below[@]+"${below[@]}"}; do
    kill -0 "$loop_pid" 2>/dev/null || break
    kill -0 "$p" 2>/dev/null && stop_force "$p"
  done

  # The loop does its own bookkeeping now: records the turn, writes the footer, leaves the marker.
  n=$((wait_s * 5))
  while [ "$n" -gt 0 ] && kill -0 "$loop_pid" 2>/dev/null; do
    sleep 0.2
    n=$((n - 1))
  done
  if kill -0 "$loop_pid" 2>/dev/null; then
    echo "foreman stop: the run in $BATCH_DIR was told to stop but is still finishing after ${wait_s}s (pid $loop_pid); it has not been killed" >&2
    exit 1
  fi
  echo "foreman stop: stopped the run in $BATCH_DIR (paused, as Ctrl-C does)"
}

case "$CMD" in
  keys) exec bash "$FOREMAN_TOOL_DIR/foreman-keys.sh" --apply "$KEYS" "$CTL" ;;
  stop)
    if [ "$NOW" -eq 1 ]; then
      stop_now
      exit 0
    fi
    exec bash "$FOREMAN_TOOL_DIR/foreman-keys.sh" --stop "$CTL"
    ;;
esac
