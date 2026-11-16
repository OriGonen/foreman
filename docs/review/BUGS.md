# Foreman bugs: verified findings

Ranked by severity. **CONFIRMED** means reproduced (repro and evidence in the linked report). **PLAUSIBLE** means established by reading the code with high confidence but not run. Line numbers are as of commit `6d01ff8`. Raw reports: `bugs/01`–`06` (Sonnet hunts), `bugs/V1`, `bugs/V2` (Opus verification).

## Critical: lost work or a wrong "done"

| # | Status | Where | What happens | Report |
|---|--------|-------|--------------|--------|
| B1 | CONFIRMED | `lib/exec/sandbox.sh:64`, `:117-148`; `lib/foreman-loop.sh:1843`, `:1854-1891` | **Sandbox commits are destroyed by a rerun.** Nothing checks for uncollected commits before `exec_sync_down` runs `git reset --hard`. Three ways in: (a) collection fails on a turn that also hit the limit, Ctrl-C or auth, so the run exits 10 saying "nothing to restore"; (b) a host commit during a turn makes `merge --ff-only` fail (the commits do sit at `refs/foreman/incoming`, but the note never says so); (c) after (b) the stale ref makes every later fetch fail, and each rerun destroys the previous run's work. | V1 |
| B2 | CONFIRMED | `lib/foreman-loop.sh:1139-1153` | **No run lock.** A live pid only makes a second `foreman run` use a private control dir. Both loops then run the same ticket (double spend), one checkpoints the other's in-flight edits as a stall, and the first to finish renames the batch under the other. With no `.foreman-run/` gitignore there is no pid file at all. | 01 #1, 03 #1, V2 B |
| B3 | CONFIRMED | `lib/foreman-config.sh:451`; `lib/foreman-loop.sh:1327`, `:1703` | **`FOREMAN_MAX_MINUTES=08` marks an unfinished batch done.** `08` passes `^[0-9]+$`, then `$((…))` dies with "value too great for base", the loop aborts, and because `FINAL_STATUS` starts as done the run exits 0 and commits the batch as `DONE_` with tickets still todo. | 04 #1 |
| B4 | CONFIRMED | `lib/foreman-convert.cjs:146`, `:225` | **`foreman convert` rewrites untracked files in place with no backup**, replacing every bare "Ralph" (including people's names and email addresses), even in repos that never used the toolkit. The clean-tree guard ignores untracked files. | 03 #5 |

## High: wrong outcome for a run

| # | Status | Where | What happens | Report |
|---|--------|-------|--------------|--------|
| B5 | CONFIRMED | `lib/foreman-stream.cjs:271-278`, `:333-338`; `lib/foreman-record.cjs:150-168` | A killed agent with no `result` has its last 40 lines of raw events flushed into the payload and scanned as failure text. An edit to `src/billing.ts` yields `limit_hit=1` and a false "usage limit" pause; tool bodies also land in the log. | 05 #1 |
| B6 | CONFIRMED (verdict); ladder effect PLAUSIBLE | `lib/foreman-record.cjs:150-168`, `:245-248` | Failure classes come from substrings in the agent's prose. "permission denied" in a healthy, committed turn stops the run with exit 20; "billing" or "rate limit" in a failed turn's reply pauses as a usage limit. | 02 #2 #3, 05 #3 |
| B7 | CONFIRMED | `lib/foreman-config.sh:382`, `:451`; `lib/foreman-loop.sh:1698` | `FOREMAN_MAX_COST_USD` is never validated. `$25`, `abc`, `-5` silently mean unlimited. | 04 #2, 02 #5 |
| B8 | CONFIRMED | `lib/foreman-json.cjs:307-310`; `lib/foreman-control.sh:94-99`; `lib/foreman-loop.sh:1143` | Liveness is checked two ways (node tests the Windows pid, bash the MSYS pid). With a stale pid file, `status --json` says in flight while `stop` says no run, which deadlocks the GUI; and `stop --now` will signal, then force-kill, whatever unrelated process holds the pid. | 06 #1, 01 #2, V2 A |
| B9 | CONFIRMED | `lib/foreman-record.cjs:325`, `:371`, `:404` | The verdict is written last, after unguarded appends. If an append throws, the verdict is empty: a real limit is missed and cost reads 0. | 05 #4, 02 #6 |
| B10 | CONFIRMED | `lib/foreman-loop.sh:1982-1997` vs `:1660-1675` | A checkpoint turn in the stall path ignores a limit hit or a pause request and exits 20 where the review path exits 10 (drifted duplicate). | 02 #4 |

## Medium

| # | Status | Where | What happens | Report |
|---|--------|-------|--------------|--------|
| B11 | CONFIRMED | `lib/foreman-loop.sh:482-491`; `lib/foreman-tickets.sh:123-172` | Renaming a batch to `DONE_` breaks its repo-relative `order.md` entries; `status` and `status --json --all` report missing tickets for every finished batch. | 03 #3 |
| B12 | CONFIRMED | `lib/foreman-config.sh:61`, `:93` | `cd` to the repo root happens before the batch path is resolved, so caller-relative paths fail and `foreman status .` inside a batch selects the repo root. | 04 #3, 03 #6 |
| B13 | CONFIRMED (multi-line array case PLAUSIBLE) | `lib/foreman-doctor.sh:201-227`, `:453` | Doctor's text reader disagrees with the real config: trailing comments, `export`, env overrides and `DONE_` batches all produce wrong advice. | 04 #4 |
| B14 | CONFIRMED | `lib/foreman-repo.sh:145` | A batch at the repo root is discovered as the string `foreman.conf`; `foreman status` with no argument fails. | 04 #5 |
| B15 | CONFIRMED | `lib/foreman-record.cjs:363`; `lib/foreman-json.cjs:238` | The agent's reply is appended raw to the log that `status --json` parses, so reply text can forge run start/complete markers. | 05 #2 |
| B16 | CONFIRMED | `gui/main.cjs:264-266` | The run-exit callback reads the global `ctx`; after switching repo it throws in the main process or reads the wrong repo. | 06 #2 |
| B17 | CONFIRMED for `RALPH_*`; rest PLAUSIBLE | `gui/foreman.cjs:36-55`; `gui/runner.cjs:35` | GUI-started runs get the read-only env whitelist: legacy caps vanish, and `ANTHROPIC_*`, proxy, SSH agent and `GH_TOKEN` are dropped. | 06 #3 |
| B18 | PLAUSIBLE | `gui/foreman.cjs:105` | `execFile` has no timeout; one hung bash freezes the overview and the watcher for good. | 06 #4 |
| B19 | CONFIRMED | `gui/live.cjs:58` and other GUI conf readers | GUI readers take the first match and ignore the legacy prefix and `ralph.conf`; the shell takes the last. Caps and exec mode shown can be wrong. | 06 #5 |
| B20 | CONFIRMED | `lib/foreman-loop.sh:1266`, `:1787-1789` | SIGTERM only sets a flag and is not forwarded (loop exits when the agent finishes); `kill -9` of the loop orphans the agent, which keeps editing. | 01 #4 #5 |
| B21 | CONFIRMED | `lib/foreman-config.sh:115-118`, `:146-148` | The env snapshot restores only element 0 of an array (malformed `claude` args) and an empty env var blanks a conf value. | 04 #6 |
| B22 | CONFIRMED | `lib/foreman-record.cjs:325`; `lib/foreman-report.cjs:244`, `:279` | A torn JSONL line swallows the next record; a `null` line crashes `report`. | 05 #5 #6 |
| B23 | CONFIRMED | `lib/foreman-stream.cjs:94-100` | ANSI stripping runs before JSON parsing, so escape sequences in tool arguments reach the terminal, the activity file and the feed. | 05 #7 |

## Low

| # | Status | Where | What happens |
|---|--------|-------|--------------|
| B24 | PLAUSIBLE | `lib/foreman-loop.sh:2094` | `trap - INT TERM` before the footer: a stop there can skip the log append or leave a staged, uncommitted batch rename. |
| B25 | PLAUSIBLE | `gui/app.js:19` (~18 call sites) | Inline `style` attributes are blocked by the CSP; spacing is silently dropped. |
| B26 | PLAUSIBLE | `gui/main.cjs:331` | `shell.openPath` uses a lexical path check only: symlink escape, and a repo-controlled path can launch an executable. |
| B27 | PLAUSIBLE | `gui/main.cjs` setup | Unserialised `setup()` can leak a watcher or reinstate the old repo. |
| B28 | CONFIRMED | `lib/foreman-loop.sh:909-917`; `bin/foreman:146-147` | `dry-run` is refused on a dirty tree; a second mode flag silently loses (`status --dry-run` prints status). |
| B29 | CONFIRMED | `lib/foreman-stream.cjs:271-327` | One JSON line over 8 KB evicts the whole tail including the error banner; a single huge line is rescanned per chunk (40 MB took 9 s). |
| B30 | PLAUSIBLE | `lib/foreman-loop.sh:1621` vs `:1959` | Review-turn salvage skips the continuation cap check that the mid-run copy makes. |
| B31 | PLAUSIBLE | `lib/foreman-init.sh:80`, `:217`, `:235`; `lib/foreman-order.sh:208`, `:264` | `init --force` overwrites `progress.txt` and `foreman.conf` with no backup; `order.md` is written non-atomically; the order spinner never exits if its parent is killed. |

## Not a bug, but missing

There is no timeout on the agent, `sbx exec` or `sbx cp` anywhere. A hung call blocks the run until someone stops it. On Windows `stop --now` cannot deliver Ctrl-C to the native agent, so it is always a grace period followed by a forced kill.

## Checked and sound

Prompt substitution (ticket text is attached, never substituted); CRLF in conf, order and tickets; credentials reader; legacy `RALPH_` precedence; ticket names with spaces or brackets; multi-byte and split-line stream input; multiple `result` objects; `report | head`; counter resets and retry bounds; the watcher's debounce.
