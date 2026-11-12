# gui — implementation order

`foreman-loop.sh` reads the block at the bottom of this file, takes the first ticket
whose Status line is not flipped, and runs exactly that one.

## Reasoning

**The spine: 01 → 01a → 02 → everything else.** Ticket 01 (sign off the designs) is a human
ticket, and 01a is its `Checks:` followup, so 01a sits immediately after it. Ticket 02 is
`Blocked by: 01a`, and every other ticket descends from 02 (03–08, 12 name it directly; 09, 10,
11, 13, 14, 15 and 15a reach it through the others). So the whole batch waits on 01, which
makes it first. There is nothing that doesn't depend on it, so no unattended stretch can come
before the first stop. 02 is also the heaviest foundation: `status --json`, the Electron shell,
`bash.cjs`, `watch.cjs` and the overview. It goes right after 01a.

**Human ticket 15** (try the app on a real batch) is `Blocked by: 14`, and 14 transitively
waits on every other ticket, so 15 is last, with its followup 15a immediately after it. Nothing
waits on 15 except 15a. Everything else runs before the loop stops there.

**Dependency chains**

- 08 (control directory, `keys`, `stop`) → 09 (`stop --now`) → 10 (start and watch a run).
  10 is also blocked by 04 (dry-run JSON; the confirmation takes its facts from
  `dry-run --json`). 10 → 11 (run-end banners).
- 06 (doctor JSON) and 12 (installer) → 13 (`foreman gui` and doctor's MACHINE line). 14 (docs)
  waits on 03, 05, 07, 11 and 13.
- Not obvious from the blocked-by lines: 07's "Start run is disabled" state and its
  Resume… button belong to the confirmation that 10 builds, and 11's `auth_failed` banner shows
  07's login-expired state. So 07 goes after 10 and before 11, where its Resume… can be wired to
  real code instead of staying disabled.
- Not obvious from the blocked-by lines: 08 defines the one `gui/node_modules/electron`
  "app is installed" check in `lib/`. 13's doctor line and the installer's installed-check should
  reuse it, so 13 comes after 08, and 12 (shell, with its own check) goes before both.

**Same area, kept adjacent.** 06, 08 and 13 all edit the doctor code in `lib/` and its tests,
so they run as 06, 08, 13 with nothing between them. `test/smoke-json.sh` is edited by nearly
every CLI ticket (02, 04, 05, 06, 08, 09, 12, 13); no ordering avoids that, but the chain makes
each edit sequential. 08, 09 and 10 form the stop/start chain over the loop; 13 is light, so
it sits between 08 and 09 and breaks up the heavy run.

**Load.** Heavy: 02, 08, 09 (starts with a Windows spike), 10, 12. 12 is pulled forward ahead
of 06/08 so it doesn't pile onto the 08, 09, 10 chain. The medium app tickets 03, 04 and 05
follow 02 to build up the app before the heavy CLI chain.

**Last.** 07 (six empty and error states) is a sweep-every-state ticket, so it is late, but it
needs 10 first. 14 (documentation, screenshots from the real app) is the last agent ticket.

<!--
The machine-readable order. One repo-relative ticket path per line, in run order.
foreman-next.sh reads only the lines between the ORDER markers.
-->

<!-- ORDER:BEGIN -->
```
.scratch/gui/issues/01-sign-off-the-picked-designs.md
.scratch/gui/issues/01a-followup-sign-off-the-picked-designs.md
.scratch/gui/issues/02-the-app-opens-on-a-repo-and-shows-the-overview.md
.scratch/gui/issues/03-ticket-page-and-handoff-editor.md
.scratch/gui/issues/04-dry-run-screen.md
.scratch/gui/issues/05-report-screen.md
.scratch/gui/issues/12-install-wizard-and-shortcut.md
.scratch/gui/issues/06-doctor-screen.md
.scratch/gui/issues/08-control-directory-keys-and-stop.md
.scratch/gui/issues/13-foreman-gui-and-doctor-line.md
.scratch/gui/issues/09-stop-now-on-windows.md
.scratch/gui/issues/10-start-and-watch-a-run.md
.scratch/gui/issues/07-empty-and-error-states.md
.scratch/gui/issues/11-run-end-banners.md
.scratch/gui/issues/14-document-the-app.md
.scratch/gui/issues/15-try-the-app-on-a-real-batch.md
.scratch/gui/issues/15a-followup-try-the-app-on-a-real-batch.md
```
<!-- ORDER:END -->
