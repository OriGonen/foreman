---
status: accepted
---

# A palette over the terminal's theme, with the theme still there at 16 colours

Foreman's colour used to be the terminal's basic 16 ANSI colours and nothing else, so that the
user's own theme decided the shades: green for ok, yellow for warn, red for error, cyan for
accent, dim for muted. That was the right call for five coloured glyphs, and it is the wrong
one for what the terminal-design batch builds. The art is drawn from block characters in a
set of exact shades (a sun that goes from cream to rust, a ground of dark brown); the same
art in whatever the theme calls "yellow" and "red" is a different picture, and on some themes
an unreadable one.

So foreman now has a **palette**: thirteen named colours, each with its hex, the nearest
xterm-256 index and a 16-colour SGR code, defined once in `lib/foreman-ui.sh` (`_UI_PALETTE`)
and read from there by the renderer. Output is painted at the best **colour tier** the
terminal has:

- **24** (`38;2;r;g;b`) when `COLORTERM` is `truecolor` or `24bit`, or `WT_SESSION` is set —
  Windows Terminal, the main terminal here, does not set `COLORTERM`;
- **256** (`38;5;n`) when `TERM` contains `256color`;
- **16** otherwise, and under `FOREMAN_COLOR=always` when nothing is detected.

`FOREMAN_COLOR=16|256|truecolor` pins a tier on every stream, for tests and for terminals that
lie about themselves. `NO_COLOR`, `TERM=dumb`, a stream that is not a terminal and
`FOREMAN_COLOR=never` still mean no colour at all, exactly as before.

**16 colours still means the theme's own.** At that tier the five styles keep the codes they
always had (`32`, `33`, `31`, `36`, `2`), so a 16-colour terminal looks exactly as it did and
the user's theme still picks the shades. The palette's 16-colour column is for the art, which
folds its shades onto yellow, red and dim. A person who wants their theme's colours everywhere
can set `FOREMAN_COLOR=16`.

The tier is decided from builtins per call, as colour on/off was, so it adds no process to the
paths that print one event line at a time under MSYS.

## Considered options

**Staying at 16 colours and drawing the art in them** was rejected: the picked designs depend
on shades that do not exist in the basic palette, and a block-character sun in two yellows and
a red is not the design.

**Computing the 256 index from the hex at run time** was rejected. It is arithmetic over 240
candidates per colour, in a shell, on a path that must stay cheap; the table holds the answer,
and a smoke case checks that each index really is the nearest shade.

**A second copy of the palette in the renderer** was rejected: two tables drift. The renderer
reads the one assignment in `foreman-ui.sh`.

**Detecting colour from `tput colors`** was rejected: it starts a process on every call, which
is the thing these helpers avoid, and it cannot tell 256 colours from 24 bits.

## Consequences

- A light-background palette is not provided; the palette is for dark terminals, and a light one
  is a later decision.
- `FOREMAN_COLOR=always` on a 24-bit terminal now writes `38;2;` sequences where it used to
  write `32`; a script that matched the old bytes pins `FOREMAN_COLOR=16`.
