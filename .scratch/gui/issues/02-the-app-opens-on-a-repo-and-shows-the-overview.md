# 02: The app opens on a repo and shows the batch overview

**What to build:** The first vertical slice. It has three parts:

- `foreman status --json` in the CLI;
- the `gui/` Electron app, started with `npm start` in `gui/` and given a repo path;
- the batch overview screen, built from that JSON.

See `spec.md`, "Architecture", "How data comes from the CLI" and additive change 1. The design
is `designs/01-overview.html`, from `designs/source/OverviewTakes.dc.html` (take a).

**Blocked by:** 01a

**Status:** ready-for-agent

**`foreman status --json`**

- [ ] `foreman status --json [<batch>] [--all]` prints one JSON object. It has
      `foreman_json: 1`, `command: "status"` and the fields in change 1. Batch paths in it are
      repo-relative, with forward slashes
- [ ] Without `--json`, the output of `foreman status` is byte for byte unchanged. Check it
      against a capture taken before the change, on the same fixture
- [ ] The output of `foreman help` is byte for byte unchanged
- [ ] `test/smoke-json.sh` exists and is built on `test/fixture.sh`. Its status cases check that
      the JSON parses, that `foreman_json` is 1, and that the counts, next ticket and human
      tickets match the plain output on the same fixture
- [ ] `test/bench.sh` shows that plain `foreman status` starts no new process

**The app**

- [ ] `gui/` exists, with the files in "Architecture". `electron` is its only dependency, pinned
      to an exact version and locked in `package-lock.json`. There are no native modules
- [ ] The window runs with `contextIsolation` and `sandbox` on and `nodeIntegration` off. It has
      a strict CSP and refuses navigation. All ticket and CLI text is set with `textContent`
- [ ] `gui/bash.cjs` finds Git Bash in the order given in "Windows paths", and never picks a WSL
      launcher. `node --test gui/test/` covers the lookup order
- [ ] `gui/watch.cjs` uses `fs.watch` with a 150 ms debounce, and never a timer poll. When a
      status line is flipped in an editor, the overview updates without a reload. If a `DONE_`
      rename happens mid-read, the read is retried and no error is shown. `node --test` covers
      the debounce and the rename
- [ ] Light and dark follow the Windows setting. The tokens come from `designs/source/gui.css`
- [ ] The app writes nothing to disk

**The overview screen**

- [ ] The overview has the rail with the batch list, and shows:
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
