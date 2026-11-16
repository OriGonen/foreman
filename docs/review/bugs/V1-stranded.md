# V1: verification of the stranded-sandbox-commits chain (02 #1, 03 #2, 03 #4)

Verified against HEAD 6d01ff8 by running the real loop + real `lib/exec/sandbox.sh` with a stub `sbx`
(the `sbxrescue` stub from test/smoke.sh L1011, plus `STUB_CP_FAIL`) and a stub `claude` that commits
in the clone (plus `STUB_LIMIT` = usage-limit payload, `STUB_HOST_COMMIT` = commit on the host mid-turn).
Harness: scratchpad `v1/repro.sh`, `a.sh`, `b.sh` (outside the repo).

**What protects un-collected commits on the next run: nothing.** The marker is dropped whenever
`sync_failed=1` (loop L1841-1847). Preflight (L909) checks only the host tree; the start sweep (L947) only
host renames; the start-of-run check (L1580) and the pre-sync check (L1727) ask `exec_tree_dirty`, which
looks at `git status` only. A clone that is *clean but ahead* passes all of them, and `exec_sync_down`
(sandbox.sh L63-68) does `reset --hard BASE`. The stranded branches (L1891, L1648, L1951) differ from the
pause branches only in *printing* `exec_recovery_note` and exiting 20; they write no state either.

## A. Pause/auth shadows `sync_failed` -> "nothing to restore" -> rerun resets over commits: CONFIRMED (repro)
Run 1, `STUB_CP_FAIL=1 STUB_LIMIT=1`:
```
   could not copy the bundle out of the sandbox
PAUSED: usage limit reached · resets 2025-01-01T00:00:00.000Z
          (nothing to restore — the tickets' Status lines are the resume point)
EXIT=10      sandbox HEAD X=de3da36 "agent: turn 1 work"; host has X? no; stall marker: none
```
Run 2 (plain rerun): no refusal, iteration 1 starts; afterwards X reachable from sandbox HEAD? no; from host? no.
X survives only in the clone's reflog (expires with `gc.reflogExpireUnreachable`, 30d); nothing points at it.
Ctrl-C/stop-file (L1860) and auth (L1869) take the same path by reading; not run live. A natural trigger
for "interrupt + collect failure together": Ctrl-C while `exec_collect` runs kills the `sbx cp`/`sbx exec` child.

## B. Host commit during a turn -> ff-only fails -> rerun resets: CONFIRMED, with a correction (repro)
Run 1, `STUB_HOST_COMMIT=1`: `could not fast-forward onto the sandbox's commits (diverged?)`,
"That work exists ONLY in the sandbox", EXIT=20, no marker. `_sbx_sync_up` checks only `is-ancestor base HEAD`
(sandbox.sh L117), never the host's *current* HEAD. Run 2 (plain rerun) resets the clone: X no longer
reachable there. **Correction:** the commits are *not* only in the sandbox: the fetch at L140 succeeded
before the merge failed, so X sits on the host at `refs/foreman/incoming` (verified = X). The note is wrong
about where the work is, and never mentions that ref. Data survives on the host, invisibly, until C bites.

## C. Stale `refs/foreman/incoming` + no `+` refspec -> every later fetch fails: CONFIRMED (repro)
Continuing B: run 2 and run 3 both print `bundle did not contain a fetchable ref`, EXIT=20; incoming still X.
Each such run strands its own new commit (Y2=5bc939b) *without* fetching it, and the next rerun resets over
it: a self-sustaining loss loop, each rerun destroying the previous run's work. Escapes only if the operator
follows the printed recovery exactly (its `git merge` makes the host contain X, so the next fetch is ff) or
deletes the ref by hand.

## Fixes (smallest correct first)
1. **The real guard: sandbox.sh L64, `exec_sync_down`.** Refuse to reset a clone whose HEAD the target does
   not contain: `git fetch --quiet origin && git merge-base --is-ancestor HEAD $1 && git reset --hard $1 ...`,
   with its own message (`exec_recovery_note "$1"` wording: commits exist only in the sandbox; or
   `sbx exec NAME git reset --hard` to discard on purpose). Covers A, B, C and any future strand path,
   whatever the ladder or marker did. False positive only if the host rewrote history (amend/reset) since
   the last sync; the message names the override.
2. **sandbox.sh L140:** `"+HEAD:refs/foreman/incoming"` (or `git update-ref -d refs/foreman/incoming`
   before the fetch). And on ff failure (L144-147) say the commits are also at `refs/foreman/incoming`.
3. **B at the source, sandbox.sh L117-128:** replay onto the host's *current* HEAD, not BASE:
   `onto=$(git rev-parse HEAD)` and use `$onto` in the ancestry check, the rebase and the bundle range.
   A host commit mid-turn then rebases in the clone like the existing moved-host path does.
4. **A's message, foreman-loop.sh:** move the `sync_failed` branch (L1891-1897) above L1854, so a stranded
   turn exits 20 with the recovery note instead of 10 + "nothing to restore". (Optionally keep the
   in-flight marker when `sync_failed=1`.) With fix 1 this is wording, not data safety.

## Regression tests (test/smoke.sh style)
FOREMAN_FAKE_BEHAVIOUR cannot drive this: fake.sh works in the host tree and never strands. Extend the
`sbxrescue` stub of the case at L1007: `cp) [ -z "$STUB_CP_FAIL" ] || exit 1; ...` in stub `sbx`; in stub
`claude`, `STUB_LIMIT` (print the `Claude AI usage limit reached|<epoch>` result, exit 1) and
`STUB_HOST_COMMIT` (`git -C "$STUB_HOST" commit --allow-empty` before printing the result).
```bash
if case_is "a sandbox commit that could not be collected is never reset over"; then
  repo="$(make_repo 2 sbx-strand-repo)"; ...sandbox conf, clone as in rescue_setup...
  STUB_CP_FAIL=1 STUB_LIMIT=1 run_sandboxed            # A
  x="$(git -C "$clone" rev-parse HEAD)"
  assert_eq "$ST" 20 "stranded beats the pause"; assert_contains "$OUT" "ONLY in the sandbox" "says where"
  assert_missing "$OUT" "nothing to restore" "never claims there is nothing"
  run_sandboxed                                         # plain rerun
  assert_eq "$ST" 20 "the rerun refuses"
  git -C "$clone" merge-base --is-ancestor "$x" HEAD && pass || fail "the stranded commit is still on HEAD"
  # B+C: STUB_HOST_COMMIT=1 run_sandboxed -> expect ST 0/progress with x rebased onto the host commit
  # (fix 3); then a second run must not print "fetchable ref" (fix 2).
fi
```
