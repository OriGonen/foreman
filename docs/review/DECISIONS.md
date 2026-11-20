# Owner decisions: implementation plan

The owner approved all seven recommendations (2026-11-21), plus R4 as scoped below. Each ticket gets one commit on `review/deep-refactor` and comes with a regression test that fails before the change. The rules in `PLAN.md` § "How to work a ticket" apply.

## How this runs

- One agent per ticket, each in its own worktree under `$TEMP/fm-<id>` on branch `review/<id>`. The lead cherry-picks the commits onto `review/deep-refactor`.
- Agents run only targeted tests: `bash test/smoke.sh "<substring>"`, `bash test/smoke-json.sh "<substring>"`, `node --test "test/node/*.test.cjs"`, `cd gui && node --test`. The Windows baseline has known platform failures. "Green" means no new failing (case, assertion) compared with the same cases on the base commit.
- New smoke cases go next to the related cases, not at the end of `test/smoke.sh`.
- User-visible changes update `README.md`, and `lib/foreman.conf.template` when a knob is added.

| Wave | Tickets | Model | Why grouped |
|------|---------|-------|-------------|
| 1 | D1, D5, D6+R4, D7 | sonnet | Disjoint files, mostly small |
| 2 | D3, D4 | opus | Cross-layer contracts (executor, control dir) |
| 3 | D2 | opus | Touches the turn loop, the executors and the control dir; needs D3 and D4 landed |

## Tickets

### D1: `convert` refuses when it would touch untracked files (B4)
- **Files:** `lib/foreman-convert.cjs` (guard at about :146, rewrite at about :225), tests in `test/node/` and/or smoke.
- **Behaviour:** before writing anything, collect the files the conversion would modify or rename. If any of them is untracked (`git ls-files --others --exclude-standard`) or ignored-but-present, refuse with exit 1, list up to about 10 of them, and say: commit them, stash them with `git stash -u`, or move them aside, then re-run. `--dry-run` still lists everything it would do, marks the untracked files, and exits as it does today.
- **Accept:** a repo with an untracked file containing "Ralph" is refused and the file is byte-identical afterwards. The tracked-only case still converts. The existing convert cases keep their pass/fail set.

### D7: `init --force` keeps backups (B31, first part)
- **Files:** `lib/foreman-init.sh` (:80, :217, :235).
- **Behaviour:** before `--force` overwrites `progress.txt` or `foreman.conf`, move the old file to `<name>.bak`, replacing any older `.bak`. Print one line per backup. No change without `--force`.
- **Accept:** a smoke case shows both `.bak` files hold the old contents and the new files are fresh.

### D5: `dry-run` on a dirty tree; conflicting mode flags (B28)
- **Files:** `bin/foreman` (dispatch, about :146), `lib/foreman-loop.sh` (mode flags about :120–135, dirty guard about :909), `lib/foreman-dryrun.sh`.
- **Behaviour:**
  - `foreman dry-run` on a dirty tree proceeds and prints one note that `run` would refuse until the tree is clean (or `--adopt-dirty`).
  - A second mode flag is an error, exit 1, naming both modes. For example `foreman status --dry-run`, `foreman run --status` and `dry-run --status` all fail. The internal flag the dispatcher appends must not trip this when the user gave no conflicting flag.
- **Accept:** smoke cases for dirty-tree dry-run (exit and note) and for `status --dry-run` (exit 1, message). The existing status, dry-run and run cases are unchanged.

### D6+R4: env vs conf (B21), and read-only commands don't migrate
- **Files:** `lib/foreman-config.sh` (env snapshot about :140–160, migration call sites), `lib/foreman-legacy.sh`, entry points that source config (`foreman-loop.sh` for status, dry-run and run, `foreman-control.sh`, `foreman-next.sh`, `foreman-order.sh`, `foreman-json.cjs` if it shells out).
- **Behaviour:**
  1. An env var that is set but empty is ignored: the conf value (or the default) wins. Document this.
  2. Array-valued knobs (find them in the conf template and config, e.g. extra `claude` args): when they come from the environment, fail with exit 1 and a message saying the knob must be set in `foreman.conf`. Today only element 0 survives, which is worse.
  3. R4, narrowed: migrating legacy `ralph-*` files (the moves and deletes) happens only on mutating commands: `run`, `init`, `order`, `convert`. Read-only commands (`status`, `dry-run`, `next`, `stop`/`keys`, `--json`) read legacy files where they are, don't move or delete anything, and may print one hint that `foreman run` will migrate them. The `cd` to the repo root stays. Doctor keeps its text reader, on purpose.
- **Accept:** smoke cases: `FOREMAN_MODEL= foreman dry-run` shows the conf model; an array knob from env exits 1; `foreman status` on a batch with legacy files leaves them in place and `run` migrates them. The existing legacy cases are updated only where they asserted migration on a read-only command.

### D3: `foreman order` goes through the executor
- **Files:** `lib/foreman-order.sh` (raw `claude` at about :264), `lib/foreman-exec.sh`, `lib/exec/{local,sandbox,sandbox-mount,fake,_common,_sbx}.sh`.
- **Behaviour:** add a one-shot adapter entry point, `exec_ask` (prompt in, reply text out, with exit status). Each adapter runs it the way it runs agent turns: `local` runs `claude -p` on the host with the configured permission settings, the sandbox modes run it inside the sandbox via `sbx exec`, and `fake` returns a canned or `FOREMAN_FAKE_*`-driven reply. `foreman-order.sh` calls it instead of `claude`, so the model, effort and permission settings come from the same place a run takes them. If the executor's preflight fails (e.g. the sandbox is not available), ordering is skipped with a clear message, the same non-fatal path as today's "'claude' is not on PATH".
- **Accept:** a smoke case with `FOREMAN_EXEC=fake` orders via `exec_ask` (the fake records that it was called). The local adapter still produces the same command line (test with a stub `claude` on PATH). The existing order cases keep their pass/fail set. Update `docs/` and the adapter-contract comment.

### D4: control dir under `.git/` when `.foreman-run/` is not ignored
- **Files:** `lib/foreman-ctl.sh` (`ctl_rel_dir`), `lib/foreman-ctl.cjs`, `lib/foreman-loop.sh` (:667, :834–842), `lib/foreman-control.sh` (:91), `lib/foreman-status.sh` (:101), `gui/live.cjs`, `gui/runner.cjs`, `gui/foreman.cjs`.
- **Behaviour:**
  - One resolver in bash and its twin in node. If `<batch>/.foreman-run/` is gitignored, use it, as today. Otherwise use `$(git rev-parse --git-dir)/foreman-run/<key>`, where `<key>` is the batch's repo-relative path with `/` turned into `__` (or another reversible, filesystem-safe mapping, the same in both languages).
  - Readers (stop, keys, status, GUI) use the same resolver, so the lock (T03), `stop` and the GUI live view all work without the ignore line. The `mktemp -d` fallback goes away, except when there is no git dir at all, which can't happen in a repo.
  - `doctor` mentions which location a batch uses.
- **Accept:** in a batch without the ignore line: a second run is refused, `foreman stop` reaches the run, and the status "in flight" line appears. The Node `ctl` tests cover the resolver. The GUI tests pass. The existing T03 and stop cases are unchanged.

### D2: agent turn timeout
- **Files:** `lib/foreman-config.sh` (knob and validation), `lib/foreman.conf.template`, `lib/foreman-loop.sh` (turn execution, stall path), `lib/exec/fake.sh` (a hang behaviour, or reuse of `FOREMAN_FAKE_SLEEP`), `README.md`.
- **Knob:** `FOREMAN_TURN_TIMEOUT_MINUTES`, a positive integer, or `0` for off. **Default 60.** It is validated like the other numeric knobs (T01 rules). A test-only `FOREMAN_TIMEOUT_UNIT_SECONDS` (default 60, undocumented) lets tests use seconds.
- **Behaviour:** a watchdog starts with each agent turn (work and review turns). When it fires, it ends the agent the same way `stop --now` / SIGTERM does (T13's tree kill), then the loop treats the turn like a stall: checkpoint any uncommitted work (the existing stall-checkpoint path), then pause with exit 10 and a reason naming the timeout. A turn that finishes in time cancels the watchdog. The watchdog must never outlive the run.
- **Accept:** smoke cases:
  - a fake turn sleeping past a 2-second timeout pauses with exit 10 and the timeout reason, and leaves a checkpoint commit when work was dirty;
  - a fast turn is unaffected;
  - `FOREMAN_TURN_TIMEOUT_MINUTES=0` disables the watchdog;
  - `abc` fails preflight.

## After the waves
- Full `smoke.sh` and `smoke-json.sh` runs on the final tip, compared with `FULL-RUN.md` keys; Node and GUI suites.
- `PLAN.md` status table gets D1–D7 and R4. The hand checks from `PLAN.md` remain for the owner.

## Status
| Ticket | State | Commit |
|--------|-------|--------|
| D1 | todo | |
| D5 | todo | |
| D6+R4 | todo | |
| D7 | todo | |
| D3 | todo | |
| D4 | todo | |
| D2 | todo | |
