# 14: Document the app

**What to build:** Add a new README section, "The desktop app (Windows)". It covers:

- what the app is, and what it never does: keep state, show secrets, or run its own loop
- how to install it (the wizard, `--gui` / `--no-gui`), how to update it
  (`git pull && bash install.sh`) and how to remove it
- `foreman gui`
- every additive CLI change: the `--json` flags with their shape and `foreman_json`,
  `foreman keys`, `foreman stop [--now]`, the control directory and its ignore line,
  `# reason:`, and the `model` field in `foreman-runs.jsonl` with `status --json`'s per-ticket
  `stats`
- which actions are free and which cost money, in the README's existing style

Add one screenshot per main screen, taken from the real app in dark, as the README's existing
pictures are. Apart from the new section and one line pointing to it from the command
reference, the README stays as it is.

See `spec.md`, "The additive CLI changes". The screenshots should match the picks: designs
`01-overview`, `02-ticket`, `03-run-confirm`, `04-live-run` and `07-report` in `designs/`.

**Blocked by:** 03, 05, 07, 11, 13, 16

**Status:** ready-for-agent

- [x] The section exists. Every additive CLI change in `spec.md` is described there, with an
      example
- [x] Each `--json` shape is given as a short example object, with a note that `foreman_json` is
      bumped only on an incompatible change
- [x] The section states the app's three rules (the files are the truth, one loop, the terminal
      unchanged) and the Windows-only scope
- [ ] Screenshots of the overview, the ticket page, the confirmation, the live run and the
      report are in the README's image folder, taken from the app
- [x] `foreman help` is byte for byte unchanged
- [ ] By hand: read the section on GitHub's rendering of the branch, and check every command in
      it in Git Bash
- [x] `test/smoke.sh` is unchanged and passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`

## Closing note

The section is in `README.md` ("The desktop app (Windows)", between "The logs" and "Files"), with
one pointer line under "At a glance". Every JSON example was taken from the real CLI in a
scratch repo (a fake-agent run, then `keys`/`stop` against a run in flight); the six JSON blocks
parse; `foreman help` md5 is unchanged; `test/smoke.sh` is untouched.

Full smoke suite: 2741 passed in 2m 10s (1 failed, "convert ... CRLF kept", pre-existing)

**Still open — why this stays `ready-for-agent`:**

- Screenshots (box 4): not taken. They have to come from the running Electron app, in dark, and
  this sandbox has no Electron, no Windows and no browser (the only `electron` is a one-file stub in
  `/tmp/standin`). A picture made any other way would not be "taken from the app". A human on
  Windows needs to save five PNGs to `docs/images/` (overview, ticket, confirmation, live run,
  report; designs 01, 02, 03, 04, 07) and add them to the new section, in the README's
  `<table>` style. The section has no image placeholder.
- By hand (box 6): read the section on GitHub's rendering of the branch; run each command in Git Bash.
