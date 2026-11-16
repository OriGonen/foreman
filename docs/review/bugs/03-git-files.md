# Bugs 03: git and file state

Scope: tickets/order/next/repo/legacy/convert/init, loop start sweep and renames, sandbox bundle transport.
Repros ran in a temp repo outside this checkout with `FOREMAN_EXEC=fake` (fixture from `test/fixture.sh`). Nothing tracked was modified.
Ruled out by repro (no bug): ticket names with spaces and `[brackets]` rename and commit correctly; CRLF in order.md / tickets / foreman.conf is stripped before parsing.

## 1. [HIGH, data loss, confirmed-by-repro] A second `foreman run` on a live batch is not refused; it steals the work and renames the batch under the first

`lib/foreman-loop.sh:1140-1153`. When `<batch>/.foreman-run/pid` names a live process, the code only skips the shared control dir and falls through to `RUN_CTL_DIR="$(mktemp -d)"`. Nothing stops the run. There is no lock.

```
if [[ "$RUN_CTL_PID" =~ ^[0-9]+$ ]] && kill -0 "$RUN_CTL_PID" 2>/dev/null; then
  :        # <- live run found, then carry on anyway
...
[ -n "$RUN_CTL_DIR" ] || RUN_CTL_DIR="$(mktemp -d)"
```

Repro: 3-ticket batch, `FOREMAN_FAKE_SLEEP=4`, run A in the background, run B 1.5s later. Observed:
- B picked up A's in-flight uncommitted edit as a "stall" and ran a paid checkpoint turn. It committed `wip: batch/issues/01-ticket.md — remaining: the rest` in the middle of A's turn.
- B finished first and ran `mark_batch_done_on_disk`, so `batch/` became `DONE_batch/` while A was still running.
- A then printed `foreman-loop.sh: line 230: batch/foreman-runs.log: No such file or directory` on every log append, `foreman next failed with status 2`, and `.foreman-run/budget: No such file or directory`.
- A's telemetry after the rename was lost. A still reported "tickets landed: 3".
- Under the default sandbox adapter both loops share one clone (`foreman-<repo>`). Run B's `exec_sync_down` (`git reset --hard && git clean -fd`, sandbox.sh:64) then runs over run A's live agent. This part is read from the code, not run.

Fix: refuse to start (exit 1 with "run already live, pid N") when the pid file is alive. Better, take a lock keyed on the sandbox name or the repo, because batches share one clone.

## 2. [HIGH, data loss risk, high confidence] Any host commit during a turn strands the iteration's commits; a rerun then destroys them

`lib/exec/sandbox.sh:120-147` and `lib/foreman-loop.sh:1841-1848`. The pre-merge check only asks `merge-base --is-ancestor $base HEAD` against the iteration's BASE_REF. If the host branch moved during the turn (the human committed, a second run landed, a stall rescue), the bundle fetches fine but `git merge --ff-only` fails. The replay-onto-base logic never runs, because the sandbox commits do sit on `base`.

```
git merge --quiet --ff-only refs/foreman/incoming ... || { warn "could not fast-forward ... (diverged?)"; return 1; }
```

Git repro of the same sequence (host commit after BASE, bundle from the clone): `merge=128 Not possible to fast-forward`.
The commits now exist only in the sandbox. The loop exits 20 with a printed note, but nothing persists. `sync_failed` removes the stall marker (loop:1846), and `exec_tree_dirty` sees a clean tree. A plain rerun calls `exec_sync_down`, which does `git reset --hard BASE`. That leaves the agent's commits only in the sandbox reflog. The only guard is the "Do not rerun" text.

Fix: before bundling, rebase the sandbox commits onto the host's current HEAD (`git rev-parse HEAD` passed in, not `$base`), not onto `$base`. Also write a `stranded` marker that `exec_sync_down` refuses to reset over.

## 3. [MED, confirmed-by-repro] A finished batch becomes unreadable: the batch rename breaks every repo-relative order.md entry

`lib/foreman-loop.sh:482-491` (`git mv "$BATCH_DIR" "$renamed"`) together with `lib/foreman-tickets.sh:123-139,168-172` (`_foreman_resolve_ticket`). `foreman init` and `foreman order` write repo-relative paths (`batch/issues/01-ticket.md`). After `batch/` is renamed to `DONE_batch/`, those entries resolve nowhere. The DONE_ fallback only re-prefixes the file name, not the directory.

Repro after a clean 2-ticket run:
```
$ foreman status DONE_batch
foreman-next.sh: DONE_batch/order.md lists a ticket that does not exist: batch/issues/01-ticket.md
$ foreman status --json --all
..."name":"DONE_batch","finished":true,"counts":null,...,"error":"foreman-next.sh: DONE_batch/order.md lists a ticket that does not exist..."
```
So `status --json --all` (and so the GUI's finished-batch list) shows an error for every finished batch that uses the default order.md. `foreman next/dry-run DONE_batch` also fails.

Fix: in `mark_batch_done_on_disk`, rewrite the old batch path prefix in order.md inside the same commit. Or have `_foreman_resolve_ticket` also try the entry with its leading `$BATCH_DIR` replaced by the current one.

## 4. [MED, confirmed-by-repro] Stale `refs/foreman/incoming` makes every later bundle fetch fail with a misleading message

`lib/exec/sandbox.sh:140-148`. The fetch refspec has no `+`, and the ref is only deleted on full success. After a failed ff-merge (see 2) the ref stays at the unmerged commit. If the user then abandons or rewrites that work (reset, cherry-pick, rebase), the next iteration's `git fetch bundle HEAD:refs/foreman/incoming` is rejected as non-fast-forward.

```
fetch=0 (iteration 1) ... merge=128 ... ; after sandbox reset to new host HEAD + new commit: fetch2=1
```
The loop reports "bundle did not contain a fetchable ref", and the iteration's work is stranded again.

Fix: `git update-ref -d refs/foreman/incoming` before the fetch, or use `+HEAD:refs/foreman/incoming`. Fix the warning text to show git's stderr.

## 5. [MED, data loss for untracked files, confirmed-by-repro] `foreman convert` rewrites any "Ralph" in every text file, including untracked ones, with no backup and no check the project used the toolkit

`lib/foreman-convert.cjs:146` (`trackedOrNew` includes `--others --exclude-standard`) and `:225` (`writeFileSync`, non-atomic, in place). The clean-tree guard uses `--untracked-files=no`, so untracked files are never protected. The rewrite is also name-blind:

```
CREDITS.md:           Ralph Smith <ralph@example.com> wrote this.  ->  Foreman Smith <foreman@example.com> wrote this.
notes-untracked.txt:  Meeting notes: Ralph said ship it.           ->  Foreman said ...   (git cannot restore it)
```
Tracked changes are recoverable with `git checkout`; untracked ones are not. It also runs happily in a repo that never had ralph in it.

Fix: refuse when the untracked-not-ignored list contains files that would be rewritten (or skip them). Only touch files that mention a `RALPH_`/`ralph-loop`/`ralph.conf` token, not bare "Ralph".

## 6. [LOW-MED, confirmed-by-repro] Relative batch paths are resolved from the repo root, not the caller's directory, contrary to the code comment; `init` disagrees with `run`

`lib/foreman-config.sh:61` does `cd "$REPO_ROOT"` before `:93 foreman_batch_relpath ... "$FOREMAN_BATCH"`, whose `[ -d "$_rb_given" ]` (`lib/foreman-repo.sh:94`) is therefore evaluated from the root. The comment at config.sh:90-92 and repo.sh:80-91 says "relative to the repo root or to the caller's own directory". `foreman-init.sh:80-82` resolves before its `cd` (the caller's directory), so it works from a subdirectory.

```
$ cd sub && foreman next batch --all     -> foreman: no such directory: batch      (rc 2)
$ cd sub && foreman next sub/batch --all -> works
$ cd batch/issues && foreman next ..     -> "the batch directory must be inside the repository"
```
`foreman init sub/x` then `foreman run x` from the same directory fails. Worse, a name that exists both under the cwd and at the repo root silently picks the root one.

Fix: resolve the given path to absolute before the `cd` (in config.sh, `FOREMAN_BATCH=$(cd "$given" && pwd)` when it is a directory relative to `$PWD`), or fix the comments.

## 7. [LOW, confirmed by reading] order.md is rewritten non-atomically, and the running loop `exit 1`s on a half-written one

`lib/foreman-init.sh:217` (`> "$BATCH_DIR/order.md"`, truncate then write) and `lib/foreman-order.sh:264` (the agent edits `order.md` in place with no backup or validation afterwards). The loop re-reads the order every pass (loop:1517-1523). If it lands in the truncated window, or the agent drops a ticket, `_foreman_tickets_compute` fails with "no ORDER:BEGIN block". `next_sh` returns 2 and the loop takes its generic `exit 1` path, mid-run, after spending. The window is small, but `foreman order` is documented as re-runnable and the GUI reads the same file.

Fix: write to `order.md.tmp` then `mv -f`. After the agent edit, check that every ticket of `--unordered` is still listed, otherwise restore the saved copy.

## 8. [LOW, data loss only with `--force`] `foreman init --force` replaces progress.txt and foreman.conf with blank templates, unbacked-up; `mkdir -p` runs before validation

`lib/foreman-init.sh:80,217,235` and the `cp` of the template over `foreman.conf`. `progress.txt` is the agent's running memory and is normally committed, but an uncommitted one is gone. `foreman.conf` may hold untracked tuned settings. Also `mkdir -p "$BATCH_INPUT"` (line 80) creates the directory before the "inside the repo" check (line 82), so `foreman init ../elsewhere/x` leaves a stray empty directory outside the repo.

Fix: skip `progress.txt` under `--force` (or rename the old file to `.bak`), and validate the path before `mkdir -p`.
