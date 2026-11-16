# Full-suite regression run: 6d01ff8 (main) vs review/deep-refactor

Trees: clean `git archive` exports (no .git needed), base = 6d01ff8, head = 5f5c8f7. Run one after the
other on the same machine, default jobs (8). Logs: scratchpad `full/logs/`.
NOTE: the branch moved while the run was in progress (head is now 43faa42, three commits later:
085b4ea R1, 24ad1b1 test follow-up to T06, 43faa42 R2). The run covers 5f5c8f7, the 11 fix commits + docs.
Only the single case named under "Regressions" was rerun against 43faa42.

## Totals (pass / fail assertions)

| suite                  | base 6d01ff8   | head 5f5c8f7   |
|------------------------|----------------|----------------|
| test/smoke.sh          | 2516 / 85      | 2675 / 87      |
| test/smoke-json.sh     | 685 / 34       | 696 / 36       |
| gui `node --test`      | 462 pass / 0 fail / 1 skip (463) | 489 pass / 0 fail / 1 skip (490) |

Failures were keyed by (case name, assertion label) and diffed. All 85/87 and 34/36 FAIL lines map to
distinct keys, and every base key still fails in head.

## Base failures (all still failing in head): environment, not code
Windows/MSYS path forms (`C:/Program Files/Git/home/...`, `C:\Users\...` vs `/tmp/...`, 96 vs 288 wide), no
`script` and no `claude` on PATH, FOREMAN_DOCKER_USERNAME set in this machine's env, `Invalid regular
expression flags` in a jv helper. Identical set in both trees, so they cannot hide a regression.

## Fixed (fail in base, pass in head)
None.

## Regressions (fail in head, pass in base): 4 candidates, 3 are not regressions
1. smoke-json, case "a stop file in the control directory pauses the run as Ctrl-C does, and nothing else
   sees it", assertion "stopped during the checkpoint turn: the exit code of an unsalvaged stall, as with
   Ctrl-C": `expected '20', got '10'`. Deterministic (fails alone, 2 of 2).
   Diagnosis: intended behaviour change from a85554a (T06): a stop during a stall checkpoint now pauses the
   run (exit 10) where it used to end needs-a-human (exit 20). The test was updated in 24ad1b1, which is
   after 5f5c8f7. Rerun at 43faa42: the case passes, 10 passed 0 failed. Not a regression at the branch tip.
2. smoke-json, case "dry-run --json: sends nothing and starts no sandbox", assertion "and was never called":
   `expected '0', got '1'`. Passes alone in head, 2 of 2.
   Diagnosis: test pollution. The case counts `foreman-fake-*.calls` files in the shared $WORK; the case
   added by 9578d43 / T09 ("status --json --all: a finished batch with a repo-relative order.md ...", about
   line 542) does a real fake-adapter `run batch` earlier and leaves one. Product code is fine; that new
   case needs `rm -f "$WORK"/foreman-fake-*.calls` at its end, as lines 250, 1112, 1770 do.
   Order-dependent: fails in a full run, would pass alone.
3. smoke.sh, case "foreman order draws the stake line when the show is on: ...", assertion "no cost, none
   said": expected `ordered in 0s`, got `1s`. Flaky: passes in head alone (1 of 2 reruns failed, 1 passed),
   passes in base 3 of 3. Wall-clock second boundary in the elapsed text (the sibling assertion "a blank
   row, the header...", same 0s/1s text, also fails in base's full run). Treat as flaky.
4. smoke.sh, case "SIGTERM during a turn ends the turn at once and pauses the run, footer and all": `TERM
   ended the run in 11 s, not at once`. This case is new in head (e13d045 / T13), so it has no base result.
   Passes alone in head, 2 of 2 (about 8 s per case, 13 assertions). Timing-sensitive under 8-way load;
   flaky, not a regression.

## Flaky candidates
- order stake line (0s vs 1s), SIGTERM-ends-at-once (11 s under load). Both pass on rerun alone.
- Parallel smoke.sh run at 8 jobs took 19 min (base) and 26 min (head, 15 more cases); a lower
  FOREMAN_SMOKE_JOBS would likely remove the two timing flakes.

## Conclusion
No assertion that passed at 6d01ff8 fails at the branch tip for a product reason. gui `node --test`: 0 fails
in both trees. One test-isolation bug to fix in the T09 case (item 2).
