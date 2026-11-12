# 07: Empty and error states

**What to build:** Six states. Each one fills the whole pane with a picture, one sentence, the
CLI's own message, and one button.

| State | Shows | Button |
|---|---|---|
| Not a git repo | — | Choose a folder… |
| No batch | the `foreman init` command | copies the command |
| Git Bash missing | the paths it looked in | Look again |
| `claude` / `sbx` missing for the batch's exec mode | runs are off; everything else works | opens Doctor |
| Login expired | the run stopped with exit 20 and `auth_failed`; resuming costs money | Resume… |
| Batch unreadable | the CLI's stderr, as text | opens the file in an editor |

The design is `designs/09-empty-and-error.html`, from `designs/source/StatesTakes.dc.html`
(take a).

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] Each of the six states appears when its condition holds. When none holds, the app shows
      the overview. Each state's message comes from the CLI's stderr or its JSON; the app never
      writes its own
- [ ] Not a git repo: Choose a folder opens a folder picker and reopens the app on the folder
      picked. The app remembers nothing
- [ ] Git Bash missing: the state lists every path `bash.cjs` tried. Look again runs the lookup
      again
- [ ] `claude` / `sbx` missing: Start run is disabled and says why. Status, dry run and report
      still work
- [ ] Login expired: shown when `status --json` gives `last_run.end` as "needs a human" and the
      run's last jsonl line has `auth_failed`. Resume… is marked "costs money" and goes through
      the run confirmation from ticket 10. Until ticket 10 lands, it is disabled
- [ ] `node --test gui/test/` covers choosing the state from fixture JSON and stderr
- [ ] By hand on Windows: bring up each state and compare it with
      `designs/09-empty-and-error.html` in light and dark:
  - a folder that isn't a repo
  - an empty repo
  - `FOREMAN_BASH` pointed at a missing file
  - a batch with `FOREMAN_EXEC=sandbox` and no `sbx` on PATH
  - a fixture log ending in `auth_failed`
  - an `order.md` that names a missing ticket
- [ ] Nothing under `bin/` or `lib/` changes in this ticket
- [ ] `test/smoke.sh` is unchanged and passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`
