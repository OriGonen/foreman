# Bugs 04 - config parsing, CLI dispatch, prompt building

Method: read lib/foreman-config.sh, -legacy, -repo, -doctor, -prompt, -credentials, -init, -commands, bin/foreman(.cmd), loop arg parsing; repros run in throw-away git repos under /tmp with `FOREMAN_EXEC=fake` (no agent, no sbx, test/smoke*.sh not run). No tracked file touched.

Checked and clean (no finding): prompt substitution (ticket text is `@file`-attached, never substituted; `$(..)`, backticks, `&`, `\1` in FOREMAN_TEST_CMD come out literal and nothing executes; PROMPT_EXTRA is spliced after the fills); CRLF foreman.conf (handled by the LF temp copy); credentials reader (data-only parse, nothing in the toolkit writes the file, so no permission problem exists; values are not logged); legacy RALPH_ precedence (env > conf > default holds, FOREMAN_ name beats RALPH_ name); env values with newlines, quotes, `=`, `$()` survive the snapshot/restore intact.

---

## 1. FOREMAN_MAX_MINUTES with a leading zero makes the loop abort silently and mark the batch DONE (high, confirmed-by-repro)

- Where: lib/foreman-config.sh:451-457 (validation is `^[0-9]+$`), lib/foreman-loop.sh:1703 (also :1938, :2140), lib/foreman-loop.sh:1327 (`FINAL_STATUS="$EXIT_DONE"` is the initial value), :2192 -> `mark_batch_done_on_disk`.
- What: `08` / `09` pass validation, but `$((MAX_MINUTES * 60))` reads it as invalid octal. The arithmetic error aborts the whole `while` body, nothing sets FINAL_STATUS, so the run ends as "done": exit 0, footer printed, the batch directory is `git mv`'d to `DONE_<batch>` and a commit `chore: mark batch done` is made - with the ticket still `todo`.
- Evidence:
  ```
  $ FOREMAN_MAX_MINUTES=08 foreman run batch
  foreman-loop.sh: line 1703: 08: value too great for base (error token is "08")
  iterations run:        0 ... tickets landed: 0
     ✓ batch marked done  ·  DONE_batch          (rc=0)
  $ cat DONE_batch/issues/*.md  ->  **Status:** todo
  ```
- Fix: validate `^(0|[1-9][0-9]*)$` (or normalise with `10#`), and make the loop's default FINAL_STATUS a failure (e.g. 1) that only the "no tickets left" path turns into EXIT_DONE.
- Changes public CLI/config format: no (rejects `08` with the existing "must be a whole number" error; the default-status change is internal).

## 2. Budget knobs are barely validated: a mistyped FOREMAN_MAX_COST_USD silently means "unlimited" (high/med, confirmed-by-repro)

- Where: lib/foreman-config.sh:382 (no check), :451-452 (cost missing from the integer list); consumed by `fgt "$MAX_COST" 0` at lib/foreman-loop.sh:1698 and :1937 (awk `a+0`).
- What: anything awk reads as <= 0 disables the cap and the run prints "cost=unlimited": `$25` (quoted so the shell keeps it), `abc`, `-5`, `25 USD` -> 25 is fine but `USD25` -> 0. A user who set a cap to protect a paid run gets none and no warning. Same family: `FOREMAN_MAX_CONTINUATIONS=0` is not "no continuations" but unlimited (`[ "$MAX_CONTINUATIONS" -gt 0 ] && ...`, loop:256), and `FOREMAN_PROGRESS_TAIL_BYTES=0` / `FOREMAN_CONTEXT_BUDGET_TOKENS=0` are accepted and produce "this is the first iteration" / "well inside 0 tokens" in the prompt.
- Evidence:
  ```
  $ FOREMAN_MAX_COST_USD='$25' foreman dry-run batch | grep Budgets   -> Budgets: cost=unlimited ...
  $ FOREMAN_MAX_COST_USD=abc     (same)      $ FOREMAN_MAX_COST_USD=-5   (same)
  ```
- Fix: validate cost against `^[0-9]+(\.[0-9]+)?$` next to the integer loop; error out on anything else. Document or reject 0 for MAX_CONTINUATIONS, PROGRESS_TAIL_BYTES, CONTEXT_BUDGET_TOKENS.
- Changes public CLI/config format: tightens it only (values that were silently ignored now error).

## 3. A batch path is resolved after `cd $REPO_ROOT`, so paths relative to the caller's directory fail, and `.` silently selects the repo root (med, confirmed-by-repro)

- Where: lib/foreman-config.sh:61 (`cd "$REPO_ROOT"`) before :93 (`foreman_batch_relpath ... "$FOREMAN_BATCH"`); the comment at :91-92 and in foreman-repo.sh promises "relative to the repo root or to the caller's own directory".
- What: `[ -d "$given" ]` and `cd "$given"` in foreman_batch_relpath now run from the repo root. From a subdirectory, `foreman status b2` -> "no such directory". Worse, `foreman status .` / `foreman run .` typed inside a batch directory resolves to the repo root (`BATCH_DIR="."`), so the command runs against the wrong "batch" instead of failing. `foreman init` does not have this problem (it cds later), so the commands disagree.
- Evidence (repo/sub/b2 is a batch):
  ```
  repo/sub$     foreman status b2     -> foreman: no such directory: b2
  repo/sub/b2$  foreman status .      -> Batch: .  /  foreman-next.sh: no tickets found.
  ```
- Fix: make FOREMAN_BATCH absolute before the cd (`[ -d "$FOREMAN_BATCH" ] && FOREMAN_BATCH=$(cd "$FOREMAN_BATCH" && pwd)`, keeping the existing error path) or call foreman_batch_relpath before line 61.
- Changes public CLI: only makes the documented behaviour true; no format change.

## 4. `foreman doctor` reads confs as text and disagrees with what config.sh does (med, confirmed-by-repro)

- Where: lib/foreman-doctor.sh:227-229 (`_conf_value`), :453-457 (`_check_can_commit`), :201-204 (batch discovery), and no env handling anywhere.
- What (a, b, c, e reproduced; d read from the code, not run):
  a. Trailing comment: `FOREMAN_EXEC=fake   # no agent` is valid bash, but doctor reads `fake   # no agent` and fails the run: "FOREMAN_EXEC=fake   # no agent in batch/foreman.conf - no such execution mode", exit 1, "NOT PASSED". Same for `FOREMAN_PERMISSION_MODE=bypassPermissions # ...` (then a false "no way for the agent to commit").
  b. `export FOREMAN_EXEC=fake` is not matched at all, so doctor judges the batch as `sandbox` and requires `sbx` (config.sh sources it and runs `fake`; commands.sh itself accepts the `export` form).
  c. The environment is ignored: `FOREMAN_EXEC=fake foreman doctor` still demands sbx, though env wins over conf at run time.
  d. A multi-line `FOREMAN_CLAUDE_ARGS=(\n --allowed-tools ... "Bash(git commit:*)"\n)` only has its first line grepped, so `git commit` is "missing" (local mode, false failure).
  e. Batch discovery lacks the `DONE_*` prune that foreman_find_batches has, so finished batches are listed as "! DONE_old / order unreadable".
- Evidence: see a-c above; e: `! DONE_old  order unreadable - run: foreman status DONE_old` in the BATCHES box.
- Fix: in `_conf_value` strip `export `, an unquoted trailing ` #...` and honour a same-named env var first; replace the doctor `find` with `foreman_find_batches` (already sourced via foreman-repo.sh); for (d) join continuation lines before grepping. Alternative: source the conf in a subshell `( source conf; printf %s "$FOREMAN_EXEC" )` (doctor's stated reason for text-reading is arbitrary bash, but the loop sources it anyway).
- Changes public CLI/config format: no. Doctor output only becomes correct.

## 5. Auto-discovery of a batch at the repo root returns the file name `foreman.conf` (low-med, confirmed-by-repro)

- Where: lib/foreman-repo.sh:145 (`sed 's|^\./||; s|/foreman\.conf$||; ...'`); same sed copy in lib/foreman-doctor.sh:204.
- What: for `./foreman.conf`, the first expression leaves `foreman.conf`, and the second needs a leading `/`, so the batch name comes out as `foreman.conf`. The loop explicitly supports `BATCH_DIR="."` (loop `mark_batch_done_on_disk` guard), and `foreman status .` works, but omitting the batch fails, and doctor/`status --json --all` carry the bogus name.
- Evidence:
  ```
  repo/ has foreman.conf at its root:   foreman status   -> foreman: no such directory: foreman.conf
                                          foreman_find_batches -> foreman.conf
  ```
- Fix: `s|^\./||; s|^\(foreman\|ralph\)\.conf$|.|; s|/\(foreman\|ralph\)\.conf$||`.
- Changes public CLI/config format: no.

## 6. Environment snapshot/restore mangles array knobs and lets an empty env value wipe the conf (low-med, confirmed-by-repro)

- Where: lib/foreman-config.sh:115-118 and :146-148 (`${!name}` reads only element 0; `printf -v` on an array name writes only element 0), :372.
- What: (a) `FOREMAN_CLAUDE_ARGS` is an array in the template. `FOREMAN_CLAUDE_ARGS='--verbose' foreman run ...` does not replace the array, it replaces element 0: the result is `--verbose "Bash(git add:*)" "Bash(git commit:*)"`, a malformed `claude` command line (the two allowlist entries become stray positionals). A one-string env value can never express two arguments, so there is no working env override for this knob. (b) Any FOREMAN_* that is set but empty in the environment overrides the conf for knobs whose default uses `${VAR-default}` (DONE_PREFIX, HUMAN_WORD) or is read verbatim (CHECK_CMD): `FOREMAN_CHECK_CMD= foreman run` blanks a conf's `FOREMAN_CHECK_CMD="npm run check"`; for `:-` knobs the empty value is replaced by the default, discarding the conf value too.
- Evidence:
  ```
  $ FOREMAN_CLAUDE_ARGS=--verbose  (conf: FOREMAN_CLAUDE_ARGS=(--allowed-tools "Bash(git add:*)" "Bash(git commit:*)"))
  [--verbose]  [Bash(git add:*)]  [Bash(git commit:*)]
  $ FOREMAN_CHECK_CMD= ...  ->  CHECK=[]
  ```
- Fix: snapshot with `declare -p` (or `compgen -v` + `[ -n "${!n+x}" ]` plus array check) and restore whole arrays, or exclude FOREMAN_CLAUDE_ARGS and skip empty values from the snapshot (`[ -n "${!n}" ]`) if "empty = unset" is the intent.
- Changes public config semantics slightly: an empty env var would stop clearing a conf value (document it); array handling is a fix.

## 7. `dry-run` ("free") is refused on a dirty tree, and `status`/`dry-run` flag order is last-wins (low-med, confirmed-by-repro; refusal needs a decision on intent)

- Where: lib/foreman-loop.sh:909-917 (the dirty-tree preflight runs for MODE=dry-run too, only the run-state/exec checks are limited to `run`); bin/foreman:146-147 (`--status` / `--dry-run` appended after the user's args); loop:121-122 (last one wins).
- What: the main reason to run `foreman dry-run` is to preview the prompt after editing foreman.conf or prompt-extra.md - exactly when the tree is dirty - and it exits 1 with "the working tree is dirty ... Override with FOREMAN_ALLOW_DIRTY=1". `foreman status` is fine in the same state. Separately `foreman status --dry-run b` prints the status (the appended `--status` wins) and `foreman dry-run --status b` runs the dry-run; the user's flag is swallowed without a message.
- Evidence:
  ```
  (batch/foreman.conf modified)  $ foreman dry-run batch  -> preflight: the working tree is dirty ... (rc 1)
  $ foreman status --dry-run batch -> "Batch: batch / Tickets done: 0 / 1"   (no prompt)
  ```
- Fix: skip the dirty check when `MODE != run`; in the parser reject a second mode flag (`MODE` already set to something other than run) with the usage line.
- Changes public CLI: dry-run stops failing on a dirty tree; conflicting mode flags become an error instead of last-wins.
