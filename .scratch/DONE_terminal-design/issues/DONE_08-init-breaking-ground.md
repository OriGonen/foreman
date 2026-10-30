# 08: foreman init as breaking ground

**What to build:** `foreman init` at a terminal shows the 7a design. It has the mark and
"FOREMAN breaks ground", the batch and what was found, and a `+` per file written. Then
come the ordering result (moved count, the human and check tickets, time, cost) and NEXT
with four numbered steps. This ticket adds the mark, which report and version reuse. See
`spec.md`, "Per command". The design is `designs/07a-init.ans`, from
`designs/source/InitTakes.dc.html`.

**Blocked by:** 02

**Status:** implemented

- [x] The mark is one renderer function, shared with report and version
- [x] Files written are listed with `+`; `--force` over an existing batch says which were replaced
- [x] `--no-order` drops the ordering line; a failed ordering says so in its place
- [x] Plain init is byte for byte today's
- [x] Smoke: a forced-show init of a fixture batch, with and without `--no-order`
- [x] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`

## Closing note

- Built: in `lib/foreman-draw.cjs` the mark (`mark(tier)`, `withMark(tier, beside)`, `MARK_WIDTH`, `TEXT_COLUMN`, plus `rule`, `ticketId`, `movedCount`, all exported for report and version) and two scenes: `init` (blank line, mark with FOREMAN / batch / found beside it, the rule, a `+` per file) and `init-done` (the ordering line, its caution and ▲ warnings, NEXT). Both checked cell for cell against `designs/07a-init.ans` at 24 bits (the mark) and `07a-init.txt` (the words).
- `lib/foreman-init.sh` draws in two goes so the header and files appear before the agent starts: `say` prints today's text or keeps it back, `fact` records the same thing for the renderer, and if node cannot draw the kept text is printed instead. Plain output is untouched (checked byte for byte against the pre-change output for fresh, again, `--force`, legacy ralph.conf, ordering ok/failed, empty batch and usage). The width the renderer needs (64) is `_init_min_cols`, tied by a smoke case.
- `lib/foreman-order.sh` leaves `FOREMAN_ORDER_RESULT=<file>` facts (result ordered/failed/skipped/empty, cost, the order before and after, human and check tickets, warnings) when asked; init reads them instead of parsing what order prints. `moved` is tickets not in the longest run that kept its order (one ticket taken to the front is 1).
- `--force` marks each file it replaced (`· replaced`); a kept file is an `=`; a legacy ralph.conf keeps its rename hint; a failed or unavailable ordering is a ✗ / ▲ line in the ordering's place; `--no-order` has no ordering line. On a real terminal a waiting line is shown during the agent call and cleared after.
- Deviation from the design, on purpose: NEXT steps 3 and 4 name the batch (`foreman dry-run <batch>`), as the plain text does, so they can be pasted when the repo has more than one batch. Not done: looking at it in a real window (Windows Terminal, mintty).
- Full smoke suite: 1356 passed in 0m 59s, 1 failed — "convert moves a ralph project…" (CRLF prose), which fails identically before this ticket.
