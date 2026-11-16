# Map 02: loop, exec adapters, control, prompt, tickets
All refs are `lib/` relative. "L" = foreman-loop.sh. Read-only survey; nothing here was run.

## 1. Launch-to-end trace (`foreman run`)
Script is `set -uo pipefail` (no `-e`; every failure is hand-checked) L:93. One flat script, not functions.
1. Arg parse L:119-146 (MODE, MAX_ITERATIONS, ADOPT_DIRTY; `--live` exports FOREMAN_STREAM=1). `status --json --all` fans out by re-running L per batch L:161-187.
2. Config: `source foreman-config.sh` L:190 (cd to REPO_ROOT; sets BATCH_DIR, RUN_JSONL/RUN_LOG/PROGRESS_FILE/BUNDLE_FILE config.sh:335-342, STALL_MARKER_FILE :347, FOREMAN_EXEC default `sandbox` :356). Then foreman-human.sh (pulls foreman-tickets.sh) L:192, foreman-ui.sh L:194.
3. Adapter load: `foreman_exec_load "$FOREMAN_EXEC"` L:636 -> exec.sh:80 sources lib/exec/<mode>.sh.
4. status / dry-run exit here (L:827-875, L:1036-1084). Dry-run sources foreman-prompt.sh to print the prompt L:1080.
5. Preflight L:881-940: git/node/awk on PATH, `exec_required_tool` + `exec_preflight` L:889-896, batch dir exists, `foreman_tickets_hold` snapshot L:902, dirty tree (unless marker matches / ALLOW_DIRTY / ADOPT_DIRTY) L:910, run-state files must be gitignored L:925-938.
6. Start sweep L:947-953: each done+ticked+unprefixed ticket -> `mark_ticket_done_on_disk` (git mv + commit, L:412-451). Skipped on a dirty tree.
7. Early exits: nothing left -> `mark_batch_done_on_disk`, exit 0 L:959-968; head ticket is human -> `human_ticket_note`, exit 30 L:973-978 (no cost, nothing logged).
8. Run init L:1089-1113: RUN_ID, counters, `VERDICT_FILE`/`PAYLOAD_FILE` mktemp. Control dir L:1138-1169 (`<batch>/.foreman-run/` if gitignored and no live pid, else `mktemp -d`); seeds budget/iteration/live/run/pid. `trap on_exit EXIT` L:1196. STREAM_ARGS L:1223-1252. `trap on_interrupt INT TERM` L:1266. Run-log header L:1279-1289; header/progress line L:1291-1296.
9. `exec_prepare` L:1301 (sandbox create + readiness probe, before money). Key reader `foreman-keys.sh ... &` L:1323 (tty stdin only).
10. `while true` L:1508-2089. Per pass:
    a. `check_stop_file` L:1509 -> pause (exit 10).
    b. `foreman_tickets_release` L:1517; `TICKET_FILE=$(next_sh)` L:1523 (-> foreman_next_answer tickets.sh:256; status 1 = all done -> exit 0; other = exit 1). Human head ticket -> exit 30 L:1542-1552.
    c. New ticket resets per-ticket counters L:1557-1565.
    d. One-time start-of-run marker check L:1577-1687: marker or `--adopt-dirty` -> `run_checkpoint_turn review` (L:1398) -> case salvaged / rejected / stranded / discarded / other.
    e. `ATTEMPTS++` L:1689; `refresh_budget` L:1692 (reads ctl `budget`); iteration / cost / time gates L:1693-1707 (pause, exit 10).
    f. `ITERATIONS_RUN++`, `BASE_REF=$(git rev-parse HEAD)`, ctl `iteration` file L:1709-1720.
    g. Refuse to sync over a dirty agent tree: `exec_tree_dirty "$BASE_REF"` L:1727-1744 (exit 20); `exec_sync_down "$BASE_REF"` L:1750.
    h. Flags FOREMAN_CONTEXT_RETRY / FOREMAN_CONTINUATION / FOREMAN_STALL_CONTINUATION / FOREMAN_REVIEW_BASE L:1759-1773, then `source foreman-prompt.sh` L:1776 (top-level code; fills prompt.template.md via `_foreman_fill` prompt.sh:205-226, + progress tail :257, + continuation preamble :270, + context-retry sentence :308).
    i. `mark_turn_in_flight` L:1786 (marker only if gitignored, L:613). Spawn: `exec_run "$FOREMAN_PROMPT" "$TICKET_FILE" </dev/null | node foreman-stream.cjs $STREAM_ARGS > $PAYLOAD_FILE` L:1787-1788; `agent_status=${PIPESTATUS[0]}` L:1789; `check_stop_file` L:1790; `result=$(cat $PAYLOAD_FILE)` L:1791.
    j. `exec_collect "$BASE_REF"` L:1801 (sandbox: bundle + ff-merge; sets EXEC_DIRTY, EXEC_AGENT_HEAD); `HEAD_REF`, `flipped` via `ticket_is_done` L:1804-1805.
    k. Record: `printf result | node foreman-record.cjs --jsonl --log --verdict ...` L:1813-1819 (appends RUN_JSONL + RUN_LOG, writes verdict k=v file); `accumulate_usage` L:1821 (cost via awk, L:208).
    l. 10 verdict keys read with one grep each L:1823-1832. Marker kept only if (limit or pause) and dirty and not sync_failed, else removed L:1841-1848.
    m. Decision ladder (order matters): 1 `limit_hit` -> pause L:1854; PAUSE_REQUESTED -> pause L:1860; 1b `auth_failed` -> exit 20 L:1869; 2 `sync_failed` (stranded) -> exit 20 L:1891; 3 `permission_denied` -> exit 20 L:1904; 4 dirty: stall signature (`agent_status=0 && !is_error && !flipped`) -> `run_checkpoint_turn` L:1931-1948 -> salvaged = continuation++ then `continue` L:1958-1968, else marker + exit 20 L:1989-1997; dirty-other -> exit 20 L:2003; 5 `flipped` -> LANDED++, `mark_ticket_done_on_disk` (+ the checked human ticket), header redraw, `continue` L:2012-2025; 6 HEAD moved, no error -> "progressed", continuations++, attempts reset, `continuation_cap_reached` L:2038-2049; 7 retry if `ATTEMPTS < TICKET_ATTEMPTS` and (transient | context_exhausted | nonzero exit with parse_ok) L:2065-2072; else exit 20 L:2074-2088.
11. Footer L:2094-2189: `trap - INT TERM`, summary, log append, overshoot note, per-FINAL_STATUS text (`resume_args` L:532), `run_ctl_end` L:2190, `mark_batch_done_on_disk` only on exit 0 L:2192, `exit $FINAL_STATUS` L:2194.
Exit codes: 0 done / 10 paused / 20 needs human / 30 waiting on human / 1 preflight or crash (L:99-102).

## 2. foreman-loop.sh inventory (2194 lines)
| Lines (size) | Concern | Functions / content | Shared globals |
|---|---|---|---|
| 1-103 (103) | Help text (doubles as `show_help`, awk L:117) | comments | - |
| 104-199 (96) | Arg parse, `status --json --all` | inline | MODE, MAX_ITERATIONS, ADOPT_DIRTY, LIVE_FLAG, STATUS_JSON/ALL |
| 204-290 (87) | Small helpers, verdict read, usage, cap | say warn fadd fsub fge fgt verdict_get verdict_num log_append accumulate_usage continuation_cap_reached budget_label tree_is_dirty ticket_is_done | RUN_COST/INPUT/OUTPUT/CACHE_*, CONTINUATIONS_ON_CURRENT, STALLS_ON_CURRENT, NEEDS_REASON, RUN_LOG |
| 292-389 (98) | Run-as-picture (RUN_SHOW) | run_header_facts run_header run_write_spent run_iteration_line run_event | RUN_SHOW RUN_TIER RUN_COLS ITER_* RECORD_QUIET RUN_CTL_DIR |
| 391-492 (102) | Rename done ticket / batch (git mv + commit) | ticket_has_unchecked_boxes mark_ticket_done_on_disk mark_batch_done_on_disk | FOREMAN_DONE_PREFIX BATCH_DIR |
| 494-573 (80) | Ticket listing, resume text, human note | next_sh print_remaining_marked human_tickets_remaining resume_args human_ticket_note | RUN_CTL_DIR LIVE_FLAG MAX_ITERATIONS |
| 594-628 (35) | Stall marker | stall_marker_get write_stall_marker mark_turn_in_flight stall_marker_matches | STALL_MARKER_FILE FOREMAN_SANDBOX BASE_REF TICKET_FILE |
| 641-1034 (~395) | status + dry-run renderers (not about running) | progress_line status_spent status_facts status_json_facts fact_escape dry_run_json_facts status_picture dry_run_facts dry_run_picture | STATUS_*/DRYRUN_* tiers, RUN_JSONL |
| 827-875, 1036-1084 (~100) | status / dry-run mode dispatch (inline) | | |
| 878-978 (100) | Preflight, sweep, pick, human gate (inline) | | preflight_failed next_ticket |
| 1086-1196 (110) | Run init, control dir, exit trap | run_ctl_clear run_ctl_end on_exit + inline setup | RUN_CTL_DIR KEYS_PID SAVED_STTY VERDICT_FILE PAYLOAD_FILE |
| 1198-1277 (80) | Budget refresh, stream args, signals | refresh_budget on_interrupt check_stop_file | PAUSE_REQUESTED PAUSE_REASON STREAM_ARGS BAR_ROWS |
| 1327-1506 (180) | Per-ticket state, checkpoint turn | checkpoint_discarded_note stranded_reason run_checkpoint_turn (~83) review_rejection_reasons (embedded `node -e`) | CHECKPOINT_OUTCOME/REJECTION FOREMAN_CLAUDE_ARGS HEAD_REF EXEC_DIRTY BASE_REF TICKET_FILE |
| 1508-2089 (**582**) | THE loop body: top level, no function | decision ladder | ~35 globals: ATTEMPTS_ON_CURRENT CURRENT_TICKET PREV_CONTEXT_EXHAUSTED CONTINUATIONS_ON_CURRENT TICKET_BASE_REF STALLS_ON_CURRENT LAST_CONTINUATION_STALLED START_OF_RUN_CHECKED STALL_MARKER_UNTRUSTED FINAL_STATUS HUMAN_TICKET, plus undeclared "locals" (agent_status dirty flipped limit_hit ...) |
| 2091-2194 (104) | Footer, final rename, exit | inline | FINAL_STATUS SALVAGED_OVER_* |

## 3. Executor abstraction
- Interface (foreman-exec.sh:11-35): `exec_required_tool, exec_default_permission_mode, exec_preflight, exec_prepare, exec_describe, exec_commit_note, exec_tree_dirty [TARGET], exec_sync_down BASE, exec_run PROMPT TICKET, exec_collect BASE (sets EXEC_AGENT_HEAD, EXEC_DIRTY), exec_show_dirty, exec_recovery_note BASE, exec_dirty_recovery_note BASE TICKET BATCH`. Plain `source`, no registry, no conformance check; a missing function is a runtime "command not found".
- Selection: `FOREMAN_EXEC` (conf/env, default `sandbox`) -> `foreman_exec_load` exec.sh:80. Modes = `lib/exec/*.sh` not starting with `_` (exec.sh:62). Peeking at a mode without adopting it uses a subshell (exec.sh:96, 109, 116).
- Adapters: `local.sh` (25 lines; `claude` in this tree, perm `acceptEdits`); `sandbox-mount.sh` (27; `sbx exec` on a bind mount, host-tree semantics from `_common.sh`); `sandbox.sh` (184; the default: private clone + `git bundle` over `sbx cp`; sync_down :63, tree_dirty :81, collect/_sbx_sync_up :97-152); `fake.sh` (422; no agent). Shared: `_common.sh` (host-tree semantics for local / sandbox-mount / fake), `_sbx.sh` (sbx create/probe/login, `exec_run` :125, bundle recovery text).
- exec_run builds one `claude --model --effort --permission-mode ${FOREMAN_CLAUDE_ARGS} --print <fmt> -p PROMPT` (local.sh:19-25, _sbx.sh:125-131). Format args: `foreman_exec_format_args` exec.sh:128 (json vs stream-json --verbose). Agent env BASH_MAX_TIMEOUT_MS from FOREMAN_COMMAND_TIMEOUT_MINUTES exec.sh:144.
- fake.sh: a scripted "agent" (about 25 behaviours via FOREMAN_FAKE_BEHAVIOUR, `:`-lists give per-call outcomes, fake.sh:11-91) that really runs git add/commit and prints claude-shaped JSON. It recognises checkpoint turns by the text "CHECKPOINT TURN" in the prompt (fake.sh:237). It exists so every loop branch (budgets, retry, stall, limit, auth, send-back, stop file, Ctrl-C, stream) is testable for free. It even sends the loop SIGINT (`kill -INT $$` :318).

## 4. Subprocess handling
| What | file:line |
|---|---|
| Agent turn: `exec_run ... </dev/null \| node foreman-stream.cjs > file`; status via PIPESTATUS[0]; foreground; **no timeout, no kill** | L:1787-1789; checkpoint L:1436-1438 |
| claude / sbx exec spawn | local.sh:21, _sbx.sh:127 |
| Every sandbox shell-out: `sbx exec NAME sh -c ... </dev/null` | _sbx.sh:17 |
| sbx ls/create/login (pw on stdin)/cp | _sbx.sh:55, 70-72, 149; sandbox.sh:136 |
| Recorder: `printf result \| node foreman-record.cjs` (verdict to file, not stdout) | L:1453, L:1813 |
| Renderer: `out="$(node foreman-draw.cjs ...; printf 'x%s' $?)"` to carry the exit code out of `$()` | L:331, 820, 1029 |
| Key reader backgrounded `bash foreman-keys.sh DIR $$ <&0 &`, KEYS_PID; killed + waited in `run_ctl_end` | L:1323-1324, L:1180-1183 |
| Spinner background (order) | order.sh:205-223 |
| Traps: `EXIT -> on_exit` L:1196 (kill keys, restore stty, rm temp files); `INT TERM -> on_interrupt` L:1266 (sets a flag only; bash runs it after the foreground pipeline returns); `trap - INT TERM` before footer L:2094; status-all `EXIT` L:169; keys.sh:329, :332; order.sh:245-247 |
| Temp files: VERDICT_FILE, PAYLOAD_FILE (mktemp) L:1109-1113; ctl dir mktemp -d L:1153; fake call counter `${TMPDIR}/foreman-fake-$$.calls` fake.sh:113; `/tmp/foreman-iter.bundle` in sandbox, `$BUNDLE_FILE` on host sandbox.sh:132-149 |
| FIFOs / named pipes | none in this area (plain pipes and files only) |
| Exit-code propagation | agent status via PIPESTATUS[0] -> `--exit-status` to the recorder; loop exit = FINAL_STATUS L:2194; `exec_collect` return 1 = stranded; `exec_prepare \|\| exit 1` L:1301 |
| `stop --now`: SIGINT to loop + descendants, grace `FOREMAN_STOP_GRACE` (5s), then `taskkill /F /T` or `kill -9` on descendants (never the loop), then waits up to 60s for it | control.sh:157-194, force :140 |
| Liveness: `kill -0` on the pid file | L:1143, control.sh:95 |
| `foreman order`: bare `claude ... </dev/null` in `$(...)`, no adapter, no timeout | order.sh:264 |

**Timeout / stall detection:** there is no wall-clock or idle watchdog on the agent. "Stall" here means "turn ended cleanly with uncommitted work" (CONTEXT.md), not "hung". `FOREMAN_COMMAND_TIMEOUT_MINUTES` only raises the agent's own Bash-tool cap and is quoted in the prompt (exec.sh:145, prompt.sh:218). A hung `claude` / `sbx exec` blocks the loop until Ctrl-C or `foreman stop --now`. The time budget (`MAX_MINUTES`) is checked only between iterations L:1703.

## 5. Control channel (control.sh + keys.sh)
- Medium is files in the control directory, not signals: `budget`, `live`, `iteration`, `run`, `pid`, `spent`, `foot`, `screen`, `activity`, `feed`, `stop` (seeded L:1154-1169; documented keys.sh:2-40). Writes are tmp + `mv -f` (keys.sh:88).
- Location: `<batch>/.foreman-run/` only if gitignored and no live pid there (L:1140-1152); otherwise a private mktemp dir that `foreman keys|stop` cannot reach (control.sh:90-98 needs the in-batch path).
- `foreman keys <batch> + - L` -> `foreman-keys.sh --apply` (control.sh:197). The loop reads `budget` only in `refresh_budget` (L:1692 before the gates; L:2095 at the footer). `live` is read by the stream filter via `--live-file` (L:1234).
- `foreman stop` (graceful) -> `keys.sh --stop` sets budget = current iteration (control.sh:203, keys.sh:145): the run finishes the turn, then pauses "iteration budget reached" (exit 10).
- `foreman stop --now`: writes the `stop` file first, SIGINT to the tree, grace kill (control.sh:157-181). The loop polls the file only after a turn ends (`check_stop_file` L:1275; called L:1509, 1439, 1790), so mid-turn interruption rests on the signal/kill, not the file.
- Interactive: the same reader started on a tty (L:1311-1325) takes + / - / L from the terminal and draws the status bar.

## 6. Git operations and state mutated
Host repo, read: `git rev-parse HEAD` (BASE_REF L:1710, HEAD_REF L:1804; also L:626, 1428, 1580, 1586, 1596), `git status --porcelain` (L:289, _common.sh:13,18), `git log -1 --format=%h`, `git check-ignore [-q --no-index]` (L:614, 928, 1140), `git status --short`.
Host repo, write: `git mv` + `git commit -- paths` for ticket rename L:439-446 and batch rename L:482-487 (undone if the commit fails); sandbox return path `git fetch $BUNDLE_FILE HEAD:refs/foreman/incoming`, `git merge --ff-only`, `git update-ref -d` (sandbox.sh:140-148). The agent (via prompt, not the loop) does the code commits, the ticket status flip and the progress.txt append (prompt.template.md:77-101; checkpoint prompts prompt.sh:34-110).
In the sandbox clone (`sbx exec`): `git fetch origin && reset --hard BASE && clean -qfd` (sandbox.sh:64), `merge-base --is-ancestor`, `rebase BASE` (:121), `bundle create` (:132), remote set-url (_sbx.sh:34).
Files: ticket .md (agent flips status; loop renames to `DONE_*`); batch dir rename; `order.md` (order.sh only); `progress.txt` (agent; tail inlined in prompt prompt.sh:257); telemetry `foreman-runs.jsonl` + `foreman-runs.log` (record.cjs + `log_append` L:230); `.foreman-stall-marker` (L:600-616); `.foreman-iter.bundle`; `.foreman-run/` ctl dir; ref `refs/foreman/incoming`. The loop writes nothing under `.scratch` except by renaming a batch or ticket that lives there.

## 7. Smells
- **The loop body is a 582-line top-level `while` (L:1508-2089)** with about 35 globals and ~14 `break`s, each hand-setting FINAL_STATUS + NEEDS_REASON + warn text. Testable only end to end through the fake adapter.
- **foreman-loop.sh is five programs**: arg dispatch, status renderer, dry-run renderer, preflight, run loop. L:641-1084 (~400 lines) is status/dry-run presentation inside the run script, each with a "facts for node" + "plain text" pair (L:672 / 716 / 774 / 987).
- **Duplicated terminal-state handling**: stranded L:1648 / 1891 / 1951; discarded L:1655 / 1970; limit pause L:1666 / 1854; salvaged counter bump L:1621-1626 vs 1959-1963; "show dirty + recovery note + exit 20" L:1676-1683 / 1731-1743 / 1989-1997 / 2003-2008.
- **"Stall" is defined three ways**: record.cjs:282 (`dirty && !committed && !flipped && !error`, telemetry only; not among the verdict keys :385-403), loop L:1931 (`agent_status=0 && !is_error && dirty && !flipped`, HEAD may have moved), CONTEXT.md. The loop never reads the recorder's `stalled` / `progressed`; it re-derives from HEAD_REF vs BASE_REF (L:2038).
- **Leaky seam**: exec.sh:12 says adapters read only FOREMAN_* and REPO_ROOT, but they use BUNDLE_FILE (_sbx.sh:177, sandbox.sh:131), RUN_CTL_DIR / STALL_MARKER_FILE / PROGRESS_FILE / FOREMAN_TOOL_DIR (fake.sh:142, 210, 222, 310) and FOREMAN_INVOKE. EXEC_DIRTY / EXEC_AGENT_HEAD are out-params via globals. L:1874 `case "$FOREMAN_EXEC" in sandbox|sandbox-mount` contradicts "nothing else holds a list of modes" (exec.sh:6); mode-specific login advice belongs in an adapter.
- **exec_run runs in a pipeline subshell**, so adapters cannot set state: fake.sh:110-122 keeps its call count in a PID-keyed temp file and relies on `$$` tricks for signals.
- **Sourced-as-script modules**: foreman-prompt.sh is top-level code re-run every iteration (L:1776), reads ~8 globals (FOREMAN_CONTINUATION, FOREMAN_STALL_CONTINUATION, FOREMAN_CONTEXT_RETRY, FOREMAN_REVIEW_BASE, TICKET_FILE, BASE_REF ...) and unsets its `_foreman_*` temps at the end (prompt.sh:316-318). `run_checkpoint_turn` sources it behind a `declare -F` guard (L:1402; the comment at L:1400 names the wrong function).
- **FOREMAN_CLAUDE_ARGS is mutated** for the checkpoint's `--max-turns` and restored (L:1432-1442); the bash<4.4 `${arr+"${arr[@]}"}` guard is repeated in three places (local.sh:23, _sbx.sh:129, L:1432).
- **Process-spawn churn**: 10 `grep` per iteration for verdict keys (L:1823-1832), an `awk` per float op (L:208-211), a node per scene, `git rev-parse HEAD` ~8x. Harmless at one turn per many minutes, noisy otherwise.
- **No agent timeout or hang recovery** (section 4). The interrupt handler only runs after the foreground pipeline ends (L:1266), so a SIGINT-ignoring agent holds the loop. `stop --now` kills local descendants; whether it reaches the in-sandbox `claude` depends on sbx (not verified).
- **Hidden temporal coupling in the ticket snapshot**: `_FOREMAN_TICKETS_HELD` (tickets.sh:231-252) must be released by hand before anything that renames; the loop does at L:1517, but every new caller must know.
- **foreman-order.sh bypasses the adapter** (order.sh:264: raw `claude`, own spinner/trap/temp file, own error parse): `foreman order` ignores sandbox / permission-mode / stream settings and is a second place that knows the claude CLI flags.
- **Control directory fallback is silent**: if `.foreman-run/` is not gitignored the keys/stop channel is unreachable (L:1153 vs control.sh:96); the only signal is a later error message.
- **Marker semantics are subtle**: written before every turn, removed after, rewritten on pause / failed stall / failed review (L:1786, 1841-1848, 1661, 1989); effective only when gitignored (L:614); correctness depends on HEAD + sandbox-name + ticket equality (L:622-628) across 6 call sites.
- `trap - INT TERM` before the footer (L:2094): Ctrl-C during the footer or `mark_batch_done_on_disk` kills the shell with no bookkeeping.
