# 10: Start a run, and watch it live

**What to build:** Two screens.

**The confirmation.** Start run… and Resume… open it. It shows:

- where the run starts and how far it can reach
- the iteration budget, which can be changed. It is the only field that is editable at first
- `FOREMAN_MAX_COST_USD` and `FOREMAN_MAX_MINUTES`, each with where it is set; a cap that isn't
  set says "none set", in rust. They become editable, for this run only, under **Advanced
  options**, which also holds the live view and shows the model and mode
- a `?` beside every field that says what it does
- the exact command
- one button: "Start run · up to $X", or "Start run · no spend cap" when there is no cap

**The live run screen.** It shows:

- the iterations in order, each with its outcome and cost
- the feed under the iteration that is running
- the run bar, with `+` / `-` / `L`, Stop after this one, and Stop now…
- a **Full view | Compact view** switch, which shrinks the window to a small layout and back

Both screens use only the CLI. The run is a plain `foreman run`, spawned detached. The bar calls
`foreman keys` and `foreman stop`, and the screen is rebuilt from the files. Closing the window
never stops the run.

See `spec.md`, "Starting, watching and stopping a run" and "Free and paid". The designs are:

- `designs/03-run-confirm.html`, from `designs/source/ConfirmTakes.dc.html` (take c; c1 is
  Advanced options open and c2 holds the words behind each `?`)
- `designs/04-live-run.html`, from `designs/source/LiveRunTakes.dc.html` (take a, and c for the
  compact view)

**Blocked by:** 04, 08, 09

**Status:** ready-for-agent

**The confirmation**

- [ ] Its facts come from `dry-run --json` and `foreman.conf`
- [ ] By default only the iteration count is editable. The batch, where the run starts and where
      it can reach are shown. The spend cap and time cap are shown with where each comes from
- [ ] Advanced options opens the spend cap, the time cap and the live view, and shows the model
      and mode without letting them be edited
- [ ] A cap edited there applies to this run only: it is passed to the spawned run as
      `FOREMAN_MAX_COST_USD` or `FOREMAN_MAX_MINUTES` in its environment, and it appears as a
      prefix in the exact command. `foreman.conf` is not written, and the next confirmation starts
      again from the file
- [ ] A value that differs from the file says so and has a way back. A cap raised above the
      file's, or set to 0 where the file has a cap, is marked in rust. The button follows the
      edited spend cap ("up to $X", or "no spend cap")
- [ ] A cap that is not a whole number of minutes, or dollars with up to two decimals, is refused
      on the field as text, and Start run stays disabled until it is fixed
- [ ] `node --test gui/test/` covers that check, and building the spawn env and the displayed
      command with and without an edited cap
- [ ] Every field has a `?` that opens a plain-text popover with the words in
      `designs/03-run-confirm.html` (c2). It opens on click or keyboard focus and closes on Esc
      or a click elsewhere. The text is set with `textContent`. The time cap's says it is for the
      whole run, not each iteration
- [ ] The budget field becomes the `<n|--unlimited>` argument of the run. The live view field
      decides whether `--live` is passed
- [ ] When `**/.foreman-run/` isn't ignored, Start run is disabled and reads "Starting from the
      app needs `doctor --fix`"
- [ ] It is the only way to start a run. Start run and Resume are marked "costs money", and no
      other control starts a run

**Starting the run**

- [ ] Start spawns `<bash.exe> bin/foreman run <batch> <n> --live` with:
  - `detached` and `windowsHide`
  - stdin ignored
  - stdout and stderr going to `<batch>/.foreman-run/out`
  - `FOREMAN_SHOW=never`, `FOREMAN_COLOR=never` and `GIT_OPTIONAL_LOCKS=0`
- [ ] The app does not wait on the process

**The live run screen**

- [ ] Iterations and their outcomes come from the jsonl, and the outcome words from
      `report --json --run <id>`
- [ ] The running ticket comes from `status --json`, and the feed from `.foreman-run/feed`
- [ ] Everything updates through `watch.cjs`, never through a poll
- [ ] A **Full view | Compact view** switch at the top right changes between take a and take c.
      Compact resizes the window to the compact size and Full view puts the previous size back,
      with no memory after the app closes. When the run ends the app returns to the full view by
      itself

**The run bar**

- [ ] `+` / `-` / `L` call `foreman keys`, and the bar shows the new budget from the control
      directory
- [ ] Stop after this one calls `foreman stop`
- [ ] Stop now… asks first, with "The ticket's uncommitted work is kept, and the next run reviews
      it", then calls `foreman stop --now`

**Reattaching**

- [ ] Close the app mid-run and reopen it: the same run shows, with the same iterations and the
      same budget
- [ ] A run started in a terminal shows the same way
- [ ] When that run's control directory is not in the batch, the bar is disabled and says
      "Steering needs `doctor --fix`"

**Checks**

- [ ] `node --test gui/test/` covers building the spawn arguments and the env, and rebuilding
      the screen from fixture files
- [ ] By hand on Windows, on a throwaway batch with a low `FOREMAN_MAX_COST_USD`:
  1. Start a 2-iteration run from the app
  2. Compare the screens with both designs, in light and dark, with Advanced options open and
     closed and in the compact view
  3. Press `+`, then `L`
  4. Close and reopen the app
  5. Press Stop after this one
  6. Check `foreman-runs.log` and plain `foreman status` against what the app shows
- [ ] Nothing under `bin/` or `lib/` changes in this ticket
- [ ] `test/smoke.sh` is unchanged and passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`
