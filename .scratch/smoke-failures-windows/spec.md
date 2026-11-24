# Smoke suite failures on Windows (Git Bash): sweep and triage

**Status:** needs-triage
**Found:** 2026-11-24, on branch `review/deep-refactor`, at commit `abfb292`
**Machine:** Windows 11, Git Bash (MSYS), Node on PATH, the Claude desktop app installed

## The problem

On this machine, `bash test/smoke.sh` results:

- **At `abfb292`:** 2,904 passed and 85 failed, in 28m 14s.
- **Baseline, the commit before (`fddeafc`):** 2,893 passed and 82 failed, from a temporary worktree at another path.

The commit between them (`abfb292`, init's NEXT step 1) changed none of these failures. Each one is either already broken or depends on this environment. Nobody has confirmed a root cause yet: everything below **Likely causes** is a hypothesis from reading the failure output. Your job is to confirm or kill each one.

`node --test "test/node/*.test.cjs"` is clean: 62 passed.

## Evidence (in `evidence/`)

- `smoke-full-run.log`: the full log of the run at `abfb292`, with each failure's expected and actual output.
- `failures-after.txt`: the 85 failures, one per line as `case | FAIL assertion`.
- `failures-baseline.txt`: the 82 baseline failures, same format.

To run one case: `bash test/smoke.sh "<exact case name>"`. A case takes 5 to 120 seconds. A full run takes about 28 minutes, and much longer if another suite runs at the same time. Never run two full suites at once: these numbers came from three suites sharing the CPU, which probably caused the timing failures in cluster F.

## Failures by case (85, at `abfb292`)

| # | Case | Fails |
|---|---|---|
| 1 | foreman report is today's text, byte for byte, wherever the show is not drawn | 24 |
| 2 | foreman convert is today's text, byte for byte, wherever the show is not drawn | 16 |
| 3 | foreman doctor, piped, is the box on a ready repo and on one that is not, with the exit code it always had | 10 |
| 4 | foreman doctor forced to show draws the same box in colour, and lists the checks when it cannot draw | 6 |
| 5 | foreman-draw version is the design's mark beside the build, and tilde shortens only what is under home | 4 |
| 6 | foreman report is the text when the picture cannot be made | 3 |
| 7 | plain foreman init is byte for byte what it was | 2 |
| 8 | foreman-keys.sh --text draws the design's foot when the loop left one: … | 2 |
| 9 | foreman-draw init writes the design's header and files, and its other pieces say what they are given | 2 |
| 10 | foreman order's result facts say when the call failed, when the login expired, and when there is no agent | 2 |
| 11 | foreman convert is the text when the picture cannot be made | 2 |
| 12 | foreman convert draws the repainted sign and what changed when the show is forced | 2 |
| 13 | turn timeout: what a native Windows agent started is ended with it, not left running (Windows only) | 1 |
| 14 | foreman-draw reads the palette from foreman-ui.sh and keeps no copy | 1 |
| 15 | foreman run is the text it always was, and writes the logs it always wrote, wherever the show is not wanted | 1 |
| 16 | foreman order piped is the text it always was, down to the byte | 1 |
| 17 | foreman init at a terminal without --no-order drops the ordering line, and says so when ordering failed | 1 |
| 18 | foreman init at a terminal still shows the agent's command pass, and falls back to today's text if it cannot draw | 1 |
| 19 | foreman convert with nothing to convert draws the short form | 1 |
| 20 | foreman convert --dry-run draws the unpainted sign with would throughout, and changes nothing | 1 |
| 21 | doctor asks the adapter what this repo needs | 1 |
| 22 | SIGTERM during a turn ends the turn at once and pauses the run, footer and all | 1 |

## Likely causes (hypotheses, to confirm)

### A. MSYS paths compared with Windows paths (likely the biggest cluster)
Node prints Windows paths, while the shell and the golden files use MSYS paths. Seen directly:

- **Case 14:** expected `no _UI_PALETTE in /c/Projects/foreman/README.md`, got `… C:/Projects/foreman/README.md`.
- **Case 5:** expected `/opt/foreman`, got `C:/Program Files/Git/opt/foreman`, because MSYS rewrites POSIX-looking arguments passed to native `node.exe`. A home of `/` gave `~/opt/foreman`.

Probably also cases 1, 2, 6, 11, 12, 19 and 20. Their goldens substitute `$WORK` (a `/tmp/...` path) into the expected text (`report_golden`, `convert_golden` in `test/smoke.sh`), and the `node`-written output likely holds the Windows form. **Check:** diff `want` against `got` for one report view. The test currently only runs `cmp -s`, so save both files to see the difference.
**Decide:** should the product normalise the path (it's what the user sees on Windows), or should the test? Fixing only the tests hides a real Windows wart.

### B. Init now updates `.gitignore`, and the init goldens predate that
**Cases 7, 17, 18:** the actual output has an extra line, `updated  .gitignore (+ **/.foreman-run/, so the app can steer a run)`, or `+ .gitignore …` in the drawn output. Everything else matches byte for byte, which I checked for case 18. Init adds that line when it detects the Claude desktop app. **Decide:** should the test environment hide the desktop app, or should the goldens and assertions accept the line? These failures did *not* happen in the baseline worktree, so check whether the detection depends on the checkout's path.

### C. `wc -m` counts bytes, not characters (locale)
**Case 9:** `the rule is 96 wide` got 288, and `no wider than the terminal` got 240 instead of 80, exactly 3× for a 3-byte `▔`. The shell's locale is probably `C`/POSIX. **Check:** `locale` in the suite's environment. **Fix:** set a UTF-8 `LC_ALL` in the suite, or count with node. Also look for other `wc -m` uses that would pass for the wrong reason.

### D. Tests that remove a tool from PATH get 127 (command not found)
- **Case 4:** `no node: exit 1` got `127`.
- **Case 10:** `no agent is not a failure` got `127`.
- **Case 21:** `a fake batch needs no runner on PATH` got `1`.

The PATH these tests build probably drops something foreman itself needs on Windows, such as `bash`, `env` or coreutils, or a Windows-only lookup still finds the tool. **Check:** print the PATH each test builds and which command returns 127.

### E. `foreman doctor` on a "ready" repo isn't ready here (case 3)
It exits 1 and offers `foreman doctor --fix`. The box has a 57-column line among 80-column ones, and `--fix` doesn't write the expected `.gitignore (+4 pattern(s))`. These failures are only in the run at `abfb292`, not the baseline, so look at what differs between this checkout and a worktree path: the desktop app check (as in B), `.gitignore` content, or a stale installed skill copy. **Check:** run the doctor case alone and read the box.

### F. Timing under load (probably noise)
- **Case 22:** `TERM ended the run in 22 s, not at once`. The baseline got 20 s, so it fails in both.
- **Case 13:** `the turn was ended at its timeout (the run took 65 s of the hang's 735)`.
- **Case 8:** the live ticker shows `01:20` where the test wants `01:1x`.

All three ran while three suites shared the CPU. **Check:** rerun each one alone. If one still fails, it's a real bug. Case 22 looks real, since it fails in both runs.

### G. Not yet explained
- **Case 15:** `foreman-runs.log is the same`. The log text is long; diff it.
- **Case 16:** `foreman order piped`, `the header is there: expected to find '▄█▄'`.

## Baseline differences worth noting

These failed in the baseline but not at `abfb292`. They're probably related to the worktree's path or missing files, since the baseline worktree lacked the untracked `.scratch/DONE_terminal-design` design files:

- the `foreman-draw dryrun`, `next`, `next-count`, `order-head`, `status` and `version` design cases (colours and cells against the `.ans` designs);
- `foreman doctor warns when the installed skill copy is stale`.

These failed only at `abfb292`: cases 3 and 21 (doctor), 7, 17 and 18 (init), 15, 13, and one of case 8's two assertions.

**Important:** those design cases read their designs from **untracked** files. A clean clone or CI checkout would fail them. Decide whether those design files should be committed or the cases should skip without them.

## Suggested approach for the sweep

1. **Reproduce:** run each of the 22 cases alone, one at a time or a few in parallel, with no other suite running. Record which still fail. That alone should clear cluster F.
2. **One investigator per cluster (A to G), in parallel.** Each confirms or rejects its hypothesis with evidence (a `want`/`got` diff, `locale` output, the PATH in use) and proposes a fix. Each fix must be labelled either **product bug** (the user would see it on Windows) or **test-environment issue**.
3. **Fixers:** one per cluster, touching only their own files. Clusters A and B both touch goldens and `test/smoke.sh`, so do them one after the other or merge them carefully.
4. **Verify:** one full `bash test/smoke.sh` at the end, alone on the machine. Record it in the closing note as `Full smoke suite: N passed in Mm Ss`.

## Done when

- [ ] Every one of the 85 failures is explained with evidence, classified as product bug, test-environment issue, or flaky.
- [ ] Product bugs are fixed, or split into their own tickets under `.scratch/`.
- [ ] Test-environment issues are fixed so the suite passes on Windows Git Bash without weakening what it checks on Linux.
- [ ] The design cases' dependence on untracked files has a decision.
- [ ] A full smoke run, alone on the machine, shows 0 failures, or only failures that have their own tickets.
