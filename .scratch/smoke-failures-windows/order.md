# smoke-failures-windows — implementation order

Three dependency chains are explicit in the `Blocked by:` lines, and I followed them exactly:

- **01 → 02.** Ticket 02 follows the product-or-test decision written in ticket 01's closing note. Both fix path-form mismatches in the Windows output (spec cluster A), so they run back to back. Ticket 01 is the larger one: seven cases, plus the decision that 02 inherits. Ticket 02 is a two-case follow-on.
- **03, 04 → 07.** Ticket 07 (cases 15 and 16) asks whether the app-installed fix from 03 or the locale fix from 04 already explains them. It has to come after both, and I put it directly after 03 so the notes are fresh. Its first job may be only to confirm that those cases now pass.
- **01–08 → 09.** Ticket 09 is the full-suite sweep that also closes the spec, so it goes last.

The remaining tickets (05, 06 and 08) have no blockers, so I ordered them by importance and load:

- **04 goes between 02 and 03.** It is a small, self-contained locale fix: `wc -m` counted bytes in case 9. It also unblocks 07. Putting it after the large 01/02 pair and before the heavy 03 stops the two big tickets running back to back.
- **03 comes before 07.** It is the larger and more foundational of the two ahead of 07. It may need a narrow product seam for "is the app installed?", plus new cases that cover both answers. It also explains cases 3, 7, 17, 18 and 21, and possibly 15.
- **05 comes after 07.** It is a separate cluster (D: exit 127 when a tool is removed from PATH). It is medium-sized, and it may turn out to be a real product bug.
- **08 comes after 05.** It runs the design cases and the stale-skill doctor case from a fresh clone. It is more meaningful once the path, locale, app and PATH fixes have landed, since any of them could have caused the baseline failures. It is mostly investigation and may end with "nothing to decide."
- **06 comes last, before 09.** The timing cases (22, 13 and 8) need three quiet runs each, so this ticket is slow. Its outcome is mostly independent of the others, and any real bug it finds, such as the case 22 slowness, can become its own ticket. Running it late also means the machine is not busy with other work while it measures.

None of the dependencies cross issue directories.

<!-- ORDER:BEGIN -->
```
.scratch/smoke-failures-windows/issues/01-report-and-convert-show-one-path-form-on-windows.md
.scratch/smoke-failures-windows/issues/02-foreman-draw-shows-the-paths-you-would-expect-on-windows.md
.scratch/smoke-failures-windows/issues/04-widths-are-counted-in-characters-on-git-bash.md
.scratch/smoke-failures-windows/issues/03-the-suite-decides-whether-the-desktop-app-is-installed.md
.scratch/smoke-failures-windows/issues/07-explain-and-fix-the-run-log-and-the-order-header.md
.scratch/smoke-failures-windows/issues/05-tests-that-take-a-tool-off-path-work-on-git-bash.md
.scratch/smoke-failures-windows/issues/08-the-design-cases-pass-from-a-clean-clone.md
.scratch/smoke-failures-windows/issues/06-the-timing-cases-run-alone.md
.scratch/smoke-failures-windows/issues/09-full-smoke-suite-on-windows-alone.md
```
<!-- ORDER:END -->
