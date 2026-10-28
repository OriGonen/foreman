# 02: The renderer, the show switch, and the help sunrise

**What to build:** `foreman help` at a wide terminal prints the D1 sunrise above the
help text, in the palette. This is the first show, so it brings what every later one
needs: `ui_show FD` and the width check in `foreman-ui.sh`, `FOREMAN_SHOW`, and
`lib/foreman-draw.cjs` with its row encoder, the palette read from `foreman-ui.sh`, and the
sun. Piped, in CI, narrow or without colour, help is today's text. See `spec.md`, "Show
or plain", "The renderer" and "Per command". The design is `designs/01-help-d1.ans`,
from `designs/source/SunrisePicks.dc.html` (panel D1).

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] `ui_show FD` succeeds only for a terminal with colour on, `CI` unset and `FOREMAN_SHOW` not `never`; `FOREMAN_SHOW=always` forces it
- [ ] The width comes from `COLUMNS`, else `stty size`, and is asked only on the show path; below the scene's minimum the output is plain
- [ ] `foreman-draw.cjs SCENE --tier T --cols N` reads facts on stdin and is also a module (`draw(scene, facts, opts)`)
- [ ] The encoder writes 24-bit, 256 and 16-colour SGR, and half-block cells with a foreground and a background, and resets at the end of every line
- [ ] The palette is read from `foreman-ui.sh`, not copied
- [ ] `foreman help` and bare `foreman` draw D1 above the help on the show path; exit codes are unchanged
- [ ] Smoke: the forced show contains the help text and `38;2;`; at `FOREMAN_COLOR=16` it has no `38;2;` or `38;5;`; a narrow `COLUMNS` and a plain capture both equal today's help
- [ ] Checked by hand in Windows Terminal and mintty against `designs/01-help-d1.ans`
- [ ] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
