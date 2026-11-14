#!/bin/bash
# Puts `foreman` on your PATH, pointing at this checkout, and installs foreman's skills.
#
#   bash install.sh                 install into the first writable directory on PATH
#   bash install.sh --to <dir>      install the shims into <dir> instead
#   bash install.sh --force         overwrite a `foreman` or a skill dir not written by this installer
#   bash install.sh --no-skill      install only the shims, not the skills
#   bash install.sh --gui           also install the desktop app (npm ci in gui/, and a
#                                   Start-menu shortcut), without asking
#   bash install.sh --no-gui        install the CLI only, and remove the app and its shortcut
#                                   if they are there, without asking
#   bash install.sh --uninstall     remove the shims, the skill copies, the app and its shortcut
#
# With neither --gui nor --no-gui, it asks one question — CLI only, or CLI and the desktop
# app — when both stdin and stdout are terminals, and the app is not already installed. Anywhere
# else (a pipe, CI, a test's capture) it asks nothing and installs the CLI, as it always did.
# Whether the app is installed is read from disk: gui/node_modules/electron, and the shortcut.
#
# It writes two small forwarding scripts, not symlinks — Windows symlinks need elevation
# or developer mode, and a forwarder survives moving this checkout being the only thing
# you have to redo (re-run install.sh).
#
#   <dir>/foreman       for bash / Git Bash / WSL
#   <dir>/foreman.cmd   for PowerShell and cmd.exe
#
# It also copies each skills/<name>/ to ${CLAUDE_CONFIG_DIR:-~/.claude}/skills/<name>/ — a
# copy, not a symlink, for the same reason the shims are forwarders — marked with a file
# naming the checkout it came from. Re-running install.sh replaces a copy carrying that
# marker, no --force needed: that is how a pulled update is installed. `--to` applies only to
# the shims; the skills always go under CLAUDE_CONFIG_DIR (or ~/.claude). They are:
#
#   foreman-human-followup-tickets   you type it, after to-tickets and before `foreman init`
#   foreman-conf-commands            `foreman init` runs it, to fill in foreman.conf's commands
#
# The desktop app, when you ask for it, is `npm ci` in this checkout's gui/ (which writes only
# gui/node_modules) and, on Windows, a shortcut at
# %APPDATA%\Microsoft\Windows\Start Menu\Programs\Foreman.lnk, written through
# powershell.exe and WScript.Shell. --uninstall and --no-gui remove both.
#
# Nothing else is installed and nothing is written outside those locations. The toolkit itself
# stays where you cloned it, and holds no state. --uninstall touches no batch, no
# ~/.config/foreman/env and no credential.
set -uo pipefail

FOREMAN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOREMAN_SKILL_MARKER=".foreman-installed-from"

# Every skill this checkout ships: a directory under skills/ with a SKILL.md in it. An empty
# directory left behind by a rename is not one.
FOREMAN_SKILL_NAMES=()
for _foreman_skill_md in "$FOREMAN_HOME"/skills/*/SKILL.md; do
  [ -f "$_foreman_skill_md" ] || continue
  _foreman_skill_dir="${_foreman_skill_md%/SKILL.md}"
  FOREMAN_SKILL_NAMES+=("${_foreman_skill_dir##*/}")
done

TARGET=""
FORCE=0
UNINSTALL=0
NO_SKILL=0
GUI_ON=0      # --gui
GUI_OFF=0     # --no-gui
while [ $# -gt 0 ]; do
  case "$1" in
    --to)        TARGET="${2:-}"; shift ;;
    --force)     FORCE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --no-skill)  NO_SKILL=1 ;;
    --gui)       GUI_ON=1 ;;
    --no-gui)    GUI_OFF=1 ;;
    --help|-h)   awk 'NR==1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *)           echo "Usage: bash install.sh [--to <dir>] [--force] [--no-skill] [--gui | --no-gui] [--uninstall]" >&2; exit 1 ;;
  esac
  shift
done

if [ "$GUI_ON" -eq 1 ] && [ "$GUI_OFF" -eq 1 ]; then
  echo "install: --gui and --no-gui contradict each other; give one." >&2
  exit 1
fi

# On Windows, a plain `bash` in PowerShell is often the WSL launcher, not Git Bash. It runs
# this script inside WSL, which installs into the WSL home — a place Windows Claude Code and
# PowerShell cannot see — and nothing looks wrong. Say so. A warning, not a refusal:
# installing for WSL itself is legitimate, and nothing here changes what is installed.
# FOREMAN_PROC_VERSION stands in for /proc/version so the test can fake the signal.
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft "${FOREMAN_PROC_VERSION:-/proc/version}" 2>/dev/null; then
  echo "warning: this is running under WSL, so everything below goes into the WSL home,"
  echo "         $HOME — not your Windows home. Windows Claude Code and PowerShell"
  echo "         will not see it. To install for Windows, run this from PowerShell:"
  echo
  echo "           & \"C:\\Program Files\\Git\\bin\\bash.exe\" install.sh"
  echo
  echo "         or from Git Bash: bash install.sh. (Installing for WSL itself? Carry on.)"
  echo
fi

SKILL_HOME_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Prefer a personal bin directory that is already on PATH, so nothing has to be added to
# the environment.
#
# On Windows, "already on PATH" has two answers. Git Bash adds ~/bin to its own PATH
# whether or not Windows knows about it, so picking by $PATH alone can land on a directory
# PowerShell cannot see. Check the persistent user PATH first, and only then this shell's.
_foreman_win_path=""
if command -v reg >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
  _foreman_win_path="$(reg query 'HKCU\Environment' /v PATH 2>/dev/null | sed -n 's/.*REG_[A-Z_]*[[:space:]]*//p')"
fi

if [ -z "$TARGET" ] && [ -n "$_foreman_win_path" ]; then
  for candidate in "$HOME/bin" "$HOME/.local/bin"; do
    case ";$_foreman_win_path;" in
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

SHIM="$TARGET/foreman"
SHIM_CMD="$TARGET/foreman.cmd"

# legacy: before the rename to Foreman this installed `ralph`, `ralph.cmd` and the
# ralph-human-followup-tickets skill. Install and --uninstall both remove them — but only a
# shim that says it is this installer's and forwards to this checkout, and only a skill copy
# carrying the old marker, exactly as for the new names.
_foreman_legacy_cleanup() {
  local f home_win
  home_win="$(cygpath -w "$FOREMAN_HOME" 2>/dev/null || printf '%s' "$FOREMAN_HOME")"
  for f in "$TARGET/ralph" "$TARGET/ralph.cmd"; do
    [ -e "$f" ] && grep -q 'ralph toolkit shim' "$f" 2>/dev/null || continue
    grep -qF -e "$FOREMAN_HOME" -e "$home_win" "$f" 2>/dev/null || continue
    rm -f "$f" && echo "removed  $f (from before the rename to Foreman)"
  done
  f="$SKILL_HOME_DIR/skills/ralph-human-followup-tickets"
  if [ -f "$f/.ralph-installed-from" ]; then
    rm -rf "$f" && echo "removed  $f (from before the rename to Foreman)"
  fi
}

# ---------------------------------------------------------------------------------------
# The desktop app: gui/node_modules (npm ci) and a Start-menu shortcut.
# ---------------------------------------------------------------------------------------
GUI_DIR="$FOREMAN_HOME/gui"
ELECTRON_DIR="$GUI_DIR/node_modules/electron"

# The shortcut, as this shell spells it: %APPDATA%\Microsoft\Windows\Start Menu\Programs\Foreman.lnk.
# Empty when there is no %APPDATA% (not Windows), and so no shortcut to write or look for.
SHORTCUT=""
if [ -n "${APPDATA:-}" ]; then
  _foreman_appdata="$APPDATA"
  if command -v cygpath >/dev/null 2>&1; then _foreman_appdata="$(cygpath -u "$APPDATA" 2>/dev/null || printf '%s' "$APPDATA")"; fi
  SHORTCUT="$_foreman_appdata/Microsoft/Windows/Start Menu/Programs/Foreman.lnk"
fi

# A path as Windows spells it, for the one program that is not bash. cygpath ships with Git Bash.
_foreman_winpath() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# Whether the shortcut is part of "installed": only where it could have been written.
_foreman_can_shortcut() { [ -n "$SHORTCUT" ] && command -v powershell.exe >/dev/null 2>&1; }

# Success when the app is installed, read from disk: electron under gui/node_modules, and the
# shortcut where a shortcut can be written. Either one missing is a piece to offer again.
_foreman_app_installed() {
  [ -d "$ELECTRON_DIR" ] || return 1
  _foreman_can_shortcut || return 0
  [ -e "$SHORTCUT" ]
}

# Removes what the app put on the machine: gui/node_modules and the shortcut. Nothing else.
_foreman_remove_app() {
  if [ -e "$GUI_DIR/node_modules" ] || [ -L "$GUI_DIR/node_modules" ]; then
    rm -rf "$GUI_DIR/node_modules" && echo "removed  $GUI_DIR/node_modules"
  fi
  if [ -n "$SHORTCUT" ] && [ -e "$SHORTCUT" ]; then
    rm -f "$SHORTCUT" && echo "removed  $SHORTCUT"
  fi
}

# Writes the Start-menu shortcut through powershell.exe and WScript.Shell. The values go in as
# environment variables, so no path is ever spliced into the PowerShell text. The target is the
# checkout's electron.exe, its argument the gui directory (quoted: a checkout may live under a
# path with spaces), its icon gui\icon.ico.
_foreman_write_shortcut() {
  local exe="$ELECTRON_DIR/dist/electron.exe" ps_script
  if [ -z "$SHORTCUT" ] || ! command -v powershell.exe >/dev/null 2>&1; then
    echo "note: no Start-menu shortcut — that needs Windows (powershell.exe was not found)."
    return 0
  fi
  mkdir -p "${SHORTCUT%/*}" 2>/dev/null
  ps_script='$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:FOREMAN_LNK); '
  ps_script+='$s.TargetPath = $env:FOREMAN_TARGET; $s.Arguments = $env:FOREMAN_ARGS; '
  ps_script+='$s.WorkingDirectory = $env:FOREMAN_WORKDIR; $s.IconLocation = $env:FOREMAN_ICON; '
  ps_script+="\$s.Description = 'Foreman'; \$s.Save()"
  FOREMAN_LNK="$(_foreman_winpath "$SHORTCUT")" \
  FOREMAN_TARGET="$(_foreman_winpath "$exe")" \
  FOREMAN_ARGS="\"$(_foreman_winpath "$GUI_DIR")\"" \
  FOREMAN_WORKDIR="$(_foreman_winpath "$FOREMAN_HOME")" \
  FOREMAN_ICON="$(_foreman_winpath "$GUI_DIR/icon.ico")" \
    powershell.exe -NoProfile -NonInteractive -Command "$ps_script" >/dev/null 2>&1
  if [ -e "$SHORTCUT" ]; then
    echo "installed shortcut"
    echo "  $SHORTCUT"
    echo "  -> $exe"
  else
    echo "install: the Start-menu shortcut was not written ($SHORTCUT)." >&2
    return 1
  fi
}

# Installs the app: npm ci in gui/, then the shortcut. Without npm it says so and leaves the
# CLI as it is — the CLI is already installed by now. A failure is reported and makes the
# installer exit 1 at the end, after everything else has been done.
APP_FAILED=0
_foreman_install_app() {
  if ! command -v npm >/dev/null 2>&1; then
    echo "note: the desktop app needs Node's npm, and npm is not on your PATH. Installed the CLI only."
    echo "      Install Node from https://nodejs.org, open a new shell, then: bash $FOREMAN_HOME/install.sh --gui"
    echo
    return 0
  fi
  echo "installing the desktop app: npm ci in $GUI_DIR (about 250 MB, this takes a minute)"
  if ! (cd "$GUI_DIR" && npm ci); then
    echo "install: npm ci failed in $GUI_DIR, so the desktop app is not installed. The CLI is." >&2
    APP_FAILED=1
    return 0
  fi
  if [ ! -d "$ELECTRON_DIR" ]; then
    echo "install: npm ci finished but $ELECTRON_DIR is not there, so the desktop app is not installed." >&2
    APP_FAILED=1
    return 0
  fi
  echo "installed the desktop app"
  echo "  $ELECTRON_DIR"
  _foreman_write_shortcut || APP_FAILED=1
  echo
}

# ---------------------------------------------------------------------------------------
# The question. Asked only when stdin and stdout are both terminals, so a pipe, CI and a
# test's capture never see it. The header is fixed lines — no node — drawn only at the 24-bit
# or 256-colour tier in a terminal at least 80 columns wide; anywhere else the same words
# are plain lines. It is the picture lib/foreman-draw.cjs draws from the pixel map in
# .scratch/gui/designs/10-install-wizard.html, 12 rows by 36 columns; test/smoke-json.sh checks
# these lines against it.
# ---------------------------------------------------------------------------------------
_foreman_header_rows() {    # _foreman_header_rows TIER — fills HEADER_ROWS
  if [ "$1" = 24 ]; then
    mapfile -t HEADER_ROWS <<'ROWS24'
           \e[0;38;2;48;35;26m▄▄▄\e[0;38;2;58;42;24m▄▄▄\e[0;38;2;48;35;26m▄▄▄\e[0m
        \e[0;38;2;48;35;26m▄▄\e[0;38;2;48;35;26;48;2;58;42;24m▀\e[0;38;2;58;42;24m█\e[0;38;2;58;42;24;48;2;201;119;47m▀▀▀▀▀▀▀\e[0;38;2;58;42;24m█\e[0;38;2;48;35;26;48;2;58;42;24m▀\e[0;38;2;48;35;26m▄▄\e[0m
       \e[0;38;2;48;35;26m▄\e[0;38;2;48;35;26;48;2;58;42;24m▀\e[0;38;2;58;42;24;48;2;201;119;47m▀\e[0;38;2;201;119;47m█\e[0;38;2;201;119;47;48;2;224;168;74m▀\e[0;38;2;224;168;74m███████\e[0;38;2;201;119;47;48;2;224;168;74m▀\e[0;38;2;201;119;47m█\e[0;38;2;58;42;24;48;2;201;119;47m▀\e[0;38;2;48;35;26;48;2;58;42;24m▀\e[0;38;2;48;35;26m▄\e[0m
      \e[0;38;2;48;35;26m█\e[0;38;2;58;42;24m█\e[0;38;2;58;42;24;48;2;201;119;47m▀\e[0;38;2;201;119;47;48;2;224;168;74m▀\e[0;38;2;224;168;74m██\e[0;38;2;224;168;74;48;2;246;213;142m▀▀\e[0;38;2;246;213;142m███\e[0;38;2;224;168;74;48;2;246;213;142m▀▀\e[0;38;2;224;168;74m██\e[0;38;2;201;119;47;48;2;224;168;74m▀\e[0;38;2;58;42;24;48;2;201;119;47m▀\e[0;38;2;58;42;24m█\e[0;38;2;48;35;26m█\e[0m
      \e[0;38;2;48;35;26;48;2;58;42;24m▀\e[0;38;2;58;42;24m█\e[0;38;2;201;119;47m█\e[0;38;2;224;168;74m██\e[0;38;2;224;168;74;48;2;246;213;142m▀\e[0;38;2;246;213;142m███\e[0;38;2;246;213;142;48;2;10;9;8m▀\e[0;38;2;10;9;8m███\e[0;38;2;224;168;74;48;2;10;9;8m▀\e[0;38;2;224;168;74m██\e[0;38;2;201;119;47m█\e[0;38;2;58;42;24m█\e[0;38;2;48;35;26;48;2;58;42;24m▀\e[0m
      \e[0;38;2;58;42;24m██\e[0;38;2;201;119;47m█\e[0;38;2;224;168;74m██\e[0;38;2;246;213;142m██\e[0;38;2;10;9;8;48;2;246;213;142m▀▀▀\e[0;38;2;10;9;8m███\e[0;38;2;10;9;8;48;2;246;213;142m▀\e[0;38;2;10;9;8;48;2;224;168;74m▀▀\e[0;38;2;201;119;47m█\e[0;38;2;58;42;24m██\e[0m
      \e[0;38;2;48;35;26m█\e[0;38;2;58;42;24m█\e[0;38;2;201;119;47m█\e[0;38;2;224;168;74m███\e[0;38;2;246;213;142m██\e[0;38;2;246;213;142;48;2;10;9;8m▀▀\e[0;38;2;10;9;8m███\e[0;38;2;224;168;74;48;2;10;9;8m▀▀\e[0;38;2;224;168;74m█\e[0;38;2;201;119;47m█\e[0;38;2;58;42;24m█\e[0;38;2;48;35;26m█\e[0m
      \e[0;38;2;48;35;26m▀\e[0;38;2;58;42;24;48;2;48;35;26m▀\e[0;38;2;58;42;24m█\e[0;38;2;201;119;47m█\e[0;38;2;224;168;74;48;2;201;119;47m▀\e[0;38;2;224;168;74m█\e[0;38;2;224;168;74;48;2;10;9;8m▀\e[0;38;2;10;9;8m█\e[0;38;2;10;9;8;48;2;224;168;74m▀\e[0;38;2;246;213;142;48;2;224;168;74m▀\e[0;38;2;10;9;8m███\e[0;38;2;224;168;74m█\e[0;38;2;10;9;8;48;2;201;119;47m▀\e[0;38;2;10;9;8m█\e[0;38;2;58;42;24;48;2;10;9;8m▀\e[0;38;2;58;42;24;48;2;48;35;26m▀\e[0;38;2;48;35;26m▀\e[0m
        \e[0;38;2;48;35;26m█\e[0;38;2;58;42;24;48;2;48;35;26m▀\e[0;38;2;201;119;47;48;2;58;42;24m▀▀\e[0;38;2;224;168;74;48;2;201;119;47m▀\e[0;38;2;10;9;8;48;2;201;119;47m▀▀\e[0;38;2;224;168;74;48;2;10;9;8m▀\e[0;38;2;10;9;8m███\e[0;38;2;201;119;47;48;2;10;9;8m▀\e[0;38;2;10;9;8;48;2;58;42;24m▀\e[0;38;2;10;9;8;48;2;48;35;26m▀\e[0;38;2;48;35;26m█\e[0m
\e[0;38;2;58;42;24m▄▄\e[0;38;2;138;90;36m▄▄▄\e[0;38;2;201;119;47m▄▄▄▄\e[0;38;2;224;168;74m▄\e[0;38;2;48;35;26;48;2;224;168;74m▀\e[0;38;2;58;42;24;48;2;224;168;74m▀▀▀\e[0;38;2;58;42;24;48;2;10;9;8m▀\e[0;38;2;10;9;8m█\e[0;38;2;10;9;8;48;2;224;168;74m▀\e[0;38;2;58;42;24;48;2;224;168;74m▀\e[0;38;2;10;9;8;48;2;224;168;74m▀\e[0;38;2;10;9;8m█\e[0;38;2;48;35;26;48;2;10;9;8m▀\e[0;38;2;224;168;74m▄\e[0;38;2;201;119;47m▄▄▄▄\e[0;38;2;138;90;36m▄▄▄\e[0;38;2;58;42;24m▄▄\e[0;38;2;48;35;26m▄▄▄▄▄\e[0m
\e[0;38;2;48;35;26;48;2;28;26;23m▀▀\e[0;38;2;58;42;24;48;2;48;35;26m▀▀▀\e[0;38;2;138;90;36;48;2;58;42;24m▀▀▀▀\e[0;38;2;201;119;47;48;2;138;90;36m▀▀▀▀\e[0;38;2;10;9;8m██\e[0;38;2;201;119;47;48;2;138;90;36m▀▀▀▀▀\e[0;38;2;10;9;8m██\e[0;38;2;138;90;36;48;2;58;42;24m▀▀▀▀\e[0;38;2;58;42;24;48;2;48;35;26m▀▀▀\e[0;38;2;48;35;26;48;2;28;26;23m▀▀\e[0;38;2;28;26;23m▀▀▀▀▀\e[0m
  \e[0;38;2;28;26;23m▀▀▀\e[0;38;2;48;35;26;48;2;28;26;23m▀▀▀▀\e[0;38;2;58;42;24;48;2;48;35;26m▀▀▀▀▀▀\e[0;38;2;10;9;8;48;2;48;35;26m▀\e[0;38;2;10;9;8m█\e[0;38;2;58;42;24;48;2;10;9;8m▀▀▀\e[0;38;2;10;9;8m███\e[0;38;2;48;35;26;48;2;10;9;8m▀▀▀\e[0;38;2;28;26;23m▀▀▀\e[0m
ROWS24
  else
    mapfile -t HEADER_ROWS <<'ROWS256'
           \e[0;38;5;235m▄▄▄\e[0;38;5;235m▄▄▄\e[0;38;5;235m▄▄▄\e[0m
        \e[0;38;5;235m▄▄\e[0;38;5;235;48;5;235m▀\e[0;38;5;235m█\e[0;38;5;235;48;5;172m▀▀▀▀▀▀▀\e[0;38;5;235m█\e[0;38;5;235;48;5;235m▀\e[0;38;5;235m▄▄\e[0m
       \e[0;38;5;235m▄\e[0;38;5;235;48;5;235m▀\e[0;38;5;235;48;5;172m▀\e[0;38;5;172m█\e[0;38;5;172;48;5;179m▀\e[0;38;5;179m███████\e[0;38;5;172;48;5;179m▀\e[0;38;5;172m█\e[0;38;5;235;48;5;172m▀\e[0;38;5;235;48;5;235m▀\e[0;38;5;235m▄\e[0m
      \e[0;38;5;235m█\e[0;38;5;235m█\e[0;38;5;235;48;5;172m▀\e[0;38;5;172;48;5;179m▀\e[0;38;5;179m██\e[0;38;5;179;48;5;222m▀▀\e[0;38;5;222m███\e[0;38;5;179;48;5;222m▀▀\e[0;38;5;179m██\e[0;38;5;172;48;5;179m▀\e[0;38;5;235;48;5;172m▀\e[0;38;5;235m█\e[0;38;5;235m█\e[0m
      \e[0;38;5;235;48;5;235m▀\e[0;38;5;235m█\e[0;38;5;172m█\e[0;38;5;179m██\e[0;38;5;179;48;5;222m▀\e[0;38;5;222m███\e[0;38;5;222;48;5;232m▀\e[0;38;5;232m███\e[0;38;5;179;48;5;232m▀\e[0;38;5;179m██\e[0;38;5;172m█\e[0;38;5;235m█\e[0;38;5;235;48;5;235m▀\e[0m
      \e[0;38;5;235m██\e[0;38;5;172m█\e[0;38;5;179m██\e[0;38;5;222m██\e[0;38;5;232;48;5;222m▀▀▀\e[0;38;5;232m███\e[0;38;5;232;48;5;222m▀\e[0;38;5;232;48;5;179m▀▀\e[0;38;5;172m█\e[0;38;5;235m██\e[0m
      \e[0;38;5;235m█\e[0;38;5;235m█\e[0;38;5;172m█\e[0;38;5;179m███\e[0;38;5;222m██\e[0;38;5;222;48;5;232m▀▀\e[0;38;5;232m███\e[0;38;5;179;48;5;232m▀▀\e[0;38;5;179m█\e[0;38;5;172m█\e[0;38;5;235m█\e[0;38;5;235m█\e[0m
      \e[0;38;5;235m▀\e[0;38;5;235;48;5;235m▀\e[0;38;5;235m█\e[0;38;5;172m█\e[0;38;5;179;48;5;172m▀\e[0;38;5;179m█\e[0;38;5;179;48;5;232m▀\e[0;38;5;232m█\e[0;38;5;232;48;5;179m▀\e[0;38;5;222;48;5;179m▀\e[0;38;5;232m███\e[0;38;5;179m█\e[0;38;5;232;48;5;172m▀\e[0;38;5;232m█\e[0;38;5;235;48;5;232m▀\e[0;38;5;235;48;5;235m▀\e[0;38;5;235m▀\e[0m
        \e[0;38;5;235m█\e[0;38;5;235;48;5;235m▀\e[0;38;5;172;48;5;235m▀▀\e[0;38;5;179;48;5;172m▀\e[0;38;5;232;48;5;172m▀▀\e[0;38;5;179;48;5;232m▀\e[0;38;5;232m███\e[0;38;5;172;48;5;232m▀\e[0;38;5;232;48;5;235m▀\e[0;38;5;232;48;5;235m▀\e[0;38;5;235m█\e[0m
\e[0;38;5;235m▄▄\e[0;38;5;94m▄▄▄\e[0;38;5;172m▄▄▄▄\e[0;38;5;179m▄\e[0;38;5;235;48;5;179m▀\e[0;38;5;235;48;5;179m▀▀▀\e[0;38;5;235;48;5;232m▀\e[0;38;5;232m█\e[0;38;5;232;48;5;179m▀\e[0;38;5;235;48;5;179m▀\e[0;38;5;232;48;5;179m▀\e[0;38;5;232m█\e[0;38;5;235;48;5;232m▀\e[0;38;5;179m▄\e[0;38;5;172m▄▄▄▄\e[0;38;5;94m▄▄▄\e[0;38;5;235m▄▄\e[0;38;5;235m▄▄▄▄▄\e[0m
\e[0;38;5;235;48;5;234m▀▀\e[0;38;5;235;48;5;235m▀▀▀\e[0;38;5;94;48;5;235m▀▀▀▀\e[0;38;5;172;48;5;94m▀▀▀▀\e[0;38;5;232m██\e[0;38;5;172;48;5;94m▀▀▀▀▀\e[0;38;5;232m██\e[0;38;5;94;48;5;235m▀▀▀▀\e[0;38;5;235;48;5;235m▀▀▀\e[0;38;5;235;48;5;234m▀▀\e[0;38;5;234m▀▀▀▀▀\e[0m
  \e[0;38;5;234m▀▀▀\e[0;38;5;235;48;5;234m▀▀▀▀\e[0;38;5;235;48;5;235m▀▀▀▀▀▀\e[0;38;5;232;48;5;235m▀\e[0;38;5;232m█\e[0;38;5;235;48;5;232m▀▀▀\e[0;38;5;232m███\e[0;38;5;235;48;5;232m▀▀▀\e[0;38;5;234m▀▀▀\e[0m
ROWS256
  fi
}

# The header: the picture with the words beside it, or the words alone.
_foreman_header() {
  local tier="" cols=80 art=0 dir hash words bold="" reset="" muted_open="" muted_close="" row i text avail
  dir="${FOREMAN_HOME/#$HOME/\~}"
  hash="$(git -C "$FOREMAN_HOME" rev-parse --short HEAD 2>/dev/null)"
  words="from $dir"
  [ -z "$hash" ] || words+=" · $hash"
  ui_color_tier tier 1
  if [ "$tier" != none ]; then bold=$'\033[1m'; reset=$'\033[0m'; fi
  ui_paint muted_open 1 muted "@"
  muted_close="${muted_open#*@}"; muted_open="${muted_open%@*}"
  if ui_show 1 tier && { [ "$tier" = 24 ] || [ "$tier" = 256 ]; }; then
    ui_cols cols 1
    [ "$cols" -lt 80 ] || art=1
  fi
  echo
  if [ "$art" -eq 1 ]; then
    _foreman_header_rows "$tier"
    # The words sit beside rows 5 and 6, at column 42: the picture is 36 wide, and those two rows
    # of it are 25 cells, so 17 spaces take the line to the words.
    avail=$((cols - 42 - 1))
    [ "${#words}" -le "$avail" ] || words="…${words: -$((avail - 1))}"
    for i in "${!HEADER_ROWS[@]}"; do
      row="${HEADER_ROWS[$i]}"
      case "$i" in
        4) printf '%b%17s%sFOREMAN%s  %sinstall%s\n' "$row" '' "$bold" "$reset" "$muted_open" "$muted_close" ;;
        5) printf '%b%17s%s%s%s\n' "$row" '' "$muted_open" "$words" "$muted_close" ;;
        *) printf '%b\n' "$row" ;;
      esac
    done
  else
    printf '  %sFOREMAN%s  %sinstall%s\n' "$bold" "$reset" "$muted_open" "$muted_close"
    printf '  %s%s%s\n' "$muted_open" "$words" "$muted_close"
  fi
  echo
}

# _foreman_ask_gui — sets GUI to 1 (install the app) or 0 (CLI only). Sourcing the colour helpers
# here, not at the top, keeps everything above it exactly as it was for a non-terminal.
_foreman_ask_gui() {
  local ans accent="" muted_open muted_close good dimmed b="" r="" tier
  . "$FOREMAN_HOME/lib/foreman-ui.sh"
  ui_color_tier tier 1
  if [ "$tier" != none ]; then b=$'\033[1m'; r=$'\033[0m'; fi
  ui_paint muted_open 1 muted "@"; muted_close="${muted_open#*@}"; muted_open="${muted_open%@*}"
  ui_paint good 1 ok "■"
  ui_paint dimmed 1 muted "·"
  local one two
  ui_paint one 1 warn "1"; ui_paint two 1 warn "2"
  _foreman_header
  if [ -f "$SHIM" ] && grep -q 'foreman toolkit shim' "$SHIM" 2>/dev/null && grep -qF "$FOREMAN_HOME" "$SHIM" 2>/dev/null; then
    # A rerun with the CLI in place: the only piece missing is the app.
    printf '  %s CLI installed           %s%s → this checkout%s\n' "$good" "$muted_open" "${SHIM/#$HOME/\~}" "$muted_close"
    printf '  %s desktop app             %snot installed%s\n\n' "$dimmed" "$muted_open" "$muted_close"
    printf '  Add the desktop app too? %snpm ci in gui/ (~250 MB) and a Start-menu shortcut%s\n\n' "$muted_open" "$muted_close"
    while :; do
      printf '  [y/%sN%s]: ' "$b" "$r"
      IFS= read -r ans || { echo; ans=n; }
      ans="${ans//[[:space:]]/}"; ans="${ans,,}"
      case "$ans" in
        y|yes)    GUI=1; break ;;
        ''|n|no)  GUI=0; break ;;
        *)        echo "  Type y or n (Enter is n)." ;;
      esac
    done
  else
    printf '  What should this install?\n\n'
    printf '  %s%s%s  CLI only                    %sforeman on your PATH, the skills, the%s\n' "$b" "$one" "$r" "$muted_open" "$muted_close"
    printf '                                 %sPowerShell shim. As today.%s\n\n' "$muted_open" "$muted_close"
    printf '  %s%s%s  CLI + desktop app           %salso npm ci in gui/ (~250 MB, Electron) and%s\n' "$b" "$two" "$r" "$muted_open" "$muted_close"
    printf '                                 %sa Start-menu shortcut "Foreman".%s\n\n' "$muted_open" "$muted_close"
    printf '  %sAdd the app later with: bash install.sh --gui   ·   remove it: --no-gui%s\n\n' "$muted_open" "$muted_close"
    while :; do
      printf '  Choice [%s1%s/2]: ' "$b" "$r"
      IFS= read -r ans || { echo; ans=1; }
      ans="${ans//[[:space:]]/}"
      case "$ans" in
        ''|1)  GUI=0; break ;;
        2)     GUI=1; break ;;
        *)     echo "  Type 1 or 2 (Enter is 1)." ;;
      esac
    done
  fi
  echo
}

if [ "$UNINSTALL" -eq 1 ]; then
  _foreman_legacy_cleanup
  removed=0
  for f in "$SHIM" "$SHIM_CMD"; do
    if [ -e "$f" ]; then rm -f "$f" && echo "removed  $f" && removed=1; fi
  done
  [ "$removed" -eq 1 ] || echo "nothing to remove in $TARGET"

  # Only a copy this installer marked — an unmarked directory of the same name is someone
  # else's, and is left alone just like a foreign `foreman` shim would be.
  for name in "${FOREMAN_SKILL_NAMES[@]}"; do
    skill_target="$SKILL_HOME_DIR/skills/$name"
    if [ -f "$skill_target/$FOREMAN_SKILL_MARKER" ]; then
      rm -rf "$skill_target" && echo "removed  $skill_target"
    elif [ -e "$skill_target" ]; then
      echo "left alone  $skill_target (not written by this installer)"
    fi
  done

  _foreman_remove_app

  echo "The toolkit itself is untouched at $FOREMAN_HOME."
  exit 0
fi

# Both conflicts are checked before either write — including creating $TARGET itself —
# so a refusal never leaves anything behind.
#
# Refuse to clobber someone else's `foreman`, but re-pointing our own shim at a moved
# checkout is the normal case and should not need --force.
if [ -e "$SHIM" ] && [ "$FORCE" -eq 0 ] && ! grep -q 'foreman toolkit shim' "$SHIM" 2>/dev/null; then
  echo "install: $SHIM already exists and was not written by this installer." >&2
  echo "         Move it aside, or re-run with --force." >&2
  exit 1
fi

# Same refusal for each skill directory — unless a marked copy is there, in which case
# replacing it is the normal case (a pulled update) and needs no --force.
if [ "$NO_SKILL" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
  for name in "${FOREMAN_SKILL_NAMES[@]}"; do
    skill_target="$SKILL_HOME_DIR/skills/$name"
    if [ -e "$skill_target" ] && [ ! -f "$skill_target/$FOREMAN_SKILL_MARKER" ]; then
      echo "install: $skill_target already exists and was not written by this installer." >&2
      echo "         Move it aside, or re-run with --force." >&2
      exit 1
    fi
  done
fi

# The question comes after the refusals above, so a refusal never asks first, and before the
# first write. Asked only when nothing has answered it (--gui, --no-gui), the app is not already
# installed, and both stdin and stdout are terminals.
GUI=""
[ "$GUI_ON" -eq 0 ] || GUI=1
[ "$GUI_OFF" -eq 0 ] || GUI=0
if [ -z "$GUI" ] && [ -t 0 ] && [ -t 1 ] && ! _foreman_app_installed; then
  _foreman_ask_gui
fi

mkdir -p "$TARGET" || { echo "install: cannot create $TARGET" >&2; exit 1; }
_foreman_legacy_cleanup

cat > "$SHIM" <<EOF
#!/bin/bash
# foreman toolkit shim — written by $FOREMAN_HOME/install.sh. Re-run that to re-point it.
exec bash "$FOREMAN_HOME/bin/foreman" "\$@"
EOF
chmod +x "$SHIM"

# The Windows shim forwards to bin/foreman.cmd, which is where the "find Git Bash rather
# than the WSL launcher" logic lives — so that logic stays in one place, in the repo.
#
# cmd.exe needs a Windows path, not the shell's own spelling: the shim may be run from
# PowerShell, where nothing translates /c/x. `cygpath -w` ships with Git Bash; the sed is
# for a shell that lacks it.
if command -v cygpath >/dev/null 2>&1; then
  FOREMAN_HOME_WIN="$(cygpath -w "$FOREMAN_HOME")"
else
  FOREMAN_HOME_WIN="$(printf '%s' "$FOREMAN_HOME" | sed -E 's|^/([A-Za-z])/|\1:/|' | tr '/' '\\')"
fi

# CRLF, deliberately: cmd.exe mis-parses a batch file whose last line has no CR.
# `call`, deliberately: invoking a batch file without it transfers control and never comes
# back, so the exit code would be lost.
printf '%s\r\n' \
  '@echo off' \
  "rem foreman toolkit shim — written by $FOREMAN_HOME/install.sh. Re-run that to re-point it." \
  "call \"$FOREMAN_HOME_WIN\\bin\\foreman.cmd\" %*" \
  'exit /b %errorlevel%' \
  > "$SHIM_CMD"

echo "installed"
echo "  $SHIM"
echo "  $SHIM_CMD"
echo "  -> $FOREMAN_HOME/bin/foreman"
echo

if [ "$NO_SKILL" -eq 0 ]; then
  # A copy, not a symlink — same reason as the shims above. Always replaced wholesale
  # rather than diffed in place, so a file the checkout deleted does not linger.
  for name in "${FOREMAN_SKILL_NAMES[@]}"; do
    skill_target="$SKILL_HOME_DIR/skills/$name"
    rm -rf "$skill_target"
    mkdir -p "$skill_target" || { echo "install: cannot create $skill_target" >&2; exit 1; }
    cp -r "$FOREMAN_HOME/skills/$name/." "$skill_target/"
    printf 'foreman skill copy — written by %s/install.sh. Re-run that to update it.\n' "$FOREMAN_HOME" \
      > "$skill_target/$FOREMAN_SKILL_MARKER"
    echo "installed skill"
    echo "  $skill_target"
    echo "  <- $FOREMAN_HOME/skills/$name"
    echo
  done
fi

# The desktop app. --no-gui removes it, --gui (or a "2" at the question) installs it, and with
# neither it is left exactly as it is.
if [ "$GUI_OFF" -eq 1 ]; then
  _foreman_remove_app
elif [ "$GUI" = 1 ]; then
  _foreman_install_app
fi

# Git Bash puts ~/bin on its own PATH whether or not Windows knows about it, so the shell
# running this can find `foreman` while PowerShell and cmd.exe still cannot. Check the user's
# persistent PATH in the registry, which is the one they actually inherit.
if [ -n "$_foreman_win_path" ]; then
  target_win="$(cygpath -w "$TARGET")"
  case ";${_foreman_win_path};" in
    *";${target_win};"*) ;;
    *)
      echo "note: $target_win is not on your Windows PATH, so PowerShell and cmd.exe will"
      echo "      not find \`foreman\` (Git Bash will — it adds ~/bin itself). To fix it, once:"
      echo
      echo "        setx PATH \"%PATH%;$target_win\""
      echo
      echo "      then open a new PowerShell. Until then, PowerShell can use the full path:"
      echo "        & \"$target_win\\foreman.cmd\" version"
      echo
      ;;
  esac
fi

if command -v foreman >/dev/null 2>&1 && [ "$(command -v foreman)" = "$SHIM" ]; then
  echo "Ready. Try it:"
else
  echo "Open a new shell, then try it:"
fi
echo "  foreman version"
echo "  cd <any git repo> && foreman doctor"
[ "$APP_FAILED" -eq 0 ] || exit 1
