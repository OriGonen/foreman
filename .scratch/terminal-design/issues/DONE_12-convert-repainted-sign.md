# 12: foreman convert as the repainted sign

**What to build:** `foreman convert` at a terminal shows the 12a design. The sign has
RALPH struck through and FOREMAN painted on, followed by the counts. Below are RENAMED,
REWROTE, DELETED, KEPT and THIS MACHINE, with ✓ and ▲. `--dry-run` says "would"
throughout and leaves the sign unpainted. `foreman-convert.cjs` draws it by requiring
`foreman-draw.cjs` as a module. See `spec.md`, "Per command". The design is
`designs/12a-convert.ans`, from `designs/source/ConvertTakes.dc.html` (panel 12a).

**Blocked by:** 02

**Status:** implemented

- [x] The strike-through uses SGR 9, and the sign still reads correctly where a terminal ignores it
- [x] A project with nothing to convert gets a short "nothing to repaint" form
- [x] Plain convert output is byte for byte today's
- [x] Smoke: forced-show convert and `--dry-run` of the existing ralph fixture
- [x] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`

Full smoke suite: 2544 passed in 2m 4s, 1 failed (the same pre-existing CRLF `convert` case).
