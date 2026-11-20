# Foreman refactor plan

Branch: `review/deep-refactor`. Tickets run in order. Each is independently shippable and has a regression test. Bug numbers refer to `BUGS.md`; the detailed evidence and fix sketches are in `docs/review/bugs/`.

## How to work a ticket (for whoever picks this up)

1. Read the ticket and the bug report sections it cites.
2. Implement it with a regression test that fails before the fix.
3. Run `cd gui && node --test` and the relevant smoke cases by substring (`bash test/smoke.sh "<substring>"`, `bash test/smoke-json.sh "<substring>"`). A full run takes 15–25 minutes; do one at the end of each group.
4. "Green" means no new failures against the baseline in `MAP.md` (66 + 35 pre-existing, platform-related failures on Windows).
5. Commit one ticket per commit. Update the Status column here in the same commit.

Stop and ask the owner before any change to the public CLI interface, the config format, or anything that deletes data.

## Status

| Ticket | Title | Status |
|--------|-------|--------|
| T01 | Validate numeric knobs; fail safe on a crashed loop | done |
| T02 | Never reset the sandbox over uncollected commits | done |
| T03 | One liveness check; refuse a second run | done |
| T04 | Record: verdict first, guarded appends, strict payload | done |
| T05 | Classify failures from structured fields, not prose | done |
| T06 | Stall-path checkpoint honours limit and pause | done (limit half untested: needs a fake.sh checkpoint behaviour) |
| T07 | Resolve batch paths before `cd`; root batch discovery | done |
| T08 | Doctor reads confs the way config does | done |
| T09 | Finished batches keep a readable order | done |
| T10 | Log and terminal hygiene | done |
| T11 | GUI main-process fixes | done |
| T12 | GUI conf readers agree with the shell | done |
| T13 | Signals: keep the trap through the footer; forward TERM | done (verify by hand: native claude.exe on Windows may ignore TERM; macOS bash 3.2 untested) |
| R1 | Loop: one path for terminal states | done |
| R2 | Move status and dry-run out of the loop file | status done; dry-run not moved (it runs after the preflight and gate, needs a second source point) |
| R3 | Shared node module for cross-boundary formats | todo |
| R4 | Side-effect-free config reading | todo |
| R5 | Control directory gets an owner | todo |

## Bug fixes

### T01 — Validate numeric knobs; fail safe on a crashed loop (B3, B7)
- **Scope:** integer knobs must match `^(0|[1-9][0-9]*)$` (reject `08` with the existing error style). `FOREMAN_MAX_COST_USD` must be empty or match `^[0-9]+(\.[0-9]+)?$`. Initialise `FINAL_STATUS` so that leaving the loop without an explicit decision is a failure (needs-human), never done; set done only where the loop decides the batch is finished.
- **Files:** `lib/foreman-config.sh`, `lib/foreman-loop.sh`, `test/smoke.sh`.
- **Accept:** `FOREMAN_MAX_MINUTES=08`, `FOREMAN_MAX_COST_USD='$25'`, `abc`, `-5` each fail preflight with exit 1 and a message naming the knob; no batch is renamed. Valid `0.015` still pauses. Existing done-path cases unchanged.
- **Blocked by:** none.

### T02 — Never reset the sandbox over uncollected commits (B1)
- **Scope:** (1) in `exec_sync_down` (`sandbox.sh` ~L64), before `reset --hard`, refuse if the sandbox HEAD is not an ancestor of the target, with a message that says where the commits are and how to recover or deliberately discard; the loop exits 20. (2) Refspec `+HEAD:refs/foreman/incoming`; the ff-failure note names that ref. (3) In the loop, test `sync_failed` before the limit, Ctrl-C and auth branches so the recovery note is printed. Do not change the rebase strategy (V1 fix 3) in this ticket.
- **Files:** `lib/exec/sandbox.sh`, `lib/exec/_sbx.sh` if needed, `lib/foreman-loop.sh`, `test/smoke.sh` (extend the `sbxrescue` stub with `STUB_CP_FAIL`, `STUB_LIMIT`, `STUB_HOST_COMMIT` as sketched in `bugs/V1-stranded.md`).
- **Accept:** the three V1 repros become tests: after each, a plain rerun refuses and the commit is still reachable in the sandbox; a stale `refs/foreman/incoming` no longer breaks the next fetch.
- **Blocked by:** none.

### T03 — One liveness check; refuse a second run (B2, B8)
- **Scope:** add `run_pid_alive MSYS WIN` (kill -0 and, where `/proc/<pid>/winpid` exists, it must equal the recorded Windows pid). Use it in the loop's start guard and in `foreman-control.sh`. The start guard refuses with "a run is already in flight" and exit 1 when alive. Emit a `runalive` fact from `status_json_facts`; `foreman-json.cjs` prefers it over `process.kill`.
- **Files:** `lib/foreman-loop.sh`, `lib/foreman-control.sh`, `lib/foreman-keys.sh` if it shares the check, `lib/foreman-json.cjs`, `test/smoke.sh`, `test/smoke-json.sh`.
- **Accept:** a second `foreman run` on a live batch exits 1 without touching the tree; a stale pid file (dead pid, or live unrelated pid with a different winpid) does not block a start, is not reported in flight by `status --json`, and is not signalled by `stop --now`.
- **Note:** user-visible behaviour change (a second run now refuses). Treated as a bug fix; no flag or format changes. The case with no `.foreman-run/` gitignore stays open (see Decisions).
- **Blocked by:** none.

### T04 — Record: verdict first, guarded appends, strict payload (B5, B9, B22, B29)
- **Scope:** `foreman-record.cjs` writes the verdict before the appends and wraps the appends in try/catch (warn on stderr, exit 0 with verdict intact); prepend `\n` when the JSONL does not end in one; the lone-JSON fallback requires `type === 'result'`. `foreman-stream.cjs` keeps only non-JSON lines in the tail it flushes when no `result` arrives, and never evicts the `ERROR:` banner. `foreman-report.cjs` skips non-object lines.
- **Files:** `lib/foreman-record.cjs`, `lib/foreman-stream.cjs`, `lib/foreman-report.cjs`, new `test/node/*.test.cjs` (node:test, builtins only) wired into the end of `test/smoke-json.sh` next to the GUI tests.
- **Accept:** the repros in `bugs/05-node.md` #1, #4, #5, #6, #8 become tests.
- **Blocked by:** none.

### T05 — Classify failures from structured fields, not prose (B6)
- **Scope:** `permission_denied` on a turn without an error comes only from the structured `permission_denials`; limit/billing words are matched only in error fields (`is_error` result text, API error subtype, stderr tail), not in the assistant's prose of a turn that ended for another stated reason (`error_max_turns` etc.).
- **Files:** `lib/foreman-record.cjs`, `test/node/record.test.cjs`.
- **Accept:** repros in `bugs/02-loop-state.md` #2, #3 and `bugs/05-node.md` #3 become tests; every existing limit/auth/permission smoke case still passes.
- **Blocked by:** T04 (test harness).

### T06 — Stall-path checkpoint honours limit and pause (B10, B30)
- **Scope:** extract the review path's post-checkpoint handling (limit hit, pause requested) into one function and call it from both the review path and the stall path; make the review-path salvage call `continuation_cap_reached` like the mid-run copy.
- **Files:** `lib/foreman-loop.sh`, `lib/exec/fake.sh` (a `limit` checkpoint behaviour if absent), `test/smoke.sh`.
- **Accept:** `FOREMAN_FAKE_BEHAVIOUR=dirty` with a checkpoint that hits the limit or a stop file exits 10, not 20.
- **Blocked by:** none.

### T07 — Resolve batch paths before `cd`; root batch discovery (B12, B14)
- **Scope:** absolutise `FOREMAN_BATCH` against the caller's directory before `cd "$REPO_ROOT"`; `foreman_find_batches` returns `.` for a root-level conf.
- **Files:** `lib/foreman-config.sh`, `lib/foreman-repo.sh`, `test/smoke.sh`.
- **Accept:** from `repo/sub`, `foreman status b2` finds `sub/b2`; `foreman status .` inside a batch selects that batch; `foreman status` with a root batch works.
- **Blocked by:** none.

### T08 — Doctor reads confs the way config does (B13)
- **Scope:** doctor's text reader strips `export` and trailing comments, takes the last assignment, honours env overrides, and uses `foreman_find_batches` (which prunes `DONE_`). No sourcing of `foreman-config.sh` (that is R4).
- **Files:** `lib/foreman-doctor.sh`, `test/smoke.sh`.
- **Accept:** repros 4a, 4b, 4c, 4e in `bugs/04-config-cli.md` become tests.
- **Blocked by:** T07.

### T09 — Finished batches keep a readable order (B11)
- **Scope:** the ticket resolver also tries an entry with the batch's original prefix swapped for the current batch directory. No rewrite of `order.md`.
- **Files:** `lib/foreman-tickets.sh`, `test/smoke.sh`, `test/smoke-json.sh`.
- **Accept:** `foreman status DONE_batch` and `status --json --all` show counts for a finished batch with repo-relative entries.
- **Blocked by:** none.

### T10 — Log and terminal hygiene (B15, B23)
- **Scope:** indent reply lines when appending to `foreman-runs.log` so they cannot match the `# run … started` / `# complete` markers; strip C0/C1 control characters from tool descriptions in `foreman-stream.cjs` after JSON parsing.
- **Files:** `lib/foreman-record.cjs`, `lib/foreman-stream.cjs`, `test/node/*.test.cjs`; check `lib/foreman-json.cjs` and goldens for readers of the reply block.
- **Accept:** repros `bugs/05-node.md` #2 and #7 become tests.
- **Blocked by:** T04.

### T11 — GUI main-process fixes (B16, B17, B18, B25, B26)
- **Scope:** capture `runner` and the batch before `start()` and guard the exit callback; give `execFile` a timeout and kill signal; spawn the run with the full `process.env` (keep the whitelist for read-only calls); `shell.openPath` goes through `resolveInside` and an extension allow-list; `h()` applies `style` through `element.style.cssText`.
- **Files:** `gui/main.cjs`, `gui/runner.cjs`, `gui/foreman.cjs`, `gui/app.js`, `gui/test/*`.
- **Accept:** `gui/test` covers each; `node --test` passes.
- **Blocked by:** none.

### T12 — GUI conf readers agree with the shell (B19)
- **Scope:** one conf reader in the GUI: last match wins, `FOREMAN_` over `RALPH_`, `ralph.conf` fallback. Replace the four regex readers with it.
- **Files:** `gui/live.cjs`, `gui/conditions.cjs`, `gui/model.js`, `gui/overview.cjs`, `gui/test/*`.
- **Accept:** repro 5 in `bugs/06-gui.md` becomes a test.
- **Blocked by:** none (superseded by R4 if the GUI later reads effective settings from `--json`).

### T13 — Signals: keep the trap through the footer; forward TERM (B20, B24)
- **Scope:** keep the INT/TERM trap until `exit` so the footer and batch rename finish; on TERM, signal the agent pipeline's children instead of only setting a flag. Orphan cleanup after `kill -9` is out of scope (needs R5).
- **Files:** `lib/foreman-loop.sh`, `test/smoke.sh`.
- **Accept:** `kill -TERM` of a loop with a 15 s fake turn exits within ~2 s with exit 10 and a complete log footer.
- **Blocked by:** T03. Higher risk; verify on Windows by hand.

## Refactors (from `ARCHITECTURE.md`)

### R1 — Loop: one path for terminal states
- **Scope:** `finish_run STATUS REASON` plus small functions for the stranded, discarded and limit-pause blocks; replace each duplicated site. No behaviour change.
- **Files:** `lib/foreman-loop.sh`. **Accept:** full smoke run equals the post-T13 baseline. **Blocked by:** T02, T06, T13.

### R2 — Move status and dry-run out of the loop file
- **Scope:** pure move of L641–1084 (as of `6d01ff8`) into `lib/foreman-status.sh`. **Files:** `lib/foreman-loop.sh`, new file, `bin/foreman` only if dispatch must change (it should not). **Accept:** goldens byte-identical. **Blocked by:** R1.

### R3 — Shared node module for cross-boundary formats
- **Scope:** `lib/foreman-facts.cjs` (`parseFacts`, outcome/progressed/stalled rules, exit-code words, EPIPE-safe write); report and convert become functions with a `main`; drop the `require.main` hack. **Files:** `lib/*.cjs`, `test/node/`. **Accept:** goldens byte-identical. **Blocked by:** T04, T05.

### R4 — Side-effect-free config reading
- **Scope:** split `foreman-config.sh` into resolve-and-validate (no `cd`, no legacy migration) and prepare-repo; doctor and `--json` use the real reader; `--json` exposes effective settings so the GUI drops its reader. **Blocked by:** T07, T08, T12. Touches every entry point.

### R5 — Control directory gets an owner
- **Scope:** one bash file and one node file define the control-dir file names and read/write them, with the liveness rule from T03. **Blocked by:** T03, R1.

## Decisions for the owner (not started)

1. **B4, `foreman convert` and untracked files.** Options: skip untracked files, or refuse when any exist, or write backups. All change what the command touches.
2. **Agent hang timeout.** Needs a new config knob and a default.
3. **`foreman order` through the executor** (today it calls `claude` on the host, ignoring sandbox and permission settings).
4. **Control dir when `.foreman-run/` is not gitignored.** Today a private temp dir, which means no run lock, no `stop`, no GUI live view. Options: refuse, warn, or keep it under `.git/`.
5. **B28:** allow `dry-run` on a dirty tree; reject a second mode flag (CLI behaviour).
6. **B21:** should an empty env var override a conf value? Array-valued knobs from env.
7. **B31:** `init --force` backing up what it overwrites.

## Where this stopped (2026-11-16)

Done and committed on `review/deep-refactor`: T01, T02, T03, T04, T06, T07, T08, T09, T11, T12, T13, R1, and the status half of R2.

**In the working tree, uncommitted: T05 and T10.** Files: `lib/foreman-record.cjs`, `lib/foreman-stream.cjs`, `test/node/record.test.cjs`, `test/node/hygiene.test.cjs`. Both are implemented and their node tests pass (23/23). T05 cannot be committed until `lib/exec/fake.sh`'s `permission-denied` behaviour (about line 375) emits a structured `permission_denials` array in its payload; without it the smoke case "a denied tool call" fails 5 of 7. The owner has to make or allow that edit (the session's permission system refused it). Then: run `bash test/smoke.sh "a denied tool call"`, commit T05 (the classification hunks of `record.cjs`, `record.test.cjs`, `fake.sh`), then T10 (the `indent()` hunks of `record.cjs`, `stream.cjs`, `hygiene.test.cjs`). A T05-only snapshot of `record.cjs` was left in the session scratchpad and may be gone; `git add -p` does the same split.

Left to do:
- **T06 follow-up:** a fake checkpoint behaviour that hits the limit, to test the limit half of `checkpoint_paused` (needs `fake.sh`).
- **R2 remainder:** move the dry-run block (needs a second source point after the preflight and the human gate).
- **R3** (blocked by T05), **R4**, **R5**: not started.
- **A full-suite run of the final tip.** `FULL-RUN.md` compares the baseline with `5f5c8f7` (everything up to T09): no real regressions. R1, R2 and two test fixes landed after it and were checked only by their related cases.
- **By hand:** T13 on Windows with the real `claude.exe` (a native process may ignore TERM) and on macOS bash 3.2; T11's `cssText` under the real CSP in Electron.

Known flaky under 8-way load (pass alone): smoke.sh "foreman order draws the stake line", "SIGTERM during a turn ends the turn at once", "a second run on a batch with a run in flight is refused".
