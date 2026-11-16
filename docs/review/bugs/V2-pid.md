# V2 — run pid file: process identity (verification)

Checked 2026-11-16 on Windows 11 / Git Bash (MSYS), node 24. Scratch repos were built with
test/fixture.sh under the session temp dir. No tracked file was changed.

## A. MSYS pid vs Windows pid — CONFIRMED (on a stale pid file; consistent while the run is alive)

What gets written (foreman-loop.sh L1155-1157): `"$$ ${winpid:-$$}"`, the loop's MSYS pid and then its
Windows pid. Readers: the loop guard (L1142-1143) and foreman-control.sh L94-95 check `kill -0 <msys>`.
foreman-json.cjs L307-310 (`readRun`) checks `process.kill(<win>, 0)`. So each side reads its own
namespace, and they agree only while the run is alive.

    $ (sleep 20 &) ; msys=1210 win=12332
    node process.kill: 1210 ESRCH, 12332 alive    # node only knows Windows pids
    bash kill -0 1210 ok; kill -0 12332 -> No such process   # bash only knows MSYS pids
    $ bash -c 'echo $$ $(cat /proc/$$/winpid); sleep 30'   # -> msys=1196 win=30424, but ps -W then
      shows 1196 with WINPID 9268: an MSYS exec keeps the MSYS pid and changes the Windows pid.

Repro of the split, using a stale pid file whose Windows pid has been reused (explorer's):

    pid file "99999 11156"  -> status --json run.in_flight = true ; foreman stop -> "no run in flight", rc 1
    pid file "<live msys> 99996" -> status --json in_flight = false ; foreman keys + -> accepted, rc 0

Windows recycles pids quickly, and a reboot or a `taskkill /F` leaves the file behind. The GUI's
run:start (gui/main.cjs L262-263) and Stop both go through `status --json` and `foreman stop`, so the GUI
refuses Start ("already in flight") while Stop says there is no run. A CLI `foreman run` still starts
(msys check), and it clears the stale dir, which unsticks the GUI.

**Fix (smallest):** have one predicate, in bash. Add `run_pid_alive MSYS WIN` to foreman-config.sh:
`kill -0 "$1" && { [ ! -r /proc/$1/winpid ] || [ "$(< /proc/$1/winpid)" = "$2" ]; }`. This is a real
identity check: a reused MSYS pid has a different winpid. Use it at loop L1143 and control.sh L95, reading
both fields. In status_json_facts (loop ~L745), emit `runalive\t0|1` from it. readRun (json.cjs L310) then
trusts `runalive` when present and falls back to pidAlive(win) off-bash. The CLI and JSON then always
agree, and the GUI follows. Users see no change except that stale files stop counting as runs.
**Test (test/smoke-json.sh style):** ctl_repo; write `batch/.foreman-run/pid` = "99999 <winpid of a live
process: tasklist explorer.exe>" plus a `run` file; assert `status --json` `.run.in_flight` is false AND
`foreman stop batch` exits 1. Then write "$$ 99996" and assert both say not in flight. gui/test: a readRun
unit test with `io.readFile` stubbed and a `runalive 0` fact, so in_flight is false although alive(win) is true.

## B. Second `foreman run` on a live batch — CONFIRMED, reproduced

L1143-1144: if the pid is alive, the guard runs `:` and falls through to `RUN_CTL_DIR=$(mktemp -d)`
(L1153). Nothing refuses. Repro: 3 tickets, `**/.foreman-run/` ignored, FOREMAN_FAKE_SLEEP=4. Run 1 in
the background; once `pid` exists ("648 3960"), start run 2 on the same batch.

    r1: landed 01,02,03 ... "batch marked done · DONE_batch"            exit 0
    r2: run ...-804 "Tickets done: 0 / 3"; iteration 1: awk: cannot open batch/issues/01-ticket.md
        "⋯ progressed · 08f2a72" (r1's commit, credited to r2); ticket 03 "stalled ... Running a
        checkpoint turn" (r1's in-flight edits); batch/.foreman-stall-marker: No such file (batch
        renamed under it); foreman-record.cjs ENOENT foreman-runs.jsonl; 14x line 230 log errors   exit 20

Both reported consequences are seen: r2 treated r1's work as a stall, and r1's DONE_ rename broke r2.
**Fix:** at loop L1143-1144, replace `:` with
`echo "foreman run: a run is already in flight in $BATCH_DIR (pid $RUN_CTL_PID); stop it first (foreman stop)" >&2; exit 1`
(preflight exit code, EXIT CODES L91). Use A's run_pid_alive so a stale file never blocks a run.
**Visible behaviour change:** a second run on the same batch now refuses with exit 1, where before it ran a
duplicate loop. The comment at L1123-1124 ("keeps a directory of its own") must change too. Gap left
open: if the repo does not ignore `.foreman-run/`, there is no pid file in the batch, so there is still
no guard. A lock outside the ignore rule, e.g. `mkdir "$GIT_DIR/foreman-<batch>.lock"`, would close it.
**Test (smoke-json):** ctl_repo 2; BG_ENV=(FOREMAN_FAKE_BEHAVIOUR=hang-dirty FOREMAN_FAKE_HANG=734); bg_run;
wait for .foreman-fake-leftover; `run_foreman "$repo" run batch` gives ST=1 with "already in flight", and
`git log` has no new commit. Then `foreman stop --now`, bg_wait, BG_ST=10.

## C. `stop --now` on Git Bash — SIGINT reaches MSYS children only; pid reuse is PLAUSIBLE, not reproduced

Git Bash has /proc, so stop_descendants takes the /proc branch; the `ps -o` fallback never runs here.
Traced with a hang-dirty fake run (FOREMAN_STOP_GRACE=3):

    pid file: 346 19072 (/proc/346/winpid=19072); descendants: 527 bash foreman-loop.sh,
    528 node.exe foreman-stream.cjs, 531 sleep 733
    foreman stop: stopped the run in batch ... rc=0 after 4s; "Interrupt received"; "PAUSED: interrupted
    (Ctrl-C)"; run exit 10; no sleep/foreman-stream left (ps -ef)

`kill -INT` ends MSYS processes (the fake's `sleep`). A native Windows process ignores it. Probe:
node.exe with a SIGINT handler, `kill -INT <msys pid>`: the handler did not run and node stayed alive.
The real agent, `sbx` (…/DockerSandboxes/bin/sbx), is native. So on Windows `--now` never delivers
Ctrl-C to the agent. It waits the full grace period, then stop_force runs `taskkill /F /T` on it
(control.sh L148-156), so the result is a hard kill. That is why this run took the full 3 s+1 s, held up
by the native node feed. The suite's `stop --now` failure on this machine has a different cause. Case
"a detached run…" fails with `spawn C:/Projects/foreman/bin/foreman ENOENT`: det_run (smoke-json
L2024) node-spawns a shebang script, which Windows cannot do. The bg_run case passes (6/0). Also,
`agent_left`/`feed_left` (L2038-2039) use `pgrep`, which is absent here ("pgrep: command not found"), so
their "no agent process is left" assertions pass vacuously on Windows.
PID reuse: stop_now trusts `kill -0 <msys>` (L95, L189) and then INTs, and later `taskkill /F /T`s,
every descendant of that pid. MSYS pids were sequential here (346…1599), so reuse needs a wrap or a
reset of the MSYS pid table. That makes it unlikely, but a stale file plus a reused pid would signal an
unrelated tree. Not reproduced. The same run_pid_alive check (winpid must match) closes it, at L95 and
before L168. For Ctrl-C to reach native agents on Windows, the agent would need its own console group
(out of scope here). Tests: run det_run through `bash "$FOREMAN"`, and make agent_left fall back to
`ps -ef | grep` when pgrep is missing.
