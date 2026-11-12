---
status: accepted
---

# The app is an Electron window over the same CLI, run from the checkout

Foreman was a terminal program and nothing else. The gui batch (`.scratch/gui/`) adds **the
app**: an optional desktop window on Windows. It shows the batches, the run and the bill, and
it starts and steers the same `foreman run`.

The app is built in Electron. It is plain HTML, CSS and JavaScript, `electron` is its only
dependency, and it runs from the git checkout like the rest of foreman. `bash install.sh` offers
it, and `npm ci` fetches it into `gui/node_modules`. The app has no installer, no signing and no
auto-update. Updating it is `git pull && bash install.sh`, the same as updating the CLI.

The app holds no state. Every fact it shows is either read from the batch's files or asked of
the CLI with a new `--json` flag. A run started from the app is a plain `foreman run`, started
detached, and the app steers it through the run's control directory. The app adds no second
loop and no second model of a batch. Removing `gui/` would leave foreman exactly as it was
before.

## Considered options

**Tauri** was rejected. Its window is the system WebView (WebView2 on Windows), so the app would
be a few MB instead of about 250. But Tauri's main process is Rust. Foreman would then need a
Rust toolchain on every machine that builds the app, or released binaries, which means signing,
hosting and a release process. All three are things foreman doesn't have and the user ruled out.
Electron's main process is Node, and foreman already needs Node (`lib/*.cjs`), so the app adds
one npm package and no new toolchain.

**A local web UI** (`foreman serve` plus a browser tab) was rejected. It needs a server running
for as long as the tab is open, and that is the daemon the performance rules forbid. It also
needs a port, which can collide, and a way to keep other local pages from calling it, which is a
security surface a desktop window doesn't have. Watching files and starting detached processes
are natural in a main process and awkward through HTTP.

**A richer TUI** was rejected. It would be the terminal again, and the terminal is not to
change. The terminal-design batch already gave the terminal its pictures.

**Building the app with a framework** (React, Svelte and the like) was rejected. A framework
brings a bundler, a dependency tree, and churn that a hand-bumped, run-from-checkout app can't
absorb. The app has ten screens, a handful of components, and no client-side state beyond the
current view, so plain DOM code is enough.

**A pseudo-terminal (node-pty) for steering a run** was rejected. It is a native module, which
needs a build toolchain on Windows and a rebuild for every Electron bump. It would also make the
app the owner of the run's terminal, so closing the window would end the run. Instead, the
control files the run's own keys already write are moved where another process can reach them,
and the CLI gets two commands for them: `foreman keys` and `foreman stop`.

## Consequences

- The app is Windows only for now. Its code keeps the Windows-specific parts (the lookup for Git
  Bash, the Start-menu shortcut) in two places, but macOS and Linux are not built or tested.
- The app has a light theme as well as a dark one. ADR 0003 left a light palette as "a later
  decision". This ADR makes that decision for the app only: the light palette in `.scratch/gui/spec.md`
  follows Windows' light/dark setting. The terminal's palette is unchanged and still dark only.
- Installing the app costs about 250 MB in `gui/node_modules`. That cost lands only on someone
  who chooses the app. With the app closed, it costs nothing: no daemon, nothing at login, and
  no process added to any CLI command.
- `foreman` gains the additive commands and flags listed in the gui spec. `foreman help` doesn't
  list them, so that its output stays byte for byte the same. The README documents them.
- Electron is bumped by hand once or twice a year. The app uses only long-stable APIs
  (`BrowserWindow`, `contextBridge`/`ipcMain`, `child_process`, `shell.openPath`,
  `nativeTheme`), so that a bump is a version change in `gui/package.json` and nothing more.
- Agent and ticket text is shown only as text, never as HTML, under a strict CSP. A ticket can
  therefore never run code in the window.
