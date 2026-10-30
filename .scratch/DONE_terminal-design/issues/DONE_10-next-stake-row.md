# 10: foreman next --all as the stake row

**What to build:** `foreman next --all` at a terminal shows the 9b design: a stake per
ticket with the next one tall, the ✓ / ▶ list with tags, and a "6 driven · 1 yours · 3 to
go" line. `--count` gets its one-line form. Bare `foreman next` and `--list` print bare
paths on every stream, because scripts read them. See `spec.md`, "Per command". The
design is `designs/09b-next.ans`, from `designs/source/NextTakes.dc.html` (panel 9b).

**Blocked by:** 02

**Status:** implemented

- [x] The stake row wraps or narrows for batches wider than the terminal, or falls back to plain
- [x] Bare `next`, `--list` and `--unordered` are unchanged on every stream, a terminal included
- [x] Smoke: forced-show `--all` and `--count`; bare `next` under `FOREMAN_SHOW=always` still prints bare paths
- [x] `test/bench.sh next`: the plain path adds no process
- [x] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`

## Closing note

- Built: scenes `next` and `next-count` (min 40) in `lib/foreman-draw.cjs`; `foreman-next.sh` draws them for `--all` and `--count` when `ui_show` and the width allow (`_next_min_cols=40`), all or nothing, else `foreman_next_answer` as before. The row wraps after `(cols-2)/6` stakes; labels and names are cut to fit.
- Bare `next`, `--list`, `--unordered` never reach the show. `foreman_next_answer` is untouched, so the loop's in-process calls never draw. Doctor reads `--count` through `$( )`, so it now sets `FOREMAN_SHOW=never` for that call (a forced show would have handed it the picture).
- `test/bench.sh next`: `foreman next batch --all` is 108 spawns before and after. The script now takes `status|next` and the run count in either order.
- Full smoke suite: 2031 passed in 1m 46s, 1 failed (the same pre-existing CRLF `convert` case).
