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

**Status:** ready-for-agent

**`foreman gui`**

- [ ] `foreman gui` starts `electron.exe gui <repo>` detached and returns within a second. It
      leaves no process tied to the terminal.
- [ ] `<repo>` comes from `git rev-parse --show-toplevel` and is passed in mixed form.
- [ ] Outside a repo, it opens the app anyway. The app shows its "not a git repo" state.
- [ ] When the app is missing and the terminal is interactive, it prints one line and asks
      `[y/N]`. Without a terminal, it prints the line and exits 1.

**Doctor's MACHINE line**

- [ ] The line is in plain doctor and in `doctor --json` only when `gui/node_modules/electron`
      exists. Otherwise doctor's output is byte for byte unchanged; test this against a capture.

**Help and tests**

- [ ] `foreman help` is byte for byte unchanged. `gui` is documented in the README (ticket 14),
      not in help.
- [ ] `test/smoke-json.sh` covers `foreman gui` with a stub `electron.exe`, and the doctor line
      with the app faked as installed and not installed.

**By hand on Windows**

- [ ] In Git Bash and in PowerShell (`foreman.cmd`), run `foreman gui` from a batch directory.
      The app opens on this repo.
- [ ] Remove `gui/node_modules` and run `foreman gui` again. It offers to install.
- [ ] Compare doctor's MACHINE line with `designs/08-doctor.html`.

**Smoke suite**

- [ ] `test/smoke.sh` is unchanged and the full suite passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`.
