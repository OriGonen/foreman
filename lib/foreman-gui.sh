#!/bin/bash
# `foreman gui [<dir>]`: opens the desktop app on the repository that holds <dir> (default: the
# current directory), detached, and returns at once.
#
# The app is `gui/node_modules/electron/dist/electron.exe` in the checkout this toolkit runs from,
# started as `electron.exe <gui directory> <repository>` with both paths in the mixed form Windows
# programs take (`C:/Projects/x`). It is started with no terminal and in its own session, so closing
# the shell that ran this neither closes the app nor waits on it, and nothing here stays running.
#
# <dir> outside any repository is not an error: the app is opened on <dir> anyway, and shows its
# "not a git repo" state, which is where the person picks a folder.
#
# With no app installed it says so and exits 1, and at a terminal (stdin and stdout both) it offers
# to install it — `[y/N]`, by running `install.sh --gui` — and opens the app once that has worked.
#
# The app is looked for where foreman_app_installed looks, beside this file, so a machine that
# has the CLI only and a toolkit copy with a stub app both answer the same way.
set -uo pipefail

# This file's directory, from the shell and not `dirname` (see foreman-config.sh).
FOREMAN_TOOL_DIR="${BASH_SOURCE[0]%/*}"; [ "$FOREMAN_TOOL_DIR" != "${BASH_SOURCE[0]}" ] || FOREMAN_TOOL_DIR=.
FOREMAN_TOOL_DIR="$(cd "${FOREMAN_TOOL_DIR:-/}" && pwd)"
# shellcheck source=foreman-repo.sh
source "$FOREMAN_TOOL_DIR/foreman-repo.sh"

usage() { echo "Usage: foreman gui [<dir>]" >&2; }

DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) echo "Usage: foreman gui [<dir>]"; echo "  Opens the desktop app on the repository that holds <dir> (default: here)."; exit 0 ;;
    -*)        echo "foreman gui: unknown option '$1'" >&2; usage; exit 1 ;;
    *)         if [ -n "$DIR" ]; then usage; exit 1; fi; DIR="$1" ;;
  esac
  shift
done
DIR="${DIR:-.}"

if [ ! -d "$DIR" ]; then
  echo "foreman gui: '$DIR' is not a directory" >&2
  exit 1
fi

TOOLKIT="$(cd "$FOREMAN_TOOL_DIR/.." && pwd)"
APP_DIR="$TOOLKIT/gui"
ELECTRON_DIST="$APP_DIR/node_modules/electron/dist"

# The executable Electron put there: electron.exe on Windows, `electron` elsewhere. Empty when there
# is none, whether the app was never installed or its install is half there.
find_exe() {
  EXE=""
  local f
  for f in "$ELECTRON_DIST/electron.exe" "$ELECTRON_DIST/electron"; do
    if [ -f "$f" ] && [ -x "$f" ]; then EXE="$f"; return 0; fi
  done
  return 1
}

if ! find_exe; then
  if foreman_app_installed; then
    echo "foreman gui: the desktop app is incomplete (no electron.exe under gui/node_modules). Repair it with: bash $TOOLKIT/install.sh --gui" >&2
  else
    echo "foreman gui: the desktop app is not installed. Install it with: bash $TOOLKIT/install.sh --gui" >&2
  fi
  # A conversation needs both sides on a terminal; anywhere else this is the whole answer.
  if [ -t 0 ] && [ -t 1 ]; then
    printf 'Install it now? [y/N] ' >&2
    ans=""; read -r ans || ans=""
    case "$ans" in
      [yY]|[yY][eE][sS]) ;;
      *) exit 1 ;;
    esac
    echo >&2
    bash "$TOOLKIT/install.sh" --gui || exit $?
    if ! find_exe; then
      echo "foreman gui: the install finished but the desktop app is still not there." >&2
      exit 1
    fi
  else
    exit 1
  fi
fi

# The repository that holds DIR, or DIR itself when none does.
cd "$DIR" || exit 1
if TARGET="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$TARGET" ]; then :; else TARGET="$PWD"; fi
foreman_mixed_path TARGET_ARG "$TARGET"
foreman_mixed_path APP_ARG "$APP_DIR"

# Detached: its own session where there is `setsid`, deaf to a hangup (`nohup`), no stdin, and stdout
# and stderr gone, so that a caller capturing this command's output is not kept waiting on the app,
# and a Ctrl-C or the terminal closing does not reach it. The subshell is so no job is left behind to be waited on. Electron run
# as node (ELECTRON_RUN_AS_NODE, which some terminals set for their own sake) would not open a window.
(
  unset ELECTRON_RUN_AS_NODE
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "$EXE" "$APP_ARG" "$TARGET_ARG" </dev/null >/dev/null 2>&1 &
  else
    nohup "$EXE" "$APP_ARG" "$TARGET_ARG" </dev/null >/dev/null 2>&1 &
  fi
)
exit 0
