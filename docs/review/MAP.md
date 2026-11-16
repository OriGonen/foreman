# Foreman map

Stitched from `map/*.md` (written by mapping agents on 2026-11-16). Judgments are in `ARCHITECTURE.md`.

## Test baseline (Windows 11, Git Bash, before any change)

- `cd gui && node --test`: 463 tests, 462 pass, 1 skipped, 3.5 s.
- `bash test/smoke.sh [substring]`: 2535 assertions pass, 66 fail (15 of 248 cases), 16m30s.
- `bash test/smoke-json.sh [substring]`: 684 pass, 35 fail, ~26 min (run concurrently with smoke.sh).
- The failures are pre-existing and platform-related (Windows path forms, Git Bash `ps` without `-o`, PATH-stripping cases, no `script` tool). "Green" for this review means: no new failures against this baseline. Details in section 5.


---

<!-- map/01-cli-config.md -->

# Map 01 — CLI entry, config, repo/path, UI, doctor, install

Scope: bin/foreman, bin/foreman.cmd, install.sh, lib/foreman-{commands,config,init,keys,credentials,legacy,doctor,repo,ui,gui}.sh, lib/foreman.conf.template. Domain vocabulary from CONTEXT.md (Batch, Ticket, Run, Iteration, Turn, Landed/Progressed/Stalled, Stall marker, Control directory, Free action, Show/Scene/Tier, Adapter, Sandbox/Clone) and ADR 0001-0004 (checkpoint turn; in-flight marker + review turn; palette over theme; Electron app over same CLI).

## 1. Entry points and CLI surface

- `bin/foreman:27` `set -uo pipefail` (no -e). `FOREMAN_HOME` = parent of script dir, backslash-normalised for foreman.cmd (`:34-37`), exported. `FOREMAN_INVOKE` defaults `foreman`, exported (`:41`). `LIB=$FOREMAN_HOME/lib`.
- Dispatcher is one `case "$cmd"` (`bin/foreman:141-162`); no argument parsing here, everything after the subcommand is passed through untouched. Default cmd is `help`.

| subcommand | dispatch (bin/foreman) | handler | flags (where parsed) |
|---|---|---|---|
| init | :142 exec bash | foreman-init.sh | `<batch> --force --no-order --no-commands` (init.sh:50-60) |
| order | :143 | foreman-order.sh (not my area) | |
| commands | :144 | foreman-commands.sh | `<batch>` only (commands.sh:33-41) |
| run | :145 | foreman-loop.sh | `[batch] [n\|--unlimited] [--live] [--adopt-dirty]` (loop, other map) |
| status | :146 | foreman-loop.sh `... --status` (flag APPENDED) | `--json [--all]` per foreman-repo.sh:132 comment |
| dry-run | :147 | foreman-loop.sh `... --dry-run` | |
| next | :148 | foreman-next.sh | `--list --count --all --unordered` |
| report | :149 fn `report()` :108 | foreman-report.cjs via `exec node` | `--by-ticket --failures` |
| doctor | :150 | foreman-doctor.sh | `--fix --json` (doctor.sh:38-46) |
| gui | :151 | foreman-gui.sh | `[<dir>] -h` (gui.sh:29-36) |
| keys, stop | :152 | foreman-control.sh `$cmd "$@"` | `keys <batch> +-L...`, `stop [--now] [batch]` |
| convert | :153 fn `convert()` :125 | foreman-convert.cjs | `[<project>] --dry-run` |
| help/-h/--help | :154 | `usage_show` (sunrise/intro) then `usage` | |
| version/-V | :155 | `version()` :90, rev from `git rev-parse --short HEAD` in FOREMAN_HOME | |

- Help text IS the header comment (`usage()` awk, bin/foreman:47-50); it does NOT list `gui`, `keys`, `stop` (header :6-16) although they dispatch. Header says "lines 2-25" (:45) but runs to :26.
- `bin/foreman.cmd`: finds Git for Windows bash (ProgramFiles, ProgramW6432, x86, LOCALAPPDATA, then `where git`) deliberately avoiding WSL `bash` (:10-19); runs `bash bin/foreman %*` (:27).
- install.sh writes shims `<dir>/foreman` (`exec bash $HOME/bin/foreman`, :453-457) and `<dir>/foreman.cmd` (CRLF, calls bin\foreman.cmd, :475-480). Flags (install.sh:63-75): `--to <dir> --force --no-skill --gui --no-gui --uninstall -h`.
- Scripts are also directly runnable (`bash lib/foreman-loop.sh`): config falls back `FOREMAN_INVOKE=$FOREMAN_HOME/bin/foreman` (config.sh:44).
- Terminal-only wrappers in bin/foreman: `usage_show` (intro `--play`, exit 130/4 handling :71-82), `version` (:90), `report`/`convert` set `FOREMAN_DRAW_TIER/COLS` then `exec node`. Min-width constants: help 64, intro 66, version 72, report 84, convert 86 (init 64 in init.sh:98, doctor 80 in doctor.sh:154) — each "held by a smoke case" against the renderer.

## 2. Modules

- **foreman-repo.sh** (sourced by config, init, doctor, gui; sources foreman-legacy.sh :23). Path layer for Windows/MSYS. `_foreman_basename/_dirname/_trim_seps` (fork-free), `foreman_repo_root VAR` (:71, git toplevel normalised via cd+pwd), `foreman_batch_relpath VAR GIVEN ROOT` (:92; git `--show-prefix` from inside the batch; rc 1 not-a-dir, 2 outside repo), `foreman_find_batches [root] [all]` (:136; `find` for foreman.conf/ralph.conf, prunes node_modules, .git, .claude/worktrees, .svelte-kit, and DONE_* dirs; also used by foreman-report.cjs), `foreman_mixed_path` (:152 cygpath -m), `foreman_app_installed` (:164, `gui/node_modules/electron` exists), `foreman_app_in_sync` (:172, lockfile mtime), globals `FOREMAN_RUN_IGNORE='**/.foreman-run/'`, `FOREMAN_RUN_IGNORE_BLOCK`, `_FOREMAN_REPO_SH_DIR`, `_foreman_seps`.
- **foreman-config.sh** (sourced by loop, next, order, commands, control; NOT doctor). Resolves one batch into every variable. Order: derive FOREMAN_TOOL_DIR/HOME/INVOKE (:37-44) -> source repo.sh -> `foreman_repo_root REPO_ROOT`, `cd` to it (:61, changes caller's cwd) -> legacy env knobs -> choose batch (`FOREMAN_BATCH` or the unique `foreman_find_batches`, :70-89) -> relpath -> snapshot env, source conf, restore env -> defaults -> validate -> `export FOREMAN_BATCH=$BATCH_DIR`. Helpers defined into caller: `_foreman_path` (:269), `foreman_issues_dirs` (:289), `foreman_issues_hint` (:305), `_foreman_bre_to_ere` (:200; BRE->ERE so tickets read in-process, returns 1 when untranslatable and caller falls back to grep). Sources foreman-exec.sh at :417 (adapters; `foreman_exec_is_mode/modes/default_permission_mode`). Writes: REPO_ROOT, BATCH_DIR, BATCH_NAME, ORDER_FILE, PROGRESS_FILE, PROMPT_EXTRA_FILE, RUN_JSONL, RUN_LOG, BUNDLE_FILE, STALL_MARKER_FILE, FOREMAN_CONF, FOREMAN_DONE_PATTERN, FOREMAN_HUMAN_PATTERN, `_FOREMAN_DONE_ERE`, `_FOREMAN_HUMAN_ERE`, all FOREMAN_* knobs, exported FOREMAN_BATCH. Always exits via `return 1 2>/dev/null || exit 1` (works sourced or run).
- **foreman-commands.sh** (script). `foreman commands <batch>`: runs `claude --print -p "/foreman-conf-commands <batch>"` headless (effort high, `acceptEdits`, model `FOREMAN_ORDERING_MODEL:-FOREMAN_MODEL`; :94-106) to fill the 5 SLOTS (:53). Sets `FOREMAN_BATCH`, sources config.sh, then uses `say_tag/warn_tag` — these come from foreman-ui.sh, which it never sources directly: it relies on config.sh -> foreman-exec.sh having loaded ui (implicit dependency). Skill-installed check :85. After the call `bash -n "$CONF"` (:121). Uses `foreman-claude-reply.cjs` to parse the JSON reply (:109). `MSYS_NO_PATHCONV=1` guard :104. Exits 0 (soft) when claude/skill missing.
- **foreman-init.sh** (script). Scaffolds `<batch>/foreman.conf` (copy of template), `order.md` (tickets from `foreman-next.sh <batch> --unordered`, :141), `progress.txt`, and appends `**/.foreman-run/` to repo `.gitignore` only if the app is installed (:244). Then chains `foreman-commands.sh` (if conf written, :266) and `foreman-order.sh` (if order written, :273-285). Does NOT source config.sh; sources repo.sh + ui.sh. Has its own show/plain duality: `say`/`fact`/`draw_or_plain` buffer text and facts for foreman-draw.cjs (`init`, `init-done` scenes). Globals: `FORCE NO_ORDER NO_COMMANDS BATCH_INPUT REPO_ROOT BATCH_DIR SHOW SHOW_TIER SHOW_COLS FACTS PLAIN tickets[] FILE_STATE wrote_any conf_written order_written`. Reads env `FOREMAN_ORDER_RESULT` (hand-off to order.sh, :278) .
- **foreman-doctor.sh** (script). Deliberately does NOT source config.sh (:48-51) — reads confs as text via `_conf_value` (:227, grep+sed, last assignment wins, quotes stripped). Sources repo.sh, exec.sh (for `foreman_exec_required_tool`, `foreman_exec_modes`), ui.sh (optional). Checks: git/node/awk, bash>=4, per-batch runner (sbx/claude), desktop app sync, skill copy drift (`diff -rq` vs `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/*`, marker `.foreman-installed-from`), `.gitignore` 4(+1) patterns, `.gitattributes` `foreman.conf text eol=lf` only when autocrlf/text=auto, batches (`foreman-next.sh <b> --count`), local-mode "can the agent commit" (:446), legacy ralph leftovers. Records facts (`_fact` for renderer, `_jfact` for JSON) then renders: live stream to `foreman-draw.cjs doctor --stream` on fd 3 (needs bash>=4.4, :158-165), `--plain`, or `_doctor_lines`; `--json` pipes facts to foreman-json.cjs and ALWAYS exits 0 (:553). `--fix` only appends to .gitignore/.gitattributes. Exit 1 if problems. Also reports credential presence via foreman-credentials.sh (:545).
- **foreman-ui.sh** (sourced by loop, exec.sh, keys, init, doctor, gui(no), install.sh; load-guard `_FOREMAN_UI_LOADED`). Fork-free output vocabulary: `say_event`, `say_rule`, `say_frame`, `warn_note`, `warn_preflight`, `say_tag`, `warn_tag`, `ui_key_echo`, colour `ui_color_tier/ui_color_on/ui_paint` (5 styles: ok warn error accent muted; tiers none/16/256/24), show decision `ui_show FD [VAR]`, `ui_cols`, `ui_rows`, status-bar escape helpers `ui_bar_rows/draw/resized/close`. Palette table `_UI_PALETTE` (:96; foreman-draw.cjs reads the same assignment textually). Reads `FOREMAN_COLOR`, `FOREMAN_SHOW`, `NO_COLOR`, `TERM`, `COLORTERM`, `WT_SESSION`, `CI`, `COLUMNS`, `LINES`.
- **foreman-keys.sh** (script, backgrounded by loop; sources ui.sh). Modes: `<ctl-dir> <loop-pid>` key reader loop; `--apply <keys> <ctl>`; `--stop <ctl>`; `--text <ctl> [cols]`. Keys `+ = - _ L l`. Implements the control-directory protocol (see section 4) and the pinned status bar/foot. Functions `keys_apply`, `keys_stop`, `keys_bar_text`, `keys_foot_text`, `keys_ticker_text`, `repaint`, `on_resize`, `_keys_write` (tmp+mv atomic). Changes locale (`LC_ALL=C.UTF-8`) at :65 to make `${#}` count chars. Builtins-only idle loop (MSYS fork cost).
- **foreman-credentials.sh** (sourced by lib/exec/_sbx.sh:13 and doctor:545). `foreman_credentials_file`, `foreman_credential NAME` (env wins if non-empty, else data-only parse of the file; `RALPH_` alias), `foreman_mask`. Global `_FOREMAN_CREDENTIALS_PATH`. Never exports/sources the file.
- **foreman-legacy.sh** (sourced by repo.sh). ralph->foreman rename shim: `FOREMAN_LEGACY_KNOBS` list (:21), `foreman_legacy_knobs WHERE` (copies RALPH_X -> FOREMAN_X, unsets old, warns once via exported flag `_FOREMAN_LEGACY_SAID_*`), `foreman_legacy_conf_path` (ralph.conf fallback), `foreman_legacy_batch_files` (MOVES ralph-runs.*, .ralph-stall-marker; DELETES .ralph-iter.bundle). Delete the file + `legacy:` greps to remove.
- **foreman-gui.sh** (script). `foreman gui [<dir>]`: finds `gui/node_modules/electron/dist/electron(.exe)` (:46-57), offers `install.sh --gui` on a tty, then launches detached (`nohup setsid`, unset ELECTRON_RUN_AS_NODE) with args `<gui dir> <repo toplevel>` as mixed paths (:94-101). Own `TOOLKIT` var (:44) duplicates FOREMAN_HOME.
- **install.sh** (script). Writes shims, copies `skills/<n>/` to `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/<n>/` with marker `.foreman-installed-from`; optional app (`npm ci` in gui/, Start-menu `Foreman.lnk` via powershell.exe+WScript.Shell, env-passed values); legacy ralph cleanup (:137); WSL warning (:87); picks target dir via HKCU PATH registry then `$PATH` (`~/bin`, `~/.local/bin`). Contains a 12-row hand-embedded pixel header (:271-303). `--uninstall` removes shims, marked skills, app, shortcut.

## 3. Config

- Format: `<batch>/foreman.conf`, plain bash sourced (config.sh:137), template `lib/foreman.conf.template` (copied verbatim by init; all keys commented except `FOREMAN_CLAUDE_ARGS`, template:68). Fallback `ralph.conf` (legacy.sh:75). CRLF is stripped via a temp copy (config.sh:128-133); `.gitattributes` pins `foreman.conf text eol=lf`.
- Precedence: env > conf > defaults (config.sh:13-16). Mechanism (:115-148): snapshot every currently-set `FOREMAN_*` variable (`compgen -v FOREMAN_`) into `_FOREMAN_FROM_ENV`, source the conf, write the snapshot back with `printf -v`. So "environment" = anything FOREMAN_* already set when config.sh is entered; relies on "no foreman script sets one before sourcing" (:112).
- Defaults/validation (config.sh): FOREMAN_EXEC=sandbox (checked against lib/exec/*, :421); FOREMAN_SANDBOX=`foreman-<repo basename>`; SANDBOX_SETUP/PROBE empty; SKIP_SANDBOX_PROBE=0; MODEL=`claude-sonnet-5-5`; EFFORT=high; PERMISSION_MODE = per-adapter default (`bypassPermissions` sandbox modes, `acceptEdits` local; :430); CLAUDE_ARGS=() (template sets `--allowed-tools "Bash(git add:*)" "Bash(git commit:*)"`); CHECK/TEST/FOCUSED_TEST_CMD, TDD_SKILL, REVIEW_SKILL empty; MAX_COST_USD=0, MAX_MINUTES=0 (0=unlimited; MAX_COST_USD NOT validated numeric); TICKET_ATTEMPTS=2, MAX_CONTINUATIONS=5, PROGRESS_TAIL_BYTES=6000, CONTEXT_BUDGET_TOKENS=200000 (all `^[0-9]+$`, :451); COMMAND_TIMEOUT_MINUTES=60 (`^[1-9][0-9]*$`); ALLOW_DIRTY=0; STREAM=0; COLOR=auto (auto|always|never|16|256|truecolor); SHOW=auto (auto|always|never); STATUS_LINE=`**Status:**`; DONE_WORD=implemented; DONE_PATTERN derived BRE (`implemented|done` when default word); HUMAN_WORD=`ready-for-human` (`-` expansion: empty disables); HUMAN_PATTERN derived; DONE_PREFIX=`DONE_` (empty disables); ORDER_FILE=order.md; ISSUES_DIRS=issues; ISSUES_EXCLUDE="README.md spec.md order.md"; PROGRESS_FILE=progress.txt; PROMPT_EXTRA=prompt-extra.md; RUN_JSONL=foreman-runs.jsonl; RUN_LOG=foreman-runs.log; BUNDLE_FILE=.foreman-iter.bundle; BATCH_NAME=basename (override FOREMAN_BATCH_NAME); ORDERING_MODEL (no default, read in order/commands).
- Path knobs accept absolute | repo-relative-if-exists | batch-relative (`_foreman_path` :269). `FOREMAN_ISSUES_DIRS` entries resolve batch-first then repo (:289).
- Not in template but real: ALLOW_DIRTY, SKIP_SANDBOX_PROBE, RUN_JSONL/RUN_LOG/BUNDLE_FILE, BATCH_NAME, CREDENTIALS_FILE, DOCKER_USERNAME/PAT, FOREMAN_INTRO, FOREMAN_STOP_GRACE/WAIT, plus test-only FOREMAN_FAKE_*. Doctor/legacy treat the template's list + some extras as the legacy RALPH set (legacy.sh:21).
- Compat aliasing: RALPH_* env and conf names accepted with a one-time warning (legacy.sh:47). Env knobs from RALPH run BEFORE the snapshot so they count as "environment".

## 4. Persisted state

- Per batch (`<batch>/`): `foreman.conf` (init writes; commands/agent edit), `order.md` (init + order.sh; next.sh reads ORDER:BEGIN/END block), `progress.txt` (init header; agent appends; loop attaches tail), `prompt-extra.md` (user), `foreman-runs.jsonl` / `foreman-runs.log` (loop appends; report.cjs reads; "never read back by the loop", config.sh:339), `.foreman-iter.bundle` (sandbox adapter, one iteration only), `.foreman-stall-marker` (loop writes before every turn, removes when handled; kept after interruption; read by next run's review turn), ticket files `*.md` under `issues/` (agent flips Status; loop renames to `DONE_<name>`; batch dir itself renamed `DONE_<batch>` when finished).
- Control directory (loop creates, keys/control/app read+write, removed at end): `<batch>/.foreman-run/` when repo ignores `**/.foreman-run/`, else a temp dir (loop.sh:1120-1139). Files: `budget`, `live`, `iteration`, `screen`, `activity`, `foot`, `spent`, `pid`, `run`, `feed`, plus `stop` (control.sh) and `out` (survives). Atomic tmp+mv via `_keys_write` (keys.sh:88).
- Repo: `.gitignore` (+4 patterns, +`**/.foreman-run/` if app installed) and `.gitattributes` appended by `doctor --fix` / init.
- User/machine: credentials `~/.config/foreman/env` (or `FOREMAN_CREDENTIALS_FILE`; legacy `~/.config/ralph/env`); skills `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/{foreman-human-followup-tickets,foreman-conf-commands}/` + marker; shims in `~/bin` or `--to`; `gui/node_modules`; `%APPDATA%/.../Start Menu/Programs/Foreman.lnk`; `foreman-order.XXXXXX` temp in `$TMPDIR` for init facts (init.sh:274); conf-LF temp (config.sh:129). The toolkit itself writes nothing in `$FOREMAN_HOME` (except `gui/node_modules` via install). No lock files anywhere; concurrency guarded only by pid file + dirty-tree check.
- Sandbox state lives in `sbx` (named `foreman-<repo>`), outside Foreman's files.

## 5. External dependencies

- bash 4+ (assoc arrays, `compgen -v`, `declare -gA`, `printf %(%s)T`, `${var,,}`; 4.4 for doctor's live show). Git for Windows bash is the target; WSL bash explicitly avoided (foreman.cmd, install.sh:87).
- git (rev-parse toplevel/prefix, bundle in sandbox), node (all `.cjs`: draw, report, convert, json, stream, claude-reply, auth-patterns, record; also the optional Electron app; no node version pinned/checked), awk, sed, grep (`-U`), find, sort, tr, diff, mktemp, stty, cygpath (optional), reg/powershell.exe (install only), npm (app only), `setsid`/`nohup`.
- `claude` CLI (`--print --output-format json --model --effort --permission-mode --allowed-tools`); `sbx` (default exec mode; required tool asked from adapter via `foreman_exec_required_tool`); Docker credentials for sbx via credentials file.
- Env: FOREMAN_* knobs, `CLAUDE_CONFIG_DIR`, `HOME`, `APPDATA`, `COLUMNS/LINES`, `NO_COLOR`, `CI`, `TERM`, `COLORTERM`, `WT_SESSION`, `OSTYPE`, `TMPDIR`, `WSL_DISTRO_NAME`, `MSYS_NO_PATHCONV`, `MSYS2_ARG_CONV_EXCL`, `ELECTRON_RUN_AS_NODE`, `FOREMAN_PROC_VERSION` (test hook).

## 6. Smells

- Stale/wrong docs: config.sh:3 says sourced by loop/next/doctor but doctor explicitly does not, and order/commands/control also source it; `foreman setup` named in credentials.sh:2 does not exist; bin/foreman usage omits gui/keys/stop (:6-16) and "lines 2-25" (:45) is off by one.
- Help text derived from the script's own header comment via awk (bin/foreman:48, and again in init:55, commands:30, doctor:42, install:71) — five copies of the same awk one-liner; `foreman commands --help` prints `$0`, which is wrong when run through `exec bash`.
- Dispatcher quirk: `status` and `dry-run` APPEND `--status`/`--dry-run` after the user's args (bin/foreman:146-147), so anything after `--` or a literal batch named like a flag is mis-parsed; `foreman status --json` relies on loop.sh accepting it.
- `config.sh` is a ~460-line sourced script with side effects: `cd`s the caller to repo root (:61), `foreman_legacy_batch_files` mv/rm's files on every config load (:350, legacy.sh:95-108), and `exit`s the caller on error. A pure "read config" call mutates the filesystem.
- Env-wins mechanism snapshots *all* FOREMAN_* vars including internals set earlier (FOREMAN_HOME, TOOL_DIR, INVOKE, BATCH) and arrays (`FOREMAN_CLAUDE_ARGS` restored as scalar, config.sh:115-148); relies on an unenforced convention (:112). An env-set empty value also overrides the conf.
- Arbitrary-bash conf: foreman.conf is `source`d (config.sh:137), executed with the user's rights in every command incl. `status`; doctor parses it as text (doctor.sh:227) so the two readers can disagree (quoting, multi-line arrays, `export`, RALPH_ in conf names).
- Duplicated batch discovery: doctor.sh:201-204 re-implements `foreman_find_batches` (repo.sh:136) without the DONE_ prune, so doctor lists finished batches that config/report skip; also duplicated `GITIGNORE_BLOCK` patterns list in doctor (:322-342, :354) vs repo.sh constants.
- Duplicated knobs lists: legacy knob list (legacy.sh:21), template, config defaults and doctor's `_conf_value` are four hand-maintained lists; template omits several real knobs (see section 3). Duplicated TOOLKIT/FOREMAN_HOME/FOREMAN_TOOL_DIR derivation in every script (`${BASH_SOURCE[0]%/*}` boilerplate in 8 files).
- Implicit dependency: commands.sh uses `say_tag/warn_tag` without sourcing ui.sh (relies on config.sh->exec.sh); init.sh calls `foreman-next.sh` via a subprocess just to list tickets (init.sh:141) and runs `foreman-commands.sh`/`foreman-order.sh` as child bash with different resolution rules than config.sh.
- Magic-number coupling between shell and renderer: min widths (64/66/72/84/86/80) duplicated in bin/foreman, init.sh, doctor.sh, install.sh header art and foreman-draw.cjs, held only by smoke cases; palette textually parsed from ui.sh by the renderer; install.sh embeds a 12-row pixel header copied from `.scratch/gui/designs/10-install-wizard.html` (:271-303).
- Show/plain duality implemented three different ways (init `say/fact/draw_or_plain`, doctor `_fact/_jfact` + three render paths, bin/foreman per-scene wrappers `report/convert/version/usage_show` that are near-identical copies, :108-134).
- keys.sh mixes a protocol definition (control-dir files documented in the header :15-44, no schema file), UI rendering and key handling; the same files are read/written by loop.sh, control.sh, stream.cjs and the Electron app (gui/*.cjs) with no single owner; a global locale hack (`LC_ALL`) at load (:65-72).
- `doctor --json` always exits 0 and `--fix` in JSON mode appends silently; JSON path still sources credentials after the fact (:545) — fine but credential reading lives in a diagnostic.
- `MAX_COST_USD` and `FOREMAN_MAX_MINUTES` semantics: only MINUTES is checked as integer; COST (decimal) unchecked at config time. Tool-dir finding in foreman-config assumes `FOREMAN_HOME` env preset wins over derived (:39), so a stale exported FOREMAN_HOME can point to a different checkout than `FOREMAN_TOOL_DIR`.
- install.sh: 540 lines mixing PATH discovery (registry), shims, skills, npm/electron install, Start-menu COM shortcut, ASCII art and legacy cleanup; no tests of partial failure besides `APP_FAILED`.

---

<!-- map/02-loop-exec.md -->

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

---

<!-- map/03-node-helpers.md -->

# Map 03 - Node helpers (lib/*.cjs)

No package.json for lib (none at repo root either; only gui/package.json, which depends solely on electron 45.3.1). All lib modules use node builtins only, CommonJS only. Features needing a recent node: `Object.hasOwn` (16.9+), `??`/`?.`, regex lookbehind (convert.cjs WORD), `node:` specifiers. No `engines` pin; doctor only checks `command -v node` (foreman-doctor.sh:184).
Top-level `return` is used as a guard in report.cjs:91-94 and stream.cjs:69-72 (legal in CJS, but blocks ESM/lint use).

## 1. Modules (responsibility / in / out / bash caller)

**foreman-stream.cjs (339)** - filter between agent and recorder. In: agent stdout on stdin; argv `--live | --live-file P | --activity-file P | --show 16|256|24 | --feed-file P | --color`. Out: stdout = ONLY the final `type:"result"` JSON line (stream-json mode) or a byte-for-byte pass-through (plain mode, :69-72); stderr = live ticker or `│ 00:41  edit  file` lines; files: `activity` (`<epoch> <label>`, tmp+rename, :128), `feed` (`MM:SS · Tool arg`, append, :158), reads `live` (`1` = on, :219). Exit 0 always. Callers: foreman-loop.sh:1437 (checkpoint turn) and :1788 (main turn): `exec_run ... </dev/null | node foreman-stream.cjs ${STREAM_ARGS[@]} > $PAYLOAD_FILE`; args built at foreman-loop.sh:1228-1251. The agent is asked for stream-json by foreman-exec.sh:127-133 (`--output-format stream-json --verbose` vs `json`). Only Write/Edit/MultiEdit/NotebookEdit/Bash calls surface (SIGNIFICANT map, :85); tool input beyond one arg is never printed (privacy). Lazily requires foreman-draw.cjs `encode` for --show (:148).

**foreman-record.cjs (412)** - one-iteration recorder. In: raw payload on stdin; argv `--jsonl --log --verdict` (required, exit 2 else, :49-52) plus `--run-id --iteration --ticket --batch --base-ref --head-ref --started-at --exit-status --tree-dirty --status-flipped --kind --model --quiet`. Out: appends 1 JSON line to foreman-runs.jsonl (:325); appends a text block to foreman-runs.log (:371); overwrites the verdict file of `key=value` lines (:379-404; `safe()` whitelists `[A-Za-z0-9._:+-]` so bash never evals model text); prints a `usage:` line unless `--quiet`. Callers: foreman-loop.sh:1453 (`--kind checkpoint`) and :1813 (iteration); verdict read back by `verdict_get` (foreman-loop.sh:213, :1823-1831: limit_hit, limit_reset, transient, parse_ok, context_exhausted, auth_failed, permission_denied, is_error; cost/tokens via accumulate_usage). Classification ladder: limit (:167) > context_exhausted (:~185) > auth (:207, shared list) > transient (:227); permission_denied is gated on outcome rather than failure (:~245); progressed/stalled derived (:~268-281).

**foreman-json.cjs (586)** - builds `--json` objects. In: `key<TAB>value` facts on stdin; argv[2] = `status | status-all | dry-run | doctor` (:572-585). Out: one JSON line on stdout; exit 2 on bad mode. Reads ticket files, foreman-runs.jsonl, foreman-runs.log and `<batch>/.foreman-run/*` through an injectable `io` (:284). Callers: foreman-loop.sh:830 (status), :962 and :1038 (dry-run), :185 (status-all, which re-invokes foreman-loop.sh per batch at :178-184), foreman-doctor.sh:551 (doctor). Exports builders for tests. Requires `outcomeOf` from foreman-report.cjs (:75).

**foreman-report.cjs (545)** - `foreman report`. Straight-line script. In: argv `[batch] --by-ticket|--failures|--json|--run ID|--jsonl F`; env FOREMAN_DRAW_TIER/COLS, FOREMAN_INVOKE. Reads foreman-runs.jsonl (legacy ralph-runs.jsonl fallback). Out: text, the drawn `report` scene, or the `--json` object (:487-526). Exit 1 on no log / no records / unknown run. Caller: bin/foreman:116 `exec node` (dispatch :149), after bin/foreman:109-115 sets the two env vars from ui_show/ui_cols. Shells out to `git rev-parse` (:128) and to bash `foreman_find_batches` (:139-156) to infer the batch. When `require`d it exports only `isProgressed/isStalled/isCheckpoint/outcomeOf` (:56-92).

**foreman-convert.cjs (361)** - ralph to foreman migrator; the only lib module that WRITES user files (text rewrite through a latin1 round-trip :215/:225, `git mv`/rename :232, copies ~/.config/ralph/env :318). argv `[project] --dry-run --allow-dirty --help` (help text = the file's leading `//` block, :40-46). Exit 1 on bad usage / non-git / dirty tree / toolkit itself. Caller: bin/foreman:133 (dispatch :153), same env protocol as report. With the picture on, output is buffered in `held` and flushed on process 'exit' (:100-103).

**foreman-claude-reply.cjs (30)** - In: one `claude --print --output-format json` reply on stdin. Out: exactly 4 lines: is_error 0/1, cost (4dp or empty), message (<=300 chars, one line), auth_failure 0/1. Non-JSON input falls back to its last 5 lines. Callers: foreman-order.sh:273, foreman-commands.sh:110 (`<<< "$RESPONSE"`).

**foreman-auth-patterns.cjs (16)** - array of lowercase login-failure substrings; required by record.cjs:207 and claude-reply.cjs:12. **foreman-strip-ansi.cjs (21)** - OSC/CSI/charset/2-char ESC stripper; required by record.cjs:38 and stream.cjs:53. Both pure, no bash caller.

**foreman-draw.cjs (2440)** - terminal renderer; structure in section 3. Bash callers (all `2>/dev/null`, stdout+exit code captured, plain-text fallback on non-zero): bin/foreman:72 (intro --play), :82 (help), :96 (version); foreman-loop.sh:331 (run), :820 (status), :1029 (dryrun); foreman-next.sh:103; foreman-order.sh:197 (`order_draw`: order-head/order); foreman-init.sh:123 (init/init-done); foreman-doctor.sh:165 (`--stream`, facts fed through fd 3 process substitution) and :567 (`--plain`). Required in-process by report.cjs:213, convert.cjs:107, stream.cjs:148.

## 2. Formats across the bash/node boundary

- **stream-json from agent** (`claude --output-format stream-json --verbose`, one object per line): no schema in-repo; example producer is exec/fake.sh:34; parsed only in stream.cjs:280-318 (`type:"result"` re-emitted verbatim; `type:"assistant"` -> `message.content[]` blocks of `tool_use{name,input}`). Non-JSON lines (sbx banner) are dropped but kept in a 40-line/8 KB tail (:265-278), emitted only if no result was ever seen (:328-338).
- **`--output-format json` payload** (one result object): parsed in record.cjs:54-112 (every `{` line with `type:"result"` is merged: usage/num_turns/duration summed, cost from the last, any is_error wins; fallback parses the whole text from the first `^{`) and in claude-reply.cjs. Fields read: is_error, result, total_cost_usd, usage.*, num_turns, duration_ms, duration_api_ms, session_id, subtype, terminal_reason.
- **Run record** (foreman-runs.jsonl, written record.cjs:284-323): run_id, iteration, kind, ticket, batch, started_at, finished_at, base_ref, head_ref, committed, status_flipped, tree_dirty, exit_status, parse_ok, result_count, is_error, limit_hit, limit_reset, transient_error, context_exhausted, auth_failed, permission_denied, progressed, stalled, subtype, session_id, num_turns, duration_ms, duration_api_ms, cost_usd, tokens{input,output,cache_read,cache_creation}, model, reply. Readers: report.cjs:239, json.cjs:180 (`readSpend`). Append-only telemetry; the loop never reads it back.
- **Verdict file** (`key=value`, record.cjs:381-404): node writes, bash `verdict_get` (foreman-loop.sh:213) reads. Verdict key `transient` vs record key `transient_error`.
- **Run-log control lines** (`# run ID started`, `# ---- run ID finished`, then `# complete | # paused: R | # stopped: waiting on a human - T | # stopped: needs a human`, `# reason: R`): written by foreman-loop.sh, parsed only in json.cjs:238-266 (-> end word + exit 0/10/30/20).
- **Facts** (`key<TAB>value`, repeated key = list): produced by bash (`*_facts` functions foreman-loop.sh:713-770, doctor `_jfacts`, init/order/next). TWO different parsers: draw.cjs:2225 (null-prototype object, repeats become arrays) and json.cjs:84 (typed switch for ticket/warning/until/done/total/humans, rest strings); json prompt/doctor values use `\\ \n \t \r` escapes undone by `unescapeFact` (json.cjs:386).
- **`--json` schema**: every object has `foreman_json: 1` + `command`. status (json.cjs:327-378), status-all (:459), dry-run (:397), doctor (:512), report (report.cjs:487-526; literal `1` hardcoded separately from json.cjs:78). GUI checks the version at gui/foreman.cjs:92.
- **Control dir** `<batch>/.foreman-run/{pid,run,iteration,budget,live,activity,feed,spent}`: bash writes most; stream.cjs writes activity+feed and reads live; json.cjs:301 `readRun` reads pid/run/iteration/budget/live; gui/live.cjs reads activity/feed directly.
- **Palette**: lives in bash `_UI_PALETTE` (foreman-ui.sh), scraped by regex at runtime in draw.cjs:139-158.

## 3. foreman-draw.cjs structure (line ranges)

1-134 header contract + scene catalogue (comment only) | 135-199 palette load/resolve/nearest | 200-257 `sgr`/`encode` (rows of runs -> ANSI at tier 16/256/24, optional erase) | 258-316 `halfBlocks` | 317-398 figure/sun/sky sprites | 399-598 intro film (INTRO frames, hammer, sparks, `introPixels`) | 599-676 mark + helpers | 677-799 init/init-done/order figures | 800-828 version | 829-940 dome + status | 941-1087 dry-run | 1088-1170 run | 1171-1270 order/stake | 1271-1367 next | 1368-1521 report | 1522-1715 convert | 1716-2177 doctor (box :1828, inspector sprite :1891-2040, `inspectorStep` :2069, `playDoctor` :2081) | 2178-2220 SCENES table `{min, frames, rows}` | 2221-2260 `parseFacts`/`draw`/`drawFrames` | 2262-2341 `play` | 2342-2430 CLI `main` | 2432-2440 exports.
State: module-level only the `defaultPalette` cache (:160) plus constants; scene code is pure (facts -> rows -> string). Stateful pieces are the two Promise closures `play` (:2278: drawn index, timer, raw mode) and `playDoctor` (:2081: text/partial buffers, t, height, ticks, still/ended flags).
Input: (a) facts via `fs.readFileSync(0)` unless stdin is a TTY (:2420); (b) `--play`: raw-mode keypress skips to last frame, Ctrl-C byte 0x03 = interrupted (exit 130), plus SIGINT/TERM/HUP listeners (:2262-2305); (c) `doctor --stream`: facts arrive line by line via stdin 'data', partial line held until `\n`, ends on 'end'/'error' (:2146-2162). Exit codes: 0, 2 bad args/unknown scene, 3 too narrow, 4 cannot play, 130 interrupted, 1 write failure.

## 4. Error-handling posture

- Rule: a node failure must cost only the picture. Bash discards stderr and falls back to plain text on non-zero; report/convert `drawn()` wrap in try/catch and return null (report.cjs:210-223, convert.cjs:105-115); stream.cjs `showLine` falls back to plain on draw failure (:148-156).
- Malformed input: record.cjs, report.cjs and json.cjs skip unparsable JSONL lines (report counts them as `unreadable`; json.readSpend silently `continue`s, :186). record with no parseable payload sets parse_ok=false, zero usage, and dumps up to 20 KB raw into the log (:365-368). stream.cjs drops non-JSON lines. claude-reply.cjs falls back to last 5 lines. Scenes are not defensive about missing facts beyond per-scene defaults.
- Missing files: json.cjs `readFile` returns null on any error (:286) and every reader tolerates null; report.cjs exits 1 with a message; stream.cjs treats a missing live file as off (:219-226) and swallows activity/feed write errors; record.cjs does NOT guard its `appendFileSync`/`writeFileSync` (throws -> non-zero -> loop `|| warn_note`, foreman-loop.sh:1458/1818).
- EPIPE: only draw.cjs sets `process.stdout.on('error', () => {})` (:2355, :2369, :2427). json.cjs, report.cjs, convert.cjs and record.cjs use bare `process.stdout.write`/`console.log` (`foreman report | head` can throw EPIPE). stream.cjs stdout goes to a file redirect, but its stderr writes are unguarded.
- Partial lines: stream.cjs buffers to `\n` and flushes a trailing unterminated line on 'end' (:320-336); playDoctor likewise. record.cjs reads all stdin at once (:54); bash hands it `printf '%s' "$result"` (trailing newlines already stripped by `$(cat)`, harmless).
- Windows: rename-over-open-file in stream.cjs:128-141 falls back to an in-place write; closed stdin handled in draw.cjs:2421.

## 5. Smells

- **Parsing + rendering + I/O mixed**: report.cjs and convert.cjs are top-level scripts (no main(), top-level `return`/`process.exit`) interleaving git/fs work, aggregation, text and picture building (report.cjs:96-545; convert.cjs:76-361). Only testable via subprocess; json.cjs reuses `outcomeOf` only because of the `require.main !== module` early-return hack (report.cjs:91).
- **Duplication within lib**: number coercion `finite`/`num`/`n` in json.cjs:167, record.cjs:89, report.cjs:255; ad-hoc argv parsers `arg()`/`valueOf`/`argAfter` in record.cjs:40, report.cjs:98, stream.cjs:55 (draw.cjs and convert.cjs have their own loops too); near-identical `drawn()` in report.cjs:210 and convert.cjs:105; slash-normalizer `show()` in report.cjs:118 and convert.cjs:53; two `parseFacts` (draw.cjs:2225 vs json.cjs:84); "progressed"/"stalled" defined three times (record.cjs:~268-281 writes them, report.cjs:56-70 re-derives as legacy fallback, json.cjs reuses report's).
- **Duplication with gui/** (gui never requires lib; it talks only via CLI `--json`, so these are copies held together by smoke tests): gui/live.cjs parses the activity (`<epoch> <label>`) and feed (`MM:SS · Tool arg`) formats stream.cjs writes; gui/model.js:64 and gui/runend.js re-encode run-end words and exit codes 10/20/30 that json.cjs:254-260 already maps; gui/model.js:279,353 and runview.js:34 re-map the outcome words from report.cjs:83; gui/art.js:133 hand-copies the sunrise from draw.cjs.
- **Giant file/functions**: foreman-draw.cjs is a single 2440-line file mixing palette I/O, encoder, sprite pixel data, ~15 scene layouts, two animation engines and the CLI. Long functions: `convertRows` (:1584-1715, ~130 lines), `trackScene` (:1920-2030, ~110), `playDoctor` (:2081-2176, ~95-line closure with ~12 mutable locals), `main` (:2380-2430, ~50 lines of flag validation), `introPixels` (:538-598). record.cjs is one ~400-line top-level script whose module-level consts are order-dependent (signal ladder :167-281).
- **Hidden cross-file coupling**: draw.cjs scrapes foreman-ui.sh by regex at runtime (:139) and throws if its quoting changes (picture lost, plain text still works). Scene `min` widths are duplicated in bin/foreman (`_report_min_cols=84`, `_convert_min_cols=86`) and foreman-order.sh (`_order_min_cols=80`), tied to the SCENES table only by a smoke case (draw.cjs:2178-2180 comment). report.cjs shells out to bash for `foreman_find_batches` (:139).
- **Constants and naming drift**: `foreman_json: 1` literal in two files; LIMIT/CONTEXT/TRANSIENT/PERMISSION pattern lists live only in record.cjs (auth alone is shared); verdict `transient` vs record `transient_error`.
- **Silent skipping**: bare `catch {}` is used widely (stream.cjs, json.cjs:186, draw `finish`). Fits the never-break-the-pipeline rule, but a corrupted run log makes `status --json` under-count spend with no `unreadable` counter (report.cjs has one).
- **Positives**: auth patterns and ANSI stripping are shared once; stream.cjs never prints tool inputs beyond name+first arg; verdict values are whitelisted so bash never evals model output; json.cjs has injectable io for tests.

---

<!-- map/04-gui.md -->

# Map 04 - gui/ (Electron app) + lib/foreman-gui.sh

Windows-only desktop window over the CLI. Electron 45.3.1 is the sole dependency (gui/package.json:12). It runs from the git checkout; nothing is persisted (main.cjs:6-7).

## 1. Process architecture
- **Main** (main.cjs, 365 lines) owns every child process, every fs read and the single `BrowserWindow`. The window is `contextIsolation`, `sandbox`, no node, no webview (main.cjs:343-347). Navigation and `window.open` are denied (guard.cjs:19-20). Permission requests are denied (main.cjs:358).
- **Preload** (preload.cjs) exposes `window.foreman` through `contextBridge`. It is a flat set of `ipcRenderer.invoke` wrappers plus three subscribe helpers that return an unsubscribe fn. No channel names reach the page.
- **Renderer** (index.html) loads plain scripts: model, states, runplan, runview, runend, art, preview, app. The CSP is strict: `default-src 'self'`, no inline script or style (index.html:5). All DOM is built with createElement/textContent, so there is no markup injection path.
- Every handler first calls `trusted(event)`, which compares `senderFrame.url` to the page's file URL (main.cjs:108-112).
- **Invoke channels (renderer -> main).** Each returns `{ok:true,...}` or `{ok:false,error:{kind,message,tried,dir}}` via `describe()` (main.cjs:38):

| channel | payload | does |
|---|---|---|
| overview:load | batch or null | `status --all` + `status <b>`, decorated with conditions, starts the watcher (114) |
| repo:choose | - | folder picker; drops ctx and watcher, sets `chosenDir` (131) |
| clipboard:init | - | writes the constant `INIT_COMMAND` (148) |
| dryrun:load / report:load(batch,{byTicket,run}) / doctor:load / doctor:fix | | one CLI `--json` call each (156-201) |
| ticket:load(batch,name) / ticket:save(batch,name,text,base) | | ticket.cjs; save is the only fs write in the app (205-226) |
| run:confirm | batch | dry-run + `git check-ignore` + conf text + env caps (237) |
| run:start(batch,request) | | re-validates, spawns a detached `foreman run` (254) |
| run:load / run:keys(batch,"+-L") / run:stop(batch,now) | | live.read / `foreman keys` / `foreman stop [--now]` (273-310) |
| window:compact(bool) | | resizes the window (314) |
| open | repo-relative path | `shell.openPath` (328) |

- **Push channels (main -> renderer).** `overview:update` carries an overview doc or `{ok:false,error}` (main.cjs:102). `run:update` carries `{batch, run|null}` (105). `run:exit` carries `{batch, code, signal, out}` (265).
- **Pure modules** (UMD, loaded both as `<script>` and by `require`): model.js, states.js, runplan.js, runview.js, runend.js, preview.js. DOM only: art.js, app.js. Pure logic with injected IO: guard.cjs (win32 path math only), conditions.cjs, overview.cjs.
- **fs:** ticket.cjs (r/w, injectable `io`), live.cjs (read, injectable `fs`), runner.cjs (mkdir/open `out`, injectable), watch.cjs (`fs.watch`), bash.cjs (`existsSync`), main.cjs `readConf` (233).
- **child_process:** foreman.cjs (`execFile`, injectable `run`) and runner.cjs (`spawn`, injectable).

## 2. Talking to the CLI
- Every call is `<bash.exe> <checkout>/bin/foreman <cmd> ...`, with cwd = repoRoot, `windowsHide`, stdin ignored, and a 64 MB maxBuffer (foreman.cjs:121-134, 103-110). There is no timeout.
- `checkout` is `path.resolve(__dirname,'..')` (main.cjs:51), so the GUI always drives the toolkit it lives in.
- Env is a whitelist, `cliEnv` (foreman.cjs:36-55): system vars plus anything `FOREMAN_*`, with forced `FOREMAN_SHOW/COLOR/INTRO=never` and `GIT_OPTIONAL_LOCKS=0`. Tokens are not passed, so the CLI reads its own credentials file.
- **Commands used.**
  - JSON: `status <b> --json`, `status --json --all`, `dry-run <b> --json`, `report <b> --json [--by-ticket] [--run id]`, `doctor --json`, `doctor --fix --json`.
  - Words: `keys <b> <[-+Ll=_]+>`, `stop [--now] <b>`.
  - Raw git through `bash -c`: `git rev-parse --show-toplevel` (foreman.cjs:208), `git check-ignore -q -- "$1/.foreman-run/pid"` (187).
  - Run: `run <b> <n|--unlimited> [--live]` (runner.cjs).
- `parseOutput` (foreman.cjs:80) requires one JSON object, `foreman_json === 1` and `doc.command === asked`. Error kinds are spawn, exit, parse, version, bad-batch, bad-run, not-a-repo.
- **Watching.** watch.cjs uses `fs.watch(dir,{recursive:true})` on each non-finished batch dir, plus the selected one (overview.cjs:68). There is no timer polling (watch.cjs:4). Events are debounced 150 ms.
  - One retry is allowed after a failed read, because the loop may have renamed things to `DONE_`.
  - `sync()` re-asks for the dir set after every read, so the watch follows renames.
  - A read is a full overview refresh (2 bash spawns, plus `report --run` for a live run). The exception is when a run is in flight and every change is under `.foreman-run/` but is not `pid` or `run` (live.cjs:109-114, main.cjs:78). Then only the control files are read from disk, with no process spawned.
- **Stop / pause.** `stop` sets the budget to the current iteration (the run finishes the iteration, then pauses). `stop --now` is the CLI's own sequence (lib/foreman-control.sh:15-41): a `stop` file, SIGINT to the loop and its descendants, then after `FOREMAN_STOP_GRACE` (5 s) `taskkill /F /T` on the children. It waits up to 60 s. The GUI never signals or kills anything itself. `+`/`-`/`L` go through `foreman keys`, which writes the control files.

## 3. Modules (deps)
- main.cjs: wiring, IPC and window. Requires bash, foreman, watch, overview, ticket, runner, live, conditions, states (`INIT_COMMAND`), guard.
- preload.cjs: the bridge. Requires electron only.
- bash.cjs: finds Git Bash. Order is FOREMAN_BASH, then `git.exe` on PATH -> `<root>\bin\bash.exe`, then `C:\Program Files\Git\bin\bash.exe`. It refuses the WSL launcher. No deps.
- foreman.cjs: CLI client, `cliEnv`, `checkBatchPath`, `checkRunId`, `findRepoRoot`, `ForemanError`, `plainText`. Requires child_process.
- runner.cjs: builds and spawns the detached run, and reads the tail of `out`. Requires runplan and foreman.
- runplan.js: validates a run request, builds the argv, the cap env and the command string, and the confirm-screen view-model and help text. No deps.
- watch.cjs: debounced recursive watcher. Requires fs.
- overview.cjs: selected batch, epoch guard against stale refreshes, `statusOf`, watch dirs. Requires model.js (`pickBatch`).
- live.cjs: reads `<batch>/.foreman-run/{budget,iteration,live,activity,feed,spent}`, caches the last `report --run`, and exports `onlyControlFiles`. Requires fs only (foreman injected).
- conditions.cjs: the "runner missing" and "login expired" states, from `doctor --json` and `report --run`. The doctor read is async behind the overview and fires `onChange`. No deps.
- ticket.cjs: ticket page read and handoff save, with symlink-safe `resolveInside`, a base-text conflict check and EOL preservation. Requires foreman (for `ForemanError`).
- guard.cjs: argv -> repo, navigation denial, `repoPath` (lexical check, then win32 join). Requires foreman.
- model.js: all screen wording, rail, `pickBatch`, `renamedTo`, ticket page and notes. Pure.
- states.js: the six pane states, `INIT_COMMAND`. Pure.
- runview.js: live screen view-model. Pure.
- runend.js: maps `status.last_run` (exit code) to an end scene. Pure.
- preview.js: tiny markdown -> node list. Pure.
- art.js: SVG dome and scenes. DOM.
- app.js (1643 lines): every screen, one IIFE. Depends on the six `window.Foreman*` globals and `window.foreman`.
- lib/foreman-gui.sh: `foreman gui [dir]`. It looks for `gui/node_modules/electron/dist/electron[.exe]`. If it is missing, it offers `install.sh --gui` on a tty. Then it resolves the git toplevel (or uses dir), converts paths with `foreman_mixed_path`, unsets `ELECTRON_RUN_AS_NODE`, and starts `nohup [setsid] electron <gui> <repo> </dev/null >/dev/null &` in a subshell, then `exit 0`.

## 4. Child process lifecycle
- **Spawn.** runner.cjs:61 uses `detached:true, windowsHide:true, stdio:['ignore',fd,fd]`, with stdout and stderr in `<batch>/.foreman-run/out`, truncated per run. It calls `child.unref()` on the `spawn` event. `start` resolves `{pid,command}` as soon as the process exists. The pid is returned but never used again.
- **Exit.** `child.once('exit')` calls back into main, which sends `run:exit` with the tail of `out`. This only fires while the app is alive and only for runs started by this app process.
- **Quit.** `window-all-closed` -> `app.quit()`. `before-quit` only stops the watcher (main.cjs:364-365). Nothing is killed, so a run outlives the app by design (runner.cjs:3). A relaunch finds it through `status.run.in_flight`, and caps then come from conf/env (live.cjs:53).
- **Windows.** Git Bash is a hard requirement. Paths given to the CLI are mixed form (`C:/x`) or repo-relative with forward slashes, and `repoPath` converts them back to backslashes for `shell.openPath`. `stop --now` depends on `taskkill` and `/proc/<pid>/winpid` (an MSYS detail). `foreman-gui.sh` copes with MSYS `setsid` being absent.

## 5. Logic duplicated from lib/
- **Conf parsing, four regex readers, no shared one**:
  - `capsFromConf` (live.cjs:53) takes the first numeric match, for the caps.
  - `execModeOf` (conditions.cjs:25) takes the last match and knows the legacy `RALPH_` prefix.
  - `capSource` (runplan.js:112) only tests whether a line exists.
  - `readConf` (main.cjs:233) is a raw read feeding those three.
  - The CLI itself `source`s conf (foreman-config.sh), so quoted values, `${VAR:-x}` and later lines are handled differently from the GUI.
- **Ticket and batch naming**:
  - `ticketName` is re-implemented in model.js:209, runview.js:24 and runend.js:32. Each carries its own copy of the DONE_ strip regex `^[A-Za-z]+_(?=\d)`, and runend.js adds `slugOf` (21).
  - The DONE_ prefix is configurable in the CLI (`FOREMAN_DONE_PREFIX`, lib/foreman-tickets.sh:130), but the GUI hard-codes the shape.
  - `renamedTo` (model.js:517) guesses where a batch was renamed to, from name suffixes.
- **Run control-dir format**: filenames and line shapes (`budget`, `spent "COST MAX"`, `activity "EPOCH LABEL"`, feed `mm:ss · Tool text`) mirror foreman-keys.sh and foreman-stream.cjs (live.cjs:20-48). So does the pid/run start/end signal (live.cjs:110).
- **Control-dir path** `.foreman-run` is repeated in runner.cjs:52, main.cjs and foreman.cjs:190.
- **Path safety**: three separate validators: `checkBatchPath` (foreman.cjs:59), `repoPath` (guard.cjs:25) and `resolveInside` (ticket.cjs:26). Only the last follows symlinks.
- Status, dry-run and report parsing are NOT duplicated: the GUI trusts the CLI's JSON (a strength).

## 6. Smells
- **Run exit callback can crash main.** The closure at main.cjs:264-266 reads the global `ctx`. After `repo:choose` sets `ctx = null` (:137), a later exit throws a TypeError in the main process. It also reports on a stale repo.
- **`if (!ctx) await setup()` races.** It is repeated in 12 handlers (e.g. main.cjs:117, 159). Two concurrent first calls run `setup()` twice and overwrite the global `watcher`, so the old watcher's handles leak. The `trusted`+try/catch+describe boilerplate is also copy-pasted 15 times; a wrapper would remove it.
- **A dead run is never noticed from the GUI side.** There is no liveness poll (watch.cjs:4 is deliberate). A loop that is hard-killed, or a terminal run that crashes, leaves the `pid` file stale. That produces no fs event, so the screen stays "in flight". The `run:exit` event covers only runs this app process started.
- **Elapsed clocks don't tick.** There is no setInterval anywhere in the renderer. `runview` computes `now - activity.epoch` from `at: Date.now()` captured at read time (live.cjs:97, runview.js:82), so the clock only advances on file events.
- **Cost of each change.** Any non-control change during a run (progress.txt, the record, tickets) triggers `status --all` + `status <b>` + `report --run`. Each is a Git Bash spawn that takes seconds (per overview.cjs:3). `execFile` has no timeout, so a hung bash hangs the IPC call forever (foreman.cjs:105).
- **Inline style under strict CSP.** app.js:1309 sets `attrs:{style:'padding-left:16px'}`. `style-src 'self'` (index.html:5) blocks an inline style attribute, so the padding is silently dropped. app.js:531 correctly uses CSSOM.
- **`shell.openPath` on repo-relative paths** (main.cjs:331) uses only the lexical `repoPath` check. A symlink inside the repo can point outside, and an in-repo `.cmd`/`.exe` is executed by the default handler. `resolveInside` isn't used here.
- **Env whitelist is too strict for the run.** `cliEnv` is also what the detached `foreman run` gets (runner.cjs:35). It drops `HTTP(S)_PROXY`, `SSH_AUTH_SOCK`, `GH_TOKEN`/`GIT_*` and `ANTHROPIC_*`, so a run started from the GUI can behave differently from a terminal one when anything but credentials-file auth is used.
- **bash.cjs:66** only knows `C:\Program Files\Git`. Per-user Git installs (`%LOCALAPPDATA%\Programs\Git`) and x86 are found only if git.exe is on PATH.
- **TOCTOU on starting a run.** The in-flight check (`status`) and the spawn (main.cjs:262-264) are not atomic and there is no in-process lock, so a double click can start two. The CLI's own guard is the only backstop.
- **Conf regex divergence** (see 5): `capsFromConf` takes the FIRST match but the shell takes the LAST. It also ignores the legacy `RALPH_MAX_*`, so the "caps" shown for a running terminal run can be wrong.
- **app.js is a 1643-line IIFE** with many module-level mutables (`data, lv, cf, rep, dr, tp`) and a second block of consts mid-file (:945-947). Behaviour is only testable through a DOM harness. `typeof api.onRunUpdate === 'function'` guards (app.js:1603, 1612) imply preload/app version skew was a concern.
- `checkBatchPath` is imported twice in main.cjs (:17, :23). The `describe()` error shape drops `code`/`stderr` and everything but four fields (main.cjs:38).

---

<!-- map/05-tests.md -->

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
