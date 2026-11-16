# 05 - Tests map

Run on Windows 11 / Git Bash, node v24.19.0, 8 logical cores. Read-only; tree left clean (only `docs/review/` is new).

## 1. How each suite is run

| Suite | Command | Harness |
|---|---|---|
| E2E loop + CLI + draw | `bash test/smoke.sh [name-substring]` | hand-rolled bash (`assert_eq/contains/missing`, test/smoke.sh:149-157). 248 cases, ~2325 asserts |
| `--json`, install, control, stop | `bash test/smoke-json.sh [name-substring]` | same assert trio (smoke-json.sh:51-55), but serial. ~100 cases, ~650 asserts. Last case shells to `node --test` in gui/ (smoke-json.sh:2489) |
| GUI logic | `cd gui && node --test` (`npm test`) | `node:test` + `node:assert/strict`. 18 files in gui/test/, 463 tests. No Electron, no jsdom: a hand-written fake DOM (gui/test/app.test.cjs:13-30) driven through `vm` |
| Benchmark / demo | `bash test/bench.sh [status\|next\|dry-run] [N]`, `bash test/demo.sh [shows ...]` | not tests. bench asserts nothing; demo.sh is only referenced by one smoke case that checks it runs (smoke.sh:7989) |
| Helper | test/ans-cells.cjs | converts SGR text to `char/fg/bg` cells, used to compare renderer output with design `.ans` files |

- Runner design (smoke.sh:1-40, 200-300): the file is two programs. Run normally it scans itself for `if case_is "name"; then` lines (smoke.sh:186-215), builds a fixture template once, then launches one `bash smoke.sh` per case with `_SMOKE_CASE=<name>`, at most `FOREMAN_SMOKE_JOBS` (default = NUMBER_OF_PROCESSORS) at once. Each case has its own TMPDIR, buffer file and counts file. Output is replayed in case order. `FOREMAN_KEEP_FIXTURES=1` keeps the temp dir. A case that dies without finishing counts as a failure.
- Fixtures: test/fixture.sh. `build_fixture_template` makes a git repo with `batch/foreman.conf` (template conf + `FOREMAN_EXEC=fake`), and `copy_fixture` copies it and commits N todo tickets.
- Isolation guards: RALPH_* vars unset, `FOREMAN_CREDENTIALS_FILE` and `CLAUDE_CONFIG_DIR` pointed at nonexistent paths, COLORTERM/WT_SESSION/NO_COLOR unset (smoke.sh:~50-58, smoke-json.sh:30-38).
- No CI config in the repo (no .github/), so nothing runs these automatically.

## 2. The fake executor (lib/exec/fake.sh, 422 lines)

- Selected by `FOREMAN_EXEC=fake` (the fixture appends it to the conf). It implements the same adapter seam as local/sandbox (`exec_preflight`, `exec_prepare`, `exec_run`...), so the real loop, parser, classifier and git logic all run. Only the model is faked.
- Driven by env vars (header, fake.sh:1-95): `FOREMAN_FAKE_BEHAVIOUR` is a `:` list, one entry per call, last entry repeating. Behaviours: land, noop, dirty, commit-dirty, error, transient, limit, limit-dirty, interrupt-dirty, hang-dirty, stop-file-dirty, session-limit, stream, partial-turn, permission-denied, crash, context, context-json, send-back, auth, double-result. Other knobs: `_CHECKPOINT_BEHAVIOUR` (commit/fail/discard/reject/stop-file), `_KEYS` (simulated +/-/L presses), `_SLEEP`, `_STREAM_PAUSE`, `_PREPARE=fail`, `_PROMPT_LOG`, `_COST`, `_DROP_MARKER`, `_HANG`.
- The call counter lives in `$TMPDIR/foreman-fake-$$.calls` (fake.sh:~70), keyed on the loop PID, so each case needs its own TMPDIR (the runner gives it one).
- Real `claude` and `sbx` are replaced by per-case PATH stubs: a stub `sbx` that logs `create` (smoke.sh:905-948) or runs `exec` against a local clone (smoke.sh:950+), and a stub `claude` using `STUB_SCRIPT/STUB_OUT/STUB_EXIT` for order/commands cases (smoke.sh:~2766-3060).

## 3. Golden files (test/golden/)

- smoke-json.sh:161-260: plain `status`, `help`, `dry-run`, `doctor`, `doctor --fix`, `run` on fake (clean/dirty/partial, `.txt` and `.jsonl`) and install output are `cmp -s`-compared with captures. Retake with `FOREMAN_JSON_GOLDEN=write bash test/smoke-json.sh golden`. Paths are normalised to `@FOREMAN_HOME@`.
- smoke.sh:7220-7300 uses `report-runs.jsonl` and `report-{by-run,by-ticket,failures}.txt` (with an `@LOG@` placeholder); `convert-*.txt` for the convert cases; `init-plain`, `install-plain`.
- A repeated idiom is "piped output is byte for byte what it was" against the show-drawn variant: it guards that terminal drawing never leaks into pipes.
- Renderer (foreman-draw.cjs) is checked cell-for-cell against design `.ans` pictures via ans-cells.cjs. Design assets are referenced from `.scratch/`, not test/.

## 4. Results (this machine)

| Suite | Result | Time |
|---|---|---|
| `node --test` in gui/ | 463 tests, 462 pass, 0 fail, 1 skipped (symlink/junction case, ticket.test.cjs:75/87) | 3.5 s. No `npm install` needed: no test requires `electron`, and gui/node_modules is absent |
| `bash test/smoke.sh` (8 jobs) | **2535 passed, 66 failed**, in 15 of 248 cases | 16m30s (1004 s). Slowest case 188 s |
| `bash test/smoke-json.sh` | **684 passed, 35 failed**, in about 7 cases. gui sub-case passed | 26 min, run concurrently with smoke.sh, so inflated |

Failures, all on this Windows/Git Bash host (none looks like a loop-logic bug; I did not run them on a Linux host to prove it):
- Path-form mismatch (`/c/...` or `/tmp/...` vs `C:/...`): foreman-draw palette error text (smoke.sh case 157), version tilde-shortening got `C:/Program Files/Git/home/you2/.foreman` (case 177), install --gui `.lnk` target/args/workdir (smoke-json "install --gui: npm ci..."), `foreman gui` args (case "starts electron.exe...").
- `ps -o sid=` is unsupported by Git Bash's ps (`ps: unknown option -- o`, smoke-json.sh:2312/2352). Together with node failing `spawn C:/Projects/foreman/bin/foreman ENOENT` (node cannot exec a shebang script on Windows), it breaks the `foreman stop --now` case (about 20 asserts: "the agent is mid-turn", "Interrupt received", "PAUSED: interrupted (Ctrl-C)"). So the SIGINT/stop-now path is **not verified on Windows** here.
- "no node / no agent" cases get exit 127 where 1 or 0 is expected (smoke.sh case 130 and case 220: the PATH-stripping trick fails under Git Bash).
- `foreman report` / `convert` "today's text, byte for byte" cases (24 + 16 failed asserts) differ in a pipe, probably the same path-form cause. Not root-caused.
- `golden: run (dirty)` differs from run-fake-dirty.txt, and `status --json` plus one `jv` case hit `Invalid regular expression flags` (a Windows path in `eval`). Not root-caused.
- 16 asserts are skipped silently-ish: `script` (util-linux) is not installed, so every "on a real terminal" / pty case prints `(skipped: no script to give a terminal)` and counts as pass. The real-TTY drawing paths and Ctrl-C-on-doctor (smoke.sh:6915) are untested here.

## 5. Coverage map

Well covered (smoke.sh, via fake exec): iteration/cost/time budgets, ticket attempts and mis-sizing (:522-590, 1613-1690), transient vs crash vs context vs auth classification (:522-600, 1766), stall and checkpoint turn and wip salvage and stall marker and review turn (:606-740, 1257-1560), usage and session limit pause (:1881-1904), human/followup tickets and exit 30 (:2271-2700), DONE_ renames (:2078-2225), `order`/`commands` with a stub claude, `--live` stream parsing, +/-/L keys, doctor, init, install.sh, colour tier and every `foreman-draw` scene, credentials reader, permission-mode defaults.
Covered in smoke-json.sh: `--json` for status/dry-run/report/doctor, control dir and `.foreman-run/` lifecycle (:1772-1894), `keys` and `stop`, `stop --now` (:2041-2128, failing here), feed file, `foreman gui` launcher.
GUI (gui/test): pure-logic modules (model, watch, ticket, foreman, runner, runplan, runview, runend, states, conditions, bash, art, preview, live, overview, guard) and app.js against a fake DOM (152 tests).

Gaps:
- **Signals**: only SIGINT paths (interrupt-dirty, stop --now). No SIGTERM/SIGHUP test of the loop, and nothing for the SIGINT-ignored-by-`&` fallback beyond smoke-json.sh:2086. smoke.sh's own cleanup on INT/TERM is not tested.
- **Timeouts and stall detection by clock**: foreman has no per-turn wall-clock timeout (grep finds only `FOREMAN_COMMAND_TIMEOUT_MINUTES`, which is passed to the agent as `BASH_MAX_TIMEOUT_MS`). Tests only check the number is validated and passed through (smoke.sh:751-790). "Stall" is detected from git state, not time, so it is covered. A hung agent is covered only through `hang-dirty` plus `stop --now`.
- **Concurrent runs / locks**: no lock exists in the product. The only exclusion is the pid file in `.foreman-run/` (smoke-json.sh:1811-1850: a held directory is skipped and a stale one cleared). Two real simultaneous `foreman run`s on one batch, or on one sandbox, are not tested.
- **Config parse errors**: partial. Bad `FOREMAN_EXEC`, `FOREMAN_COLOR`, `FOREMAN_COMMAND_TIMEOUT_MINUTES` and `FOREMAN_SMOKE_JOBS` values are tested, and so is a conf the agent left unparseable (smoke.sh:2973). A syntactically broken foreman.conf at `run` time, a conf with CRLF, and bad budgets are not systematically tested. foreman-config.sh has 465 lines and no dedicated case.
- **Sandbox executor**: only against stubs. `_sbx_create`, dirty check, rescue sync and Docker token login are tested with a fake `sbx` (smoke.sh:905-1210). `sandbox.sh`, `sandbox-mount.sh` and `local.sh` have no real run, and neither do `sbx` exec/stop/cleanup or the `claude` argument assembly (apart from the BASH_MAX_TIMEOUT_MS check, :771).
- **Control channel**: well tested on the CLI side. Not tested: a real terminal key read (no `script`), the Windows signal story, and races between `keys` and the loop's iteration boundary.
- gui: `main.cjs` and `preload.cjs` (Electron main/IPC) have no direct tests. guard.test.cjs only greps the sources for forbidden patterns. There is no Electron smoke or screenshot test, and ticket 14 notes "screenshots need Windows + Electron".
- Untested-by-name modules: foreman-tickets.sh, foreman-human.sh, foreman-repo.sh, foreman-claude-reply.cjs, foreman-auth-patterns.cjs, foreman-strip-ansi.cjs. They are reached only through end-to-end cases, so a unit-level regression gives a vague failure.

## 6. Testability observations

- Slow: Git Bash fork cost dominates. A single `foreman status` takes tens of seconds (bench.sh header), a typical case 5-60 s, and the worst about 190 s. The full suite takes about 17 min on 8 cores, and serial would be about 2 h (summed case time is above 1 h).
- One case can be run alone: `bash test/smoke.sh "<substring of name>"` (spawns only matching cases), likewise `smoke-json.sh <substring>`. `node --test gui/test/x.test.cjs` for one gui file. Output is per case with elapsed seconds and a "Slowest cases" table.
- Adding a regression test is easy for loop behaviour: append an `if case_is "name"; then ... fi` block, `make_repo N`, set `FOREMAN_FAKE_BEHAVIOUR=a:b:c`, `run_foreman`, and assert on `$OUT`/`$ST`/git state. Names must be unique (checked, smoke.sh:214). The header says test/smoke.sh should not be edited by app tickets, so new `--json`/app cases go to smoke-json.sh.
- Hard: both files are huge (8010 and 2503 lines), cases are free-form blocks with no shared setup per area, assertions are string `contains` on human text (so wording changes break many tests), and golden files are byte-exact. Windows path normalisation is not centralised, which is why 50+ asserts fail on the intended platform.
- smoke.sh works in parallel only because a per-case TMPDIR keeps the fake adapter's PID-keyed counter and temp files apart. Cases that use fixed names under `$WORK` are safe only because `$WORK` is shared per run and names differ.
- Flaky patterns: fixed sleeps in pty cases (smoke.sh:4186, 6243, 6260, 6964-6965: `sleep 1; printf '\003'`), polling `seq 200 / sleep 0.1` for terminal output (:4205, deliberate against load), `sleep 1.5/0.6` stub scripts for the spinner (:6243-6260), and node-side `sleep(30..300)` in the live doctor case (:6685-6776). Cleanup retries `rm -rf` 6 times on Windows (smoke.sh:105-113). Running two suites at once (as I did) was not seen to cause timing failures, but I did not confirm that with a rerun.
- Gui tests are fast, deterministic and dependency-free (3.5 s). The only timing-sensitive file is watch.test.cjs (debounce 150 ms, with fake timers or real ones; not verified).
