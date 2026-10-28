# 01: Colour tiers and the palette

**What to build:** Every coloured line foreman prints uses the best colour the terminal
has. `lib/foreman-ui.sh` learns the four colour tiers (none, 16, 256, 24) and the palette.
Its five styles paint in the palette's exact shades at 24 bits, the nearest at 256, and
the old ANSI codes at 16, so a 16-colour terminal looks as it does today, while Windows
Terminal and mintty show the designed colours. No command's text changes. See `spec.md`
in this directory, "Colour tiers" and "The palette".

**Blocked by:** None.

**Status:** implemented

- [x] `ui_color_tier VAR FD` sets none / 16 / 256 / 24 from builtins only, by the rules in the spec (`WT_SESSION` or `COLORTERM` gives 24, `*256color` gives 256)
- [x] `FOREMAN_COLOR` accepts `16`, `256` and `truecolor` beside `auto`, `always` and `never`; `always` with nothing detected is 16
- [x] `ui_color_on` and `ui_paint` keep their signatures; `ui_paint` paints at the stream's tier
- [x] The palette table is defined once in `foreman-ui.sh` (hex, 256 index, 16 code per name), with the 256 indexes precomputed
- [x] The header comment describes the tiers and the palette, and no longer says only 16 colours are used
- [x] `docs/adr/0003-a-palette-over-the-terminal-theme.md` records the change, and that 16 colours still means the theme's own
- [x] The README's `FOREMAN_COLOR` entry lists the new values
- [x] Smoke: a table of environments against the expected tier; a 24-bit and a 256 case of `say_event ok`; the existing `[32m` cases unchanged (with `COLORTERM` and `WT_SESSION` unset)
- [x] `test/bench.sh`: no new processes on any path
- [x] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`

## Closing note

- Built: `ui_color_tier`, the four tiers, `_UI_PALETTE` (once, in `lib/foreman-ui.sh`), `ui_paint` at the stream's tier, `FOREMAN_COLOR=16|256|truecolor`, ADR 0003, README and conf-template entries.
- Styles in the palette: ok→ok, warn→amber, error→error, accent→sun, muted→muted; at 16 they keep the old codes (32, 33, 31, 36, 2).
- `test/bench.sh`: 116 spawns before and after; every colour path runs in one process (xtrace by PID).
- Full smoke suite: 921 passed in 0m 52s, 1 failed — "convert moves a ralph project…" (CRLF prose), which fails identically on 928b892 and is not touched by this ticket.
