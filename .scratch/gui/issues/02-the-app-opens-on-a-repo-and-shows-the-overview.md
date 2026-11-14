# 02: The app opens on a repo and shows the batch overview

**What to build:** The first vertical slice. It has three parts:

- `foreman status --json` in the CLI;
- the `gui/` Electron app, started with `npm start` in `gui/` and given a repo path;
- the batch overview screen, built from that JSON.

See `spec.md`, "Architecture", "How data comes from the CLI" and additive change 1. The design
is `designs/01-overview.html`, from `designs/source/OverviewTakes.dc.html` (take a).

**Blocked by:** 01a

**Status:** implemented

**`foreman status --json`**

- [x] `foreman status --json [<batch>] [--all]` prints one JSON object. It has
      `foreman_json: 1`, `command: "status"` and the fields in change 1. Batch paths in it are
      repo-relative, with forward slashes
- [x] Without `--json`, the output of `foreman status` is byte for byte unchanged. Check it
      against a capture taken before the change, on the same fixture
- [x] The output of `foreman help` is byte for byte unchanged
- [x] `test/smoke-json.sh` exists and is built on `test/fixture.sh`. Its status cases check that
      the JSON parses, that `foreman_json` is 1, and that the counts, next ticket and human
      tickets match the plain output on the same fixture
- [x] `test/bench.sh` shows that plain `foreman status` starts no new process

**The app**

- [x] `gui/` exists, with the files in "Architecture". `electron` is its only dependency, pinned
      to an exact version and locked in `package-lock.json`. There are no native modules
- [x] The window runs with `contextIsolation` and `sandbox` on and `nodeIntegration` off. It has
      a strict CSP and refuses navigation. All ticket and CLI text is set with `textContent`
- [x] `gui/bash.cjs` finds Git Bash in the order given in "Windows paths", and never picks a WSL
      launcher. `node --test gui/test/` covers the lookup order
- [x] `gui/watch.cjs` uses `fs.watch` with a 150 ms debounce, and never a timer poll. When a
      status line is flipped in an editor, the overview updates without a reload. If a `DONE_`
      rename happens mid-read, the read is retried and no error is shown. `node --test` covers
      the debounce and the rename
- [x] Light and dark follow the Windows setting. The tokens come from `designs/source/gui.css`
- [x] The app writes nothing to disk

**The overview screen**

- [x] The overview has the rail with the batch list, and shows:
  - the dome, sized by tickets landed
  - the next ticket
  - the human ticket that is waiting
  - the run-until note
  - the warnings
  - the order, with each ticket's spend

  Free actions are marked free

**Checks**

- [ ] By hand on Windows: open the app on this repo and compare it with
      `designs/01-overview.html` in light and dark. Every number on the overview matches plain
      `foreman status` for the same batch
- [ ] `test/smoke.sh` is unchanged and the full suite passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`

**Closing note**

- Full smoke suite: 2741 passed in 2m 21s. One case fails and failed before this ticket: "prose
  is converted, CRLF kept, the credit and the project's own file name left alone"
  (`test/smoke.sh:3609`). It fails the same way on the tree from before this ticket
  (`1651230`), and `test/smoke.sh` is not edited, so that box stays unchecked. `ui_color_tier`
  failed once in a first full run (a `script` pty row came back empty) and passed in the next
  run and in four runs of its own.
- `bash test/smoke-json.sh`: 99 passed. `node --test` in `gui/`: 93 passed.
- Plain output: `foreman status` and `foreman help` are byte for byte what the tree from before
  this ticket prints, on the same fixture (`test/golden/`, retaken from that tree and compared
  with `cmp`). The `help` capture holds the checkout path as `@FOREMAN_HOME@` so it is true on any
  machine.
- `test/bench.sh`: plain `foreman status batch` has the same spawns before and after: 108
  subshells and command substitutions, 116 in all, with the same external commands (git 2, bash,
  cut, find, grep, rm and sort once each). Running `status` writes nothing into a batch, so the
  watcher cannot feed itself.
- **Not done here, and needs a person on Windows:** the by-hand check. This was written in a
  Linux sandbox with no Electron binary and no browser, so the window has never been opened and
  nothing has been compared with `designs/01-overview.html`. What is checked instead: `app.js`
  runs against a fake DOM in `gui/test/app.test.cjs`, and `main.cjs` was driven through a
  stand-in `electron` module with the real CLI. Run `npm install` and `npm start -- <repo>` in
  `gui/`, then compare the overview with the design in light and dark and check each number
  against `foreman status`. Ticket 15 walks through the whole app.
- `Dry run`, `Start run…` and `Fill in handoff` are drawn, marked free / costs money, and
  disabled until their own tickets (04, 10, 03). `Open ticket` and `Open folder` work.
- With no repository argument the app opens on the repository holding the current directory;
  asking for a folder is the "not a git repo" state in ticket 09.

