#!/bin/bash
# The one reader of the operator's credentials file. Sourced — never run. The sandbox
# adapters, `foreman setup` and `foreman doctor` all ask their questions through these
# functions, so none of them can disagree with another about what the file says.
#
# The file is ~/.config/foreman/env, or wherever FOREMAN_CREDENTIALS_FILE points: plain
# NAME=value lines and `#` comments, outside every repository.
#
#   FOREMAN_DOCKER_USERNAME=someone
#   FOREMAN_DOCKER_PAT=dckr_pat_...
#
#   foreman_credentials_file   print the path the file is (or would be) at
#   foreman_credential NAME    print NAME's value: the environment's if it has one, else the
#                            file's, else nothing. Always succeeds — a missing file is not
#                            an error, it is "no value".
#   foreman_mask VALUE         print VALUE as …last4, for showing that a value exists
#
# THE FILE IS DATA, NEVER CODE. It is read line by line and split on the first `=`; it is
# never sourced or evaluated, so a stray line in it cannot run anything. CR is stripped, a
# UTF-8 byte-order mark is skipped, blanks and `#` lines are ignored, blanks around a name or
# an unquoted value are trimmed, one pair of surrounding quotes is removed, and when a name
# appears twice the last wins.
#
# A real environment variable of the same name wins over the file (an empty one does not),
# so the older `setx` setup keeps working. Values are only ever printed to the caller that
# asked for one: nothing here exports a value, and nothing logs one. Callers hand a value to
# `sbx` on stdin — never in argv.
#
# This file starts no process of its own — builtins only, no `$(...)` — because it runs under
# MSYS, where a process is the expensive thing. (A caller that captures the output pays for
# its own subshell.)

# Sets _FOREMAN_CREDENTIALS_PATH (empty when there is no HOME to put it under); a function that
# printed it would cost a subshell at every lookup.
_foreman_credentials_resolve() {
  _FOREMAN_CREDENTIALS_PATH="${FOREMAN_CREDENTIALS_FILE:-}"
  if [ -z "$_FOREMAN_CREDENTIALS_PATH" ] && [ -n "${HOME:-}" ]; then
    _FOREMAN_CREDENTIALS_PATH="$HOME/.config/foreman/env"
    # legacy: the file from before the rename from ralph, while it is the only one.
    [ -e "$_FOREMAN_CREDENTIALS_PATH" ] || [ ! -e "$HOME/.config/ralph/env" ] ||
      _FOREMAN_CREDENTIALS_PATH="$HOME/.config/ralph/env"
  fi
}

foreman_credentials_file() {
  _foreman_credentials_resolve
  [ -z "$_FOREMAN_CREDENTIALS_PATH" ] || printf '%s\n' "$_FOREMAN_CREDENTIALS_PATH"
}

foreman_credential() {
  local name="${1:-}" file line key value q cr=$'\r' bom=$'\xEF\xBB\xBF'
  # `${!name}` and the comparison below both treat NAME as a variable name; anything else
  # (an array subscript, say) is refused rather than expanded.
  [[ $name =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0

  # legacy: FOREMAN_X may still be spelled RALPH_X, in the environment or the file, from
  # before the rename. The new name wins wherever both are set.
  local old= old_value= found=
  [ "${name#FOREMAN_}" = "$name" ] || old="RALPH_${name#FOREMAN_}"

  if [ -n "${!name:-}" ]; then
    printf '%s\n' "${!name}"
    return 0
  fi
  if [ -n "$old" ] && [ -n "${!old:-}" ]; then
    printf '%s\n' "${!old}"
    return 0
  fi

  _foreman_credentials_resolve
  file="$_FOREMAN_CREDENTIALS_PATH"
  [ -n "$file" ] && [ -r "$file" ] || return 0

  value=
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%"$cr"}"
    line="${line#"$bom"}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"
    [ "$key" = "$name" ] || { [ -n "$old" ] && [ "$key" = "$old" ]; } || continue
    line="${line#*=}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [ "${#line}" -ge 2 ]; then
      q="${line:0:1}"
      if { [ "$q" = '"' ] || [ "$q" = "'" ]; } && [ "${line: -1}" = "$q" ]; then
        line="${line:1:${#line}-2}"
      fi
    fi
    if [ "$key" = "$name" ]; then value="$line" found=1; else old_value="$line"; fi
  done < "$file" 2>/dev/null
  [ -n "$found" ] || value="$old_value"
  printf '%s\n' "$value"
}

# …last4 — and for a value too short to show four characters of safely, just `…`.
foreman_mask() {
  local value="${1:-}"
  if [ -z "$value" ]; then
    return 0
  elif [ "${#value}" -le 8 ]; then
    printf '…\n'
  else
    printf '…%s\n' "${value: -4}"
  fi
}
