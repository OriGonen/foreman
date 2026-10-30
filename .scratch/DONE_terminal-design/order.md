# terminal-design — implementation order

`foreman-loop.sh` reads the block at the bottom of this file, takes the first ticket
whose Status line is not flipped, and runs exactly that one.

## Reasoning

**Dependency chains** (all from `Blocked by:`; none cross issue directories):

- 01 (colour tiers, palette) -> 02 (`ui_show`, `foreman-draw.cjs`, the help sunrise). 02 is
  the root of every show, so these two go first, in this order.
- 02 -> 03 (intro, animation support) -> 07 (doctor). 07 reuses the animation support that
  03 adds.
- 02 -> 04 (status) -> 05 (dry-run) and 06 (run). 04, 05 and 06 all rework output in
  `foreman-loop.sh` (`--status`, `dry-run`, the run output), so they sit adjacent and run
  sequentially rather than merging.
- 02 -> 08 (init, which adds the shared mark) -> 11 (report) and 13 (version), which reuse
  the mark. 11 and 12 both draw by requiring `foreman-draw.cjs` as a module, so they sit
  together.
- 09 (order), 10 (next) and 12 (convert) need only 02.
- 14 (docs) is blocked by 03, 05, 06, 07, 09, 10, 11, 12 and 13 and describes every scene,
  so it is last.

**Placement and load.** 01 and 02 are the foundations. 08 is small and unblocks 11 and 13,
and 13 is tiny, so they follow 03 while the renderer is fresh. The heavy tickets are 03
(animation, raw stdin, cursor safety), 04 and 06 (reworking `foreman-loop.sh` output; 06 also
touches the pinned bar and `--live`) and 07 (rewriting doctor and its smoke assertions).
They are spread out: 03 early; 04-05-06 as one block with the lighter 05 in the middle; the
small 09 and 10 next; then 07, the most self-contained and least foundational of the heavy
ones; then the light pair 11 and 12; and 14 to close.

<!--
The machine-readable order. One repo-relative ticket path per line, in run order.
foreman-next.sh reads only the lines between the ORDER markers.
-->

<!-- ORDER:BEGIN -->
```
.scratch/terminal-design/issues/01-colour-tiers-and-the-palette.md
.scratch/terminal-design/issues/02-the-renderer-and-help.md
.scratch/terminal-design/issues/03-the-intro.md
.scratch/terminal-design/issues/08-init-breaking-ground.md
.scratch/terminal-design/issues/13-version-mark.md
.scratch/terminal-design/issues/04-status-sunrise.md
.scratch/terminal-design/issues/05-dry-run-walk-round.md
.scratch/terminal-design/issues/06-run-sunrise-header.md
.scratch/terminal-design/issues/09-order-stake-line.md
.scratch/terminal-design/issues/10-next-stake-row.md
.scratch/terminal-design/issues/07-doctor-inspector.md
.scratch/terminal-design/issues/11-report-the-bill.md
.scratch/terminal-design/issues/12-convert-repainted-sign.md
.scratch/terminal-design/issues/14-document-the-show.md
```
<!-- ORDER:END -->
