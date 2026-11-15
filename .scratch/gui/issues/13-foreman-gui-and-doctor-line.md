# 13: `foreman gui`, and doctor's desktop-app line

**What to build:** Two additions, both new.

- **`foreman gui [<dir>]`** opens the app on the repo that holds `<dir>`, detached, and returns
  at once. If the app isn't installed, it says so. At a terminal, it also offers to install the
  app (`[y/N]`), by running `install.sh --gui`.
- **Doctor's MACHINE section** gets the line "desktop app installed · in sync", or "out of date:
  rerun install.sh" when `gui/package-lock.json` is newer than `gui/node_modules`. The line is
  shown only when the app is installed. It appears in `doctor --json` too.

See `spec.md`, additive change 10. The designs are:

- `designs/08-doctor.html` (`designs/source/DoctorTakes.dc.html`, take a): the MACHINE row
- `designs/10-install-wizard.html` (`designs/source/WizardTakes.dc.html`, take a2): the
  `[y/N]` offer

**Blocked by:** 06, 12

**Status:** implemented

**`foreman gui`**

- [x] `foreman gui` starts `electron.exe gui <repo>` detached and returns within a second. It
      leaves no process tied to the terminal.
- [x] `<repo>` comes from `git rev-parse --show-toplevel` and is passed in mixed form.
- [x] Outside a repo, it opens the app anyway. The app shows its "not a git repo" state.
- [x] When the app is missing and the terminal is interactive, it prints one line and asks
      `[y/N]`. Without a terminal, it prints the line and exits 1.

**Doctor's MACHINE line**

- [x] The line is in plain doctor and in `doctor --json` only when `gui/node_modules/electron`
      exists. Otherwise doctor's output is byte for byte unchanged; test this against a capture.

**Help and tests**

- [x] `foreman help` is byte for byte unchanged. `gui` is documented in the README (ticket 14),
      not in help.
- [x] `test/smoke-json.sh` covers `foreman gui` with a stub `electron.exe`, and the doctor line
      with the app faked as installed and not installed.

**By hand on Windows**

- [ ] In Git Bash and in PowerShell (`foreman.cmd`), run `foreman gui` from a batch directory.
      The app opens on this repo.
- [ ] Remove `gui/node_modules` and run `foreman gui` again. It offers to install.
- [ ] Compare doctor's MACHINE line with `designs/08-doctor.html`.

**Smoke suite**

- [x] `test/smoke.sh` is unchanged and the full suite passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`.

**Closing note**

- Full smoke suite: 2741 passed in 2m 5s, 1 failed: "convert ... CRLF kept" (`test/smoke.sh:3609`),
  which failed before this ticket. `test/smoke.sh`, `bin/foreman`'s help and `test/golden/` are unchanged.
- `test/smoke-json.sh`: 823 passed, 0 failed.
- The by-hand Windows boxes are open: no Windows here (no `powershell.exe`, no Electron).
- `foreman gui` is `lib/foreman-gui.sh`; the in-sync check is `foreman_app_in_sync` in
  `lib/foreman-repo.sh`, beside `foreman_app_installed`. The box wraps the out-of-date row at its
  column; `doctor --json` carries the row whole.
