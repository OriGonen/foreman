# 02: The renderer, the show switch, and the help sunrise

**What to build:** `foreman help` at a wide terminal prints the D1 sunrise above the
help text, in the palette. This is the first show, so it brings what every later one
needs: `ui_show FD` and the width check in `foreman-ui.sh`, `FOREMAN_SHOW`, and
`lib/foreman-draw.cjs` with its row encoder, the palette read from `foreman-ui.sh`, and the
sun. Piped, in CI, narrow or without colour, help is today's text. See `spec.md`, "Show
or plain", "The renderer" and "Per command". The design is `designs/01-help-d1.ans`,
from `designs/source/SunrisePicks.dc.html` (panel D1).

**Blocked by:** 01

**Status:** implemented

- [x] `ui_show FD` succeeds only for a terminal with colour on, `CI` unset and `FOREMAN_SHOW` not `never`; `FOREMAN_SHOW=always` forces it
- [x] The width comes from `COLUMNS`, else `stty size`, and is asked only on the show path; below the scene's minimum the output is plain
- [x] `foreman-draw.cjs SCENE --tier T --cols N` reads facts on stdin and is also a module (`draw(scene, facts, opts)`)
- [x] The encoder writes 24-bit, 256 and 16-colour SGR, and half-block cells with a foreground and a background, and resets at the end of every line
- [x] The palette is read from `foreman-ui.sh`, not copied
- [x] `foreman help` and bare `foreman` draw D1 above the help on the show path; exit codes are unchanged
- [x] Smoke: the forced show contains the help text and `38;2;`; at `FOREMAN_COLOR=16` it has no `38;2;` or `38;5;`; a narrow `COLUMNS` and a plain capture both equal today's help
- [ ] Checked by hand in Windows Terminal and mintty against `designs/01-help-d1.ans`
- [x] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`

## Closing note

- Built: `ui_show FD [VAR]` (sets VAR to the tier), `ui_cols VAR FD`, `FOREMAN_SHOW=auto|always|never` (config, conf template, README), `lib/foreman-draw.cjs` (palette reader, encoder, half-block grid, D1 sun and figure, `parseFacts`, `draw`), and `usage_show` in `bin/foreman` for `help`, `--help`, `-h` and bare `foreman`.
- `FOREMAN_SHOW=always` beats CI, NO_COLOR and TERM, but not `FOREMAN_COLOR=never`. An unknown command's usage on stderr is not a help request and draws nothing.
- At 16 colours the dark shades (earth, shade, night) are the terminal's own background, so the ground and the rim are not drawn; the sun is yellow over red, the figure black.
- Checked against `designs/01-help-d1.ans` at 24 bits, cell by cell (glyph, foreground, background): all 18 rows identical. NOT done: the by-hand look in Windows Terminal and mintty, which a sandbox cannot do; left unchecked for a person.
- Full smoke suite: 1072 passed in 1m 1s, 1 failed — "convert moves a ralph project…" (CRLF prose), which fails identically on 928b892 and is not touched by this ticket.
