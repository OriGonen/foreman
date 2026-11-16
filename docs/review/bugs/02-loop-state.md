# Bug hunt 02: the loop's state machine, error handling and retries

Scope: `lib/foreman-loop.sh` L1508-2089 (plus the start-of-run review, budgets, `run_checkpoint_turn`),
`lib/foreman-record.cjs`, verdict reading, the stall marker. Repros were run in a scratch copy of
`bin/ lib/` under `/tmp/fm-repro` (FOREMAN_EXEC=fake; the copy's `fake.sh` got two test-only hooks:
a checkpoint behaviour `limit`, and a `.git/strand` flag that makes `exec_collect` return 1). No
tracked file was modified.

## 1. A limit / Ctrl-C / auth pause shadows `sync_failed`: stranded sandbox work is reported as "nothing to restore", and a rerun resets over it
- Where: `lib/foreman-loop.sh:1854` (limit), `:1860` (PAUSE_REQUESTED), `:1869` (auth) all come before `:1891` (`sync_failed`); footer `:2150-2160`.
- What: the comment at L1888 says stranded work must never be synced over, yet the stranded branch is 4th in the ladder. If the turn committed in the sandbox clone, `exec_collect` could not bring it back, and the same turn hit the usage limit (or the user pressed Ctrl-C / `stop --now`, or auth died), the run pauses with exit 10 and never calls `exec_recovery_note`. The footer then runs `exec_tree_dirty` (clean: the work is committed in the clone) and prints "nothing to restore". The marker is also dropped (`:1843` needs `sync_failed -eq 0`). On the default `sandbox` adapter the rerun's `exec_sync_down` does `git reset --hard BASE` (`lib/exec/sandbox.sh:64`), and the commits exist nowhere else.
- Evidence (scratch fake, exec_collect forced to fail): `FOREMAN_FAKE_BEHAVIOUR=limit foreman run batch --unlimited` printed `PAUSED: usage limit reached ...`, `Resume:   foreman run batch --unlimited`, `(nothing to restore - the tickets' Status lines are the resume point)`, exit=10, no recovery note. Same with `interrupt-dirty` (PAUSED: interrupted). The control (`land` + forced strand) exits 20 as designed.
- Severity: high (data loss on the default adapter). Confidence: confirmed-by-repro for ordering and message; the reset-over-commits step is from reading sandbox.sh.
- Fix: test `sync_failed` first (before limit/pause/auth) and print the recovery note; keep the pause exit code if wanted, but never print "nothing to restore".

## 2. `permission_denied` is a substring match on the whole reply and sits above progressed/dirty/landed
- Where: `lib/foreman-record.cjs:245-248`; ladder `lib/foreman-loop.sh:1904`.
- What: the scan is skipped only when the turn "landed cleanly" (flipped AND clean). Any other successful turn (a progressed checkpoint, a stall, a flipped-but-dirty turn) has its reply scanned for the bare substrings `requires approval` / `permission denied`. An agent that mentions an EACCES, a permissions test or an approval workflow flips the verdict, and the ladder stops with exit 20 "stopped by a permission denial" plus advice to edit FOREMAN_CLAUDE_ARGS, on a turn that committed fine (progress not continued, no retry).
- Evidence: a payload with `"is_error":false,"result":"... permission denied on the cache dir; chmod added. Handing off."` piped to `foreman-record.cjs --exit-status 0 --tree-dirty 0 --status-flipped 0 --base-ref a --head-ref b` gives `permission_denied=1`. Also with `--tree-dirty 1 --status-flipped 1` ("a test asserts permission denied for guests") gives `permission_denied=1`.
- Severity: med-high. Confidence: confirmed for the verdict; the ladder consequence is by reading (fake.sh cannot emit custom reply text).
- Fix: scan only when something is wrong (dirty and unflipped, or is_error), or use the CLI's structured denial field rather than prose.

## 3. `limit_hit` matches the bare word `billing` / `rate limit` in a failed turn's own text: wrong pause (exit 10) instead of retry or a real stop
- Where: `lib/foreman-record.cjs:153-168`, haystack is the whole payload on any failure (`:150-151`); ladder `foreman-loop.sh:1854`.
- What: on any failed turn (exit != 0 or is_error) the lowercased payload, agent prose included, is searched for `billing`, `rate limit`, `quota exceeded`, and so on. A ticket in a billing or rate-limiting codebase that fails for any other reason is reported as a usage limit. The limit check is first in the ladder, so the run pauses ("usage limit reached", exit 10) and a rerun repeats it, instead of retrying or naming the real cause. If the tree is dirty, the marker is kept too.
- Evidence: `{"type":"result","subtype":"error_max_turns","is_error":true,"result":"Ran out of turns while refactoring the billing module."}` with `--exit-status 1` gives `limit_hit=1`; `...the rate limit middleware test crashed` gives `limit_hit=1`.
- Severity: med. Confidence: confirmed (verdict).
- Fix: restrict to structured fields or the CLI's own limit sentence (429 / `rate_limit_error` / usage-limit wording); drop bare `billing`.

## 4. A checkpoint turn in the stall path ignores a usage limit / Ctrl-C / stop that hit it: exit 20 instead of a pause
- Where: `lib/foreman-loop.sh:1982-1997` versus the review path's `:1660-1675` (drifted copy).
- What: when the stall's checkpoint ends `failed`, the stall branch writes the marker and always exits 20 "could not commit them either". It never reads `limit_hit` from the checkpoint verdict nor `PAUSE_REQUESTED`, which the review branch does (-> `EXIT_PAUSED`). A `foreman stop --now`, Ctrl-C or the 5-hour window during a checkpoint therefore ends as "needs a human" with recovery advice, and exit-code consumers (the app) see 20, not 10. No data loss: the marker is written.
- Evidence: `FOREMAN_FAKE_BEHAVIOUR=dirty FOREMAN_FAKE_CHECKPOINT_BEHAVIOUR=stop-file foreman run batch --unlimited` printed "Interrupt received ... then pausing" and then "... the checkpoint turn could not commit them either. Stopping so you can look.", exit=20. With the scratch `limit` checkpoint behaviour: exit=20.
- Severity: med. Confidence: confirmed-by-repro.
- Fix: after `run_checkpoint_turn` falls out of the case, reuse the review block's limit / PAUSE_REQUESTED test (one shared function).

## 5. `FOREMAN_MAX_COST_USD` is the only budget with no validation: a typo silently means unlimited
- Where: `lib/foreman-config.sh:451-457` (validates the five integer settings, not the cost); gates `foreman-loop.sh:210-211, 1698, 1937`.
- What: `fgt`/`fge` use awk `a+0`, so `abc`, `$5`, `5usd`, `1,5` become 0 or a prefix, `fgt "$MAX_COST" 0` is false, and there is no cap and no warning. A user who set a cap to protect money gets none.
- Evidence: `FOREMAN_MAX_COST_USD='$5' foreman run batch --unlimited` (3 tickets): all 3 landed, exit 0, no complaint; same for `abc`. A valid `0.015` pauses correctly ("cost budget reached ($0.020000 of $0.015)").
- Severity: med. Confidence: confirmed-by-repro.
- Fix: validate `^[0-9]+(\.[0-9]+)?$` in config like the integers.

## 6. The recorder writes the verdict last; an earlier crash leaves an empty verdict that the loop reads as "nothing wrong, cost 0"
- Where: `lib/foreman-record.cjs:325` (jsonl append) and `:371` (log append) precede `:404` (verdict write); loop `:1809`, `:1819`, `:1823-1832`.
- What: the loop truncates the verdict first. If record.cjs dies on the jsonl/log write (full disk, log directory removed, a locked file on Windows), the ten greps return empty: `limit_hit`, `auth_failed`, `permission_denied`, `parse_ok` read as false, cost and tokens as 0. A real usage limit is then handled as an ordinary failure (dirty -> exit 20, no pause, marker dropped) and the cost budget never advances. Only a `warn_note` is printed.
- Evidence: `printf '{"type":"result","is_error":true,"result":"You have hit your session limit"}' | node foreman-record.cjs ... --log /nonexistent/dir/l --verdict v --exit-status 1 ...` gives an ENOENT stack trace, exit 1, and `v` is not created.
- Severity: low-med. Confidence: confirmed for the crash and ordering; trigger frequency unknown.
- Fix: write the verdict first, or wrap both appends in try/catch so the verdict always lands.

## 7. Review-turn salvage skips the continuation cap, and the marker's base ref can go stale on a hard kill (drifted duplicates)
- Where: `lib/foreman-loop.sh:1621-1626` vs `:1959-1967`; marker `:615`, `:626`.
- What: (a) the start-of-run salvage bumps CONTINUATIONS/STALLS but never calls `continuation_cap_reached`, unlike the mid-run copy. With `FOREMAN_MAX_CONTINUATIONS=1` the rescue uses up the one allowed extra turn and the next real progression trips the cap ("needed 2 extra turns" against a cap of 1). (b) `mark_turn_in_flight` records `base_ref` = HEAD before the turn. On local / sandbox-mount adapters a turn that made a `wip:` commit and was then killed hard (closed terminal) leaves HEAD != base_ref, so `stall_marker_matches` fails and the rerun refuses as "untrusted". Only the graceful limit/Ctrl-C path rewrites the marker against HEAD (`:1844`). The checkpoint turn's own in-flight marker (`:1435`) uses BASE_REF the same way after a stalled turn that already committed.
- Severity: low. Confidence: (a) high by reading; (b) needs-verification (not reproduced).
- Fix: (a) one shared salvage-bump function that includes the cap test; (b) write `git rev-parse HEAD` as base_ref in `run_checkpoint_turn`'s marker.

## Checked and found sound
Counter resets on ticket change (L1557); attempts reset on progress/salvage; retry bounded by TICKET_ATTEMPTS; graceful `stop` floor of 1 (keys.sh:114, 157); empty or malformed batch in `foreman_next_answer` (exits 1 with a message); float cost gate (`0.015`); stale verdict (truncated at L1809); in-flight marker removal on every non-pause path; `verdict_num` for token sums; FINAL_STATUS / NEEDS_REASON are set before every `break` in the ladder.
