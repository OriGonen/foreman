# 12: The install wizard, the shortcut, and uninstall

**What to build:** `bash install.sh` asks one question: CLI only, or CLI and the desktop app. It
asks only when both stdin and stdout are terminals.

- `--gui` and `--no-gui` answer the question up front.
- On a rerun, the installer offers only the piece that is missing.
- When everything is installed, it asks nothing.
- Installing the app runs `npm ci` in `gui/` and writes the Start-menu shortcut.
- `--uninstall` removes everything, including the app and the shortcut.

See `spec.md`, "Answers recorded" (How it's installed) and "Windows paths" (The shortcut). The
design is `designs/10-install-wizard.html`, from `designs/source/WizardTakes.dc.html` (take a,
and a2 for the rerun).

**Blocked by:** 02

**Status:** ready-for-agent

**The question**

- [ ] The installer asks only when `[ -t 0 ] && [ -t 1 ]`.
- [ ] Everywhere else, including under `test/smoke.sh`, in a pipe and in CI, its output is byte
      for byte what it is today. Check this against a capture.
- [ ] The question is a numbered choice read with a plain `read`. Enter picks 1, CLI only.
- [ ] The wording follows `designs/10-install-wizard.html`, with its sunrise header.
- [ ] `--gui` installs the app without asking. `--no-gui` removes the app and its shortcut if
      they are there, and never asks.

**Installed or not**

- [ ] Whether the app is installed is read from disk: `gui/node_modules/electron` and the
      shortcut. On a rerun with only the CLI installed, the installer shows take a2.
- [ ] Without `npm`, choosing the app says it needs Node's npm, and installs the CLI only.

**The shortcut**

- [ ] The shortcut is `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Foreman.lnk`, written
      through `powershell.exe -NoProfile` and `WScript.Shell`. Its target is the checkout's
      `electron.exe`, its argument is `gui`, and its icon is `gui\icon.ico`.

**Uninstall**

- [ ] `--uninstall` also removes `gui/node_modules` and the shortcut.
- [ ] It touches no batch, no `~/.config/foreman/env` and no credential.

**Checks**

- [ ] `test/smoke-json.sh` covers the non-TTY path (unchanged), `--gui` with a stub `npm` and a
      stub `powershell.exe` on PATH, `--no-gui`, and `--uninstall`.
- [ ] By hand on Windows, in Git Bash's mintty:
  1. Run `bash install.sh` and pick 2. The Start-menu entry opens the app.
  2. Rerun it. It asks nothing.
  3. Run `--no-gui`. The app and its shortcut are gone.
  4. Rerun it. It shows take a2.
  5. Run `--uninstall`.
- [ ] Nothing under `bin/` or `lib/` changes in this ticket, apart from what `install.sh` itself
      needs.
- [ ] `test/smoke.sh` is unchanged and passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`.
