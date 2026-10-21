#!/bin/bash
# How foreman's terminal output looks: the glyphs, the indents, the "  ·  " separators and the
# colour all live here, so a line reads the same wherever the loop prints it. Sourced by
# foreman-loop.sh (and, for the adapters' preflight lines, by foreman-exec.sh) and by
# foreman-keys.sh — never run.
#
#   say_event ok|progress|sentback|fail FACT [DETAIL]   "   ✓ FACT  ·  DETAIL"
#   say_rule TEXT                                       "── TEXT"
#   say_frame TEXT                                      "== TEXT =="
#   warn_note TEXT                                      "   note: TEXT"        (stderr)
#   warn_preflight TEXT                                 "preflight: TEXT"      (stderr)
#   ui_key_echo TEXT                                    "   ⌨ TEXT"            (stderr)
#   ui_bar_rows|ui_bar_draw|ui_bar_resized|ui_bar_close  the pinned status bar   (stderr)
#   say_tag STYLE TAG TEXT                              "TAG TEXT"             (stdout)
#   warn_tag STYLE TAG TEXT                             "TAG TEXT"             (stderr)
#   ui_paint VAR FD STYLE TEXT                          VAR = TEXT, coloured when FD wants it
#
# STYLE is ok, warn, error, accent or muted. say_tag / warn_tag colour only TAG — the
# "Batch:" of a status line, the "foreman order:" of a message.
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
#   - nothing that reaches foreman-runs.log goes through these helpers' colour — log_append
#     writes its own strings.
# FOREMAN_COLOR overrides it (set in the environment or foreman.conf):
#   auto    (default) a terminal, unless NO_COLOR is set or TERM is dumb
#   always  colour on every stream, whatever it is — even with NO_COLOR set
#   never   no colour, ever
#
# Nothing here starts a process: `[ -t ]`, `printf -v` and `case` are builtins, which is the
# point under MSYS, where a fork is the expensive thing and these run once per event line.

[ -z "${_FOREMAN_UI_LOADED:-}" ] || return 0
_FOREMAN_UI_LOADED=1

_UI_ESC=$'\033'
_UI_SEP='  ·  '

# ui_color_on FD — success when colour is wanted on that file descriptor.
ui_color_on() {
  case "${FOREMAN_COLOR:-auto}" in
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
    *)        printf 'foreman-ui: say_event: unknown kind %s\n' "$kind" >&2; return 2 ;;
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

# THE STATUS BAR. On a terminal, `foreman run` keeps the bottom rows for lines that are
# redrawn in place while everything else scrolls in the rows above them: the bar itself (the
# iteration count, the live view, the keys) on the last row, and with the live view on, the
# agent's activity on the row above it. ROWS is the terminal's height; KEPT is how many rows
# are held back, 0 for none. Only foreman-keys.sh draws there, and each call is one printf, so
# one write: nothing else on the terminal can land in the middle of it.
#
# Every line drawn there must fit its row. A line that wraps puts its tail on the row below
# and leaves its head behind when it is redrawn — the bug the in-place --live line had.
#
#   ui_bar_rows ROWS FROM TO  hold back TO rows instead of FROM. Growing scrolls the text up
#                             first with ESC D (index: down a row, scrolling at the bottom, the
#                             column kept) and back up, so the cursor is never left in a held
#                             row. Shrinking blanks the rows given back. Setting the region
#                             homes the cursor, so it is saved and restored around that.
#   ui_bar_draw ROWS BAR [TICKER]   BAR on the last row, TICKER on the one above when given;
#                             the cursor put back where it was.
#   ui_bar_resized ROWS KEPT  after the terminal changed size. A terminal moves its text on a
#                             resize — reflowed, pulled back from scrollback — and the old bar
#                             moves with it, to a row nobody can know. It can only be BELOW
#                             the cursor, though, where nothing else is: so everything from the
#                             cursor down is erased, and the rows are held back again.
#   ui_bar_close ROWS KEPT    scrolling over the whole screen again, and everything from the
#                             cursor down erased — the held rows, and any bar a resize the
#                             reader did not hear about left somewhere else.
ui_bar_rows() {    # ui_bar_rows ROWS FROM TO
  local e="$_UI_ESC" rows="$1" from="$2" to="$3" out="" i
  if [ "$to" -gt "$from" ]; then
    for ((i = from; i < to; i++)); do out+="${e}D"; done
    out+="${e}[$((to - from))A"
  fi
  out+="${e}7"
  if [ "$to" -gt 0 ]; then out+="${e}[1;$((rows - to))r"; else out+="${e}[r"; fi
  for ((i = rows - from + 1; i <= rows - to; i++)); do out+="${e}[${i};1H${e}[2K"; done
  out+="${e}8"
  printf '%s' "$out" >&2
}

ui_bar_draw() {    # ui_bar_draw ROWS BAR [TICKER]
  local e="$_UI_ESC" out
  out="${e}7"
  [ $# -lt 3 ] || out+="${e}[$(($1 - 1));1H${e}[2K$3"
  out+="${e}[$1;1H${e}[2K$2${e}8"
  printf '%s' "$out" >&2
}

ui_bar_resized() {    # ui_bar_resized ROWS KEPT
  local e="$_UI_ESC"
  printf '%s[J%s7%s[r%s8' "$e" "$e" "$e" "$e" >&2
  ui_bar_rows "$1" 0 "$2"
}

ui_bar_close() {    # ui_bar_close ROWS KEPT
  local e="$_UI_ESC"
  printf '%s[J' "$e" >&2
  ui_bar_rows "$1" "$2" 0
}
