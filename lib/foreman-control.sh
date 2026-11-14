#!/bin/bash
# Steers a run that is in flight from outside its terminal: `foreman keys` and `foreman stop`.
#
#   foreman keys <batch> <+|-|L>...      press keys, as if in the run's terminal
#   foreman stop [<batch>]               finish the iteration in flight, then pause
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
# `foreman stop --now`, which acts as Ctrl-C does, is not here yet.
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
        -*) echo "Usage: foreman stop [<batch>]" >&2; exit 1 ;;
        *) BATCH_INPUT="$1" ;;
      esac
      shift
    done
    if [ "$NOW" -eq 1 ]; then
      echo "foreman stop: --now is not available yet" >&2
      exit 1
    fi
    ;;
  *)
    echo "Usage: foreman keys <batch> <+|-|L>...  |  foreman stop [<batch>]" >&2
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

case "$CMD" in
  keys) exec bash "$FOREMAN_TOOL_DIR/foreman-keys.sh" --apply "$KEYS" "$CTL" ;;
  stop) exec bash "$FOREMAN_TOOL_DIR/foreman-keys.sh" --stop "$CTL" ;;
esac
