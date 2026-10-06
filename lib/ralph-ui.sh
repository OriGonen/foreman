#!/bin/bash
# How ralph's terminal output looks: the glyphs, the indents, the "  ·  " separators and the
# colour all live here, so a line reads the same wherever the loop prints it. Sourced by
# ralph-loop.sh (and, for the adapters' preflight lines, by ralph-exec.sh) and by
# ralph-keys.sh — never run.
#
#   say_event ok|progress|sentback|fail FACT [DETAIL]   "   ✓ FACT  ·  DETAIL"
#   say_rule TEXT                                       "── TEXT"
#   say_frame TEXT                                      "== TEXT =="
#   warn_note TEXT                                      "   note: TEXT"        (stderr)
#   warn_preflight TEXT                                 "preflight: TEXT"      (stderr)
#   ui_key_echo TEXT                                    "   ⌨ TEXT"            (stderr)
#   say_tag STYLE TAG TEXT                              "TAG TEXT"             (stdout)
#   warn_tag STYLE TAG TEXT                             "TAG TEXT"             (stderr)
#   ui_paint VAR FD STYLE TEXT                          VAR = TEXT, coloured when FD wants it
#
# STYLE is ok, warn, error, accent or muted. say_tag / warn_tag colour only TAG — the
# "Batch:" of a status line, the "ralph order:" of a message.
#
# Streams are unchanged from before: everything above is stdout except `fail`, the two warn_
# helpers and the key echo, which are stderr. A caller may still redirect (`say_rule … >&2`).
#
# COLOUR is added here and nowhere else, to the glyph or prefix only — never to a sentence.
# The glyph stays the signal; colour is a second channel, so output read without it loses
# nothing. Only the basic 16 ANSI colours are used, so a terminal's own theme decides the
# shades: ok green, warn yellow, error red, accent cyan, muted dim.
#
# Colour is on only when the stream being written is a terminal. It is decided per call,
# from `[ -t FD ]` on the stream that call writes to, so:
#   - a line redirected with `>&2` follows stderr, and one captured by `$(…)` or sent to a
#     pipe or file is plain;
#   - nothing that reaches ralph-runs.log goes through these helpers' colour — log_append
#     writes its own strings.
# RALPH_COLOR overrides it (set in the environment or ralph.conf):
#   auto    (default) a terminal, unless NO_COLOR is set or TERM is dumb
#   always  colour on every stream, whatever it is — even with NO_COLOR set
#   never   no colour, ever
#
# Nothing here starts a process: `[ -t ]`, `printf -v` and `case` are builtins, which is the
# point under MSYS, where a fork is the expensive thing and these run once per event line.

[ -z "${_RALPH_UI_LOADED:-}" ] || return 0
_RALPH_UI_LOADED=1

_UI_ESC=$'\033'
_UI_SEP='  ·  '

# ui_color_on FD — success when colour is wanted on that file descriptor.
ui_color_on() {
  case "${RALPH_COLOR:-auto}" in
    always) return 0 ;;
    never)  return 1 ;;
  esac
  [ -z "${NO_COLOR:-}" ] || return 1
  [ "${TERM:-}" != dumb ] || return 1
  [ -t "$1" ]
}

# ui_paint VAR FD STYLE TEXT — sets VAR to TEXT, wrapped in STYLE's colour when FD wants it.
ui_paint() {
  local code
  if ui_color_on "$2"; then
    case "$3" in
      ok)     code=32 ;;
      warn)   code=33 ;;
      error)  code=31 ;;
      accent) code=36 ;;
      muted)  code=2 ;;
      *)      code=0 ;;
    esac
    printf -v "$1" '%s[%sm%s%s[0m' "$_UI_ESC" "$code" "$4" "$_UI_ESC"
  else
    printf -v "$1" '%s' "$4"
  fi
}

say_event() {    # say_event ok|progress|sentback|fail FACT [DETAIL]
  local kind="$1" fact="$2" fd=1 glyph style line
  case "$kind" in
    ok)       glyph='✓'; style=ok ;;
    progress) glyph='⋯'; style=muted ;;
    sentback) glyph='↩'; style=warn ;;
    fail)     glyph='✗'; style=error; fd=2 ;;
    *)        printf 'ralph-ui: say_event: unknown kind %s\n' "$kind" >&2; return 2 ;;
  esac
  ui_paint glyph "$fd" "$style" "$glyph"
  line="   $glyph $fact"
  # Tested on the argument count, not on emptiness, so an empty detail still prints its
  # separator exactly as the hand-written lines did.
  [ $# -lt 3 ] || line+="$_UI_SEP$3"
  printf '%s\n' "$line" >&"$fd"
}

say_rule() {    # say_rule TEXT
  local mark
  ui_paint mark 1 accent '──'
  printf '%s %s\n' "$mark" "$1"
}

say_frame() {    # say_frame TEXT
  local mark
  ui_paint mark 1 accent '=='
  printf '%s %s %s\n' "$mark" "$1" "$mark"
}

warn_note() {    # warn_note TEXT
  local mark
  ui_paint mark 2 warn 'note:'
  printf '   %s %s\n' "$mark" "$1" >&2
}

warn_preflight() {    # warn_preflight TEXT
  local mark
  ui_paint mark 2 warn 'preflight:'
  printf '%s %s\n' "$mark" "$1" >&2
}

say_tag() {    # say_tag STYLE TAG TEXT
  local mark
  ui_paint mark 1 "$1" "$2"
  printf '%s %s\n' "$mark" "$3"
}

warn_tag() {    # warn_tag STYLE TAG TEXT
  local mark
  ui_paint mark 2 "$1" "$2"
  printf '%s %s\n' "$mark" "$3" >&2
}

ui_key_echo() {    # ui_key_echo TEXT
  local mark
  ui_paint mark 2 accent '⌨'
  printf '\r\033[2K   %s %s\n' "$mark" "$1" >&2
}
