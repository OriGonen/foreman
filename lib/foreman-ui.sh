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
# nothing. The five styles are ok, warn, error, accent and muted, and they are painted in the
# best colour the terminal has, in one of four TIERS:
#   none  no colour
#   16    the basic ANSI colours — ok green, warn yellow, error red, accent cyan, muted dim —
#         so the terminal's own theme decides the shades, as it always did
#   256   the palette's nearest xterm-256 shades
#   24    the palette's exact shades (38;2;r;g;b)
# THE PALETTE is the table _UI_PALETTE below: foreman's designed colours, one line per name —
# its hex, its nearest xterm-256 index (worked out once, not at run time) and its 16-colour
# SGR code. It is defined there and nowhere else; foreman-draw.cjs reads the same assignment
# for the art. The styles use ok, amber (warn), error, sun (accent) and muted from it. At 16
# colours the styles keep the codes above rather than the table's 16-colour column, which is for
# the art's shades. See docs/adr/0003-a-palette-over-the-terminal-theme.md.
#
# The tier is decided per call, from the stream being written, so:
#   - a line redirected with `>&2` follows stderr, and one captured by `$(…)` or sent to a
#     pipe or file is plain;
#   - nothing that reaches foreman-runs.log goes through these helpers' colour — log_append
#     writes its own strings.
# FOREMAN_COLOR overrides it (set in the environment or foreman.conf):
#   auto      (default) a terminal, unless NO_COLOR is set or TERM is dumb; the tier is the
#             terminal's best (below)
#   always    colour on every stream, whatever it is — even with NO_COLOR set — at the
#             terminal's best tier, or 16 when nothing says better
#   never     no colour, ever
#   16|256|truecolor   that tier, on every stream — for tests, and for terminals that lie
# The terminal's best tier: 24 when COLORTERM is truecolor or 24bit, or WT_SESSION is set
# (Windows Terminal does not set COLORTERM); else 256 when TERM contains 256color; else 16.
#
# Nothing here starts a process: `[ -t ]`, `printf -v` and `case` are builtins, which is the
# point under MSYS, where a fork is the expensive thing and these run once per event line.

[ -z "${_FOREMAN_UI_LOADED:-}" ] || return 0
_FOREMAN_UI_LOADED=1

_UI_ESC=$'\033'
_UI_SEP='  ·  '

# name, hex, nearest xterm-256 index, 16-colour SGR code. `text` is the terminal's own default
# below 24 bits, so it has no 256 index. The 16 codes fold the shades onto yellow, red and dim.
_UI_PALETTE='
sun   #f6d58e 222 33
amber #e0a84a 179 33
rust  #c9772f 172 31
post  #8a5a24 94  31
earth #3a2a18 235 2
shade #30231a 235 2
night #1c1a17 234 2
ok    #8fcf8f 114 32
error #f08078 210 31
muted #a8a299 247 2
dim   #5c574f 240 2
text  #ece8e1 -   0
ink   #171614 233 30
'

# The palette as the arrays ui_paint reads: _UI_RGB[name] is "r;g;b", _UI_X256[name] the index.
# Built on the first colour painted, so a plain run never pays for it.
declare -gA _UI_RGB=() _UI_X256=()
_UI_PALETTE_LOADED=
_ui_palette_load() {
  local name hex idx code
  while read -r name hex idx code; do
    [ -n "$name" ] || continue
    hex="${hex#\#}"
    _UI_RGB[$name]="$((16#${hex:0:2}));$((16#${hex:2:2}));$((16#${hex:4:2}))"
    [ "$idx" = - ] || _UI_X256[$name]="$idx"
  done <<< "$_UI_PALETTE"
  _UI_PALETTE_LOADED=1
}

# ui_color_tier VAR FD — sets VAR to none, 16, 256 or 24: the colour tier for that stream.
ui_color_tier() {
  local _ct_best=16
  case "${FOREMAN_COLOR:-auto}" in
    never)     printf -v "$1" none; return 0 ;;
    16)        printf -v "$1" 16; return 0 ;;
    256)       printf -v "$1" 256; return 0 ;;
    truecolor) printf -v "$1" 24; return 0 ;;
    always)    ;;
    *)
      if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = dumb ] || ! [ -t "$2" ]; then
        printf -v "$1" none; return 0
      fi
      ;;
  esac
  case "${COLORTERM:-}" in
    truecolor|24bit) _ct_best=24 ;;
    *) if [ -n "${WT_SESSION:-}" ]; then _ct_best=24
       else case "${TERM:-}" in *256color*) _ct_best=256 ;; esac
       fi ;;
  esac
  printf -v "$1" '%s' "$_ct_best"
}

# ui_color_on FD — success when colour is wanted on that file descriptor: its tier is not none.
ui_color_on() {
  local _co_tier
  ui_color_tier _co_tier "$1"
  [ "$_co_tier" != none ]
}

# ui_paint VAR FD STYLE TEXT — sets VAR to TEXT, wrapped in STYLE's colour at FD's tier.
ui_paint() {
  local _up_tier _up_name _up_sgr
  ui_color_tier _up_tier "$2"
  if [ "$_up_tier" = none ]; then
    printf -v "$1" '%s' "$4"
    return 0
  fi
  case "$3" in
    ok)     _up_name=ok;    _up_sgr=32 ;;
    warn)   _up_name=amber; _up_sgr=33 ;;
    error)  _up_name=error; _up_sgr=31 ;;
    accent) _up_name=sun;   _up_sgr=36 ;;
    muted)  _up_name=muted; _up_sgr=2 ;;
    *)      _up_name=;      _up_sgr=0 ;;
  esac
  if [ -n "$_up_name" ] && [ "$_up_tier" != 16 ]; then
    [ -n "$_UI_PALETTE_LOADED" ] || _ui_palette_load
    if [ "$_up_tier" = 24 ]; then _up_sgr="38;2;${_UI_RGB[$_up_name]}"
    else _up_sgr="38;5;${_UI_X256[$_up_name]}"; fi
  fi
  printf -v "$1" '%s[%sm%s%s[0m' "$_UI_ESC" "$_up_sgr" "$4" "$_UI_ESC"
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
