#!/bin/bash
# Puts `ralph` on your PATH, pointing at this checkout, and installs the
# ralph-human-followup-tickets skill.
#
#   bash install.sh                 install into the first writable directory on PATH
#   bash install.sh --to <dir>      install the shims into <dir> instead
#   bash install.sh --force         overwrite a `ralph` or a skill dir not written by this installer
#   bash install.sh --no-skill      install only the shims, not the skill
#   bash install.sh --uninstall     remove the shims and the skill copy this wrote
#
# It writes two small forwarding scripts, not symlinks — Windows symlinks need elevation
# or developer mode, and a forwarder survives moving this checkout being the only thing
# you have to redo (re-run install.sh).
#
#   <dir>/ralph       for bash / Git Bash / WSL
#   <dir>/ralph.cmd   for PowerShell and cmd.exe
#
# It also copies skills/ralph-human-followup-tickets/ to
# ${CLAUDE_CONFIG_DIR:-~/.claude}/skills/ralph-human-followup-tickets/ — a copy, not a
# symlink, for the same reason the shims are forwarders — marked with a file naming the
# checkout it came from. Re-running install.sh replaces a copy carrying that marker, no
# --force needed: that is how a pulled update is installed. `--to` applies only to the
# shims; the skill always goes under CLAUDE_CONFIG_DIR (or ~/.claude).
#
# Nothing else is installed and nothing is written outside those two locations. The
# toolkit itself stays where you cloned it, and holds no state.
set -uo pipefail

RALPH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_SKILL_NAME="ralph-human-followup-tickets"
RALPH_SKILL_MARKER=".ralph-installed-from"

TARGET=""
FORCE=0
UNINSTALL=0
NO_SKILL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to)        TARGET="${2:-}"; shift ;;
    --force)     FORCE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --no-skill)  NO_SKILL=1 ;;
    --help|-h)   awk 'NR==1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *)           echo "Usage: bash install.sh [--to <dir>] [--force] [--no-skill] [--uninstall]" >&2; exit 1 ;;
  esac
  shift
done

SKILL_HOME_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SKILL_TARGET="$SKILL_HOME_DIR/skills/$RALPH_SKILL_NAME"

# Prefer a personal bin directory that is already on PATH, so nothing has to be added to
# the environment.
#
# On Windows, "already on PATH" has two answers. Git Bash adds ~/bin to its own PATH
# whether or not Windows knows about it, so picking by $PATH alone can land on a directory
# PowerShell cannot see. Check the persistent user PATH first, and only then this shell's.
_ralph_win_path=""
if command -v reg >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
  _ralph_win_path="$(reg query 'HKCU\Environment' /v PATH 2>/dev/null | sed -n 's/.*REG_[A-Z_]*[[:space:]]*//p')"
fi

if [ -z "$TARGET" ] && [ -n "$_ralph_win_path" ]; then
  for candidate in "$HOME/bin" "$HOME/.local/bin"; do
    case ";$_ralph_win_path;" in
      *";$(cygpath -w "$candidate" 2>/dev/null);"*) TARGET="$candidate"; break ;;
    esac
  done
fi
if [ -z "$TARGET" ]; then
  for candidate in "$HOME/bin" "$HOME/.local/bin"; do
    case ":$PATH:" in *":$candidate:"*) TARGET="$candidate"; break ;; esac
  done
fi
if [ -z "$TARGET" ]; then
  TARGET="$HOME/bin"
  echo "note: $TARGET is not on your PATH yet. Installing there anyway — add it with:"
  echo "        setx PATH \"%PATH%;%USERPROFILE%\\bin\"        (once, then reopen the shell)"
  echo
fi

SHIM="$TARGET/ralph"
SHIM_CMD="$TARGET/ralph.cmd"

if [ "$UNINSTALL" -eq 1 ]; then
  removed=0
  for f in "$SHIM" "$SHIM_CMD"; do
    if [ -e "$f" ]; then rm -f "$f" && echo "removed  $f" && removed=1; fi
  done
  [ "$removed" -eq 1 ] || echo "nothing to remove in $TARGET"

  # Only a copy this installer marked — an unmarked directory of the same name is someone
  # else's, and is left alone just like a foreign `ralph` shim would be.
  if [ -f "$SKILL_TARGET/$RALPH_SKILL_MARKER" ]; then
    rm -rf "$SKILL_TARGET" && echo "removed  $SKILL_TARGET"
  elif [ -e "$SKILL_TARGET" ]; then
    echo "left alone  $SKILL_TARGET (not written by this installer)"
  fi

  echo "The toolkit itself is untouched at $RALPH_HOME."
  exit 0
fi

# Both conflicts are checked before either write — including creating $TARGET itself —
# so a refusal never leaves anything behind.
#
# Refuse to clobber someone else's `ralph`, but re-pointing our own shim at a moved
# checkout is the normal case and should not need --force.
if [ -e "$SHIM" ] && [ "$FORCE" -eq 0 ] && ! grep -q 'ralph toolkit shim' "$SHIM" 2>/dev/null; then
  echo "install: $SHIM already exists and was not written by this installer." >&2
  echo "         Move it aside, or re-run with --force." >&2
  exit 1
fi

# Same refusal for the skill directory — unless a marked copy is there, in which case
# replacing it is the normal case (a pulled update) and needs no --force.
if [ "$NO_SKILL" -eq 0 ] && [ -e "$SKILL_TARGET" ] && [ "$FORCE" -eq 0 ] &&
   [ ! -f "$SKILL_TARGET/$RALPH_SKILL_MARKER" ]; then
  echo "install: $SKILL_TARGET already exists and was not written by this installer." >&2
  echo "         Move it aside, or re-run with --force." >&2
  exit 1
fi

mkdir -p "$TARGET" || { echo "install: cannot create $TARGET" >&2; exit 1; }

cat > "$SHIM" <<EOF
#!/bin/bash
# ralph toolkit shim — written by $RALPH_HOME/install.sh. Re-run that to re-point it.
exec bash "$RALPH_HOME/bin/ralph" "\$@"
EOF
chmod +x "$SHIM"

# The Windows shim forwards to bin/ralph.cmd, which is where the "find Git Bash rather
# than the WSL launcher" logic lives — so that logic stays in one place, in the repo.
#
# cmd.exe needs a Windows path, not the shell's own spelling: the shim may be run from
# PowerShell, where nothing translates /c/x. `cygpath -w` ships with Git Bash; the sed is
# for a shell that lacks it.
if command -v cygpath >/dev/null 2>&1; then
  RALPH_HOME_WIN="$(cygpath -w "$RALPH_HOME")"
else
  RALPH_HOME_WIN="$(printf '%s' "$RALPH_HOME" | sed -E 's|^/([A-Za-z])/|\1:/|' | tr '/' '\\')"
fi

# CRLF, deliberately: cmd.exe mis-parses a batch file whose last line has no CR.
# `call`, deliberately: invoking a batch file without it transfers control and never comes
# back, so the exit code would be lost.
printf '%s\r\n' \
  '@echo off' \
  "rem ralph toolkit shim — written by $RALPH_HOME/install.sh. Re-run that to re-point it." \
  "call \"$RALPH_HOME_WIN\\bin\\ralph.cmd\" %*" \
  'exit /b %errorlevel%' \
  > "$SHIM_CMD"

echo "installed"
echo "  $SHIM"
echo "  $SHIM_CMD"
echo "  -> $RALPH_HOME/bin/ralph"
echo

if [ "$NO_SKILL" -eq 0 ]; then
  # A copy, not a symlink — same reason as the shims above. Always replaced wholesale
  # rather than diffed in place, so a file the checkout deleted does not linger.
  rm -rf "$SKILL_TARGET"
  mkdir -p "$SKILL_TARGET" || { echo "install: cannot create $SKILL_TARGET" >&2; exit 1; }
  cp -r "$RALPH_HOME/skills/$RALPH_SKILL_NAME/." "$SKILL_TARGET/"
  printf 'ralph skill copy — written by %s/install.sh. Re-run that to update it.\n' "$RALPH_HOME" \
    > "$SKILL_TARGET/$RALPH_SKILL_MARKER"
  echo "installed skill"
  echo "  $SKILL_TARGET"
  echo "  <- $RALPH_HOME/skills/$RALPH_SKILL_NAME"
  echo
fi

# Git Bash puts ~/bin on its own PATH whether or not Windows knows about it, so the shell
# running this can find `ralph` while PowerShell and cmd.exe still cannot. Check the user's
# persistent PATH in the registry, which is the one they actually inherit.
if [ -n "$_ralph_win_path" ]; then
  target_win="$(cygpath -w "$TARGET")"
  case ";${_ralph_win_path};" in
    *";${target_win};"*) ;;
    *)
      echo "note: $target_win is not on your Windows PATH, so PowerShell and cmd.exe will"
      echo "      not find \`ralph\` (Git Bash will — it adds ~/bin itself). To fix it, once:"
      echo
      echo "        setx PATH \"%PATH%;$target_win\""
      echo
      echo "      then open a new PowerShell. Until then, PowerShell can use the full path:"
      echo "        & \"$target_win\\ralph.cmd\" version"
      echo
      ;;
  esac
fi

if command -v ralph >/dev/null 2>&1 && [ "$(command -v ralph)" = "$SHIM" ]; then
  echo "Ready. Try it:"
else
  echo "Open a new shell, then try it:"
fi
echo "  ralph version"
echo "  cd <any git repo> && ralph doctor"
