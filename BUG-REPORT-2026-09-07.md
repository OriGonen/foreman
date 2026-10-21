# foreman toolkit — issues found while onboarding pixel-diffusion (2026-09-07)

Found while setting up a batch (`.scratch/sinkhorn-speedup/issues`) in
`C:\Projects\pixel-diffusion` on this machine. Two confirmed bugs, one blocking
(sandbox mode unusable), one silently-corrupting (prompt mangling). Plus two smaller
usability findings from the same session. Toolkit was at commit `c8456fc` (up to date
with its own `origin/main`) throughout.

---

## 1. CONFIRMED — `&` in a `FOREMAN_*_CMD` value corrupts the rendered prompt

**Severity:** High. Silent corruption, no error, no warning — the agent receives a
mangled instruction and either fails confusingly or (worse) may try to act on the
garbled text. Only visible via `foreman dry-run`.

**Where:** `lib/foreman-prompt.sh`, the substitution block at lines 102–111:

```sh
_foreman_body="${_foreman_body//__ORDER_SENTENCE__/$_foreman_order_sentence}"
_foreman_body="${_foreman_body//__PROGRESS_FILE__/$PROGRESS_FILE}"
_foreman_body="${_foreman_body//__BASE_REF__/$BASE_REF}"
_foreman_body="${_foreman_body//__TDD_INSTRUCTION__/$_foreman_tdd}"
_foreman_body="${_foreman_body//__ITERATIVE_CHECK_BLOCK__/$_foreman_iterative}"
_foreman_body="${_foreman_body//__VERIFY_BLOCK__/$_foreman_verify}"
_foreman_body="${_foreman_body//__REVIEW_INSTRUCTION__/$_foreman_review}"
_foreman_body="${_foreman_body//__COMMIT_NOTE__/$_foreman_commit}"
_foreman_body="${_foreman_body//__STATUS_LINE__/$FOREMAN_STATUS_LINE}"
_foreman_body="${_foreman_body//__DONE_WORD__/$FOREMAN_DONE_WORD}"
```

**Root cause:** bash's `${var//pattern/replacement}` treats an *unescaped* `&` inside
`replacement` as "insert the matched text" — the same convention as `sed`'s `&`. This
is not bash-specific trivia the code was unaware of in general: the comment directly
above this block (lines 90–93) already documents that the *free-text* blocks
(`prompt-extra.md`, progress notes) are deliberately concatenated instead of substituted
"because bash's pattern substitution treats backslashes in a replacement as escapes,
which would quietly mangle any Windows path or regex someone wrote there." The `&`
sibling of that exact same hazard was missed for the ten slots above.

**Repro (standalone, nothing foreman-specific):**

```sh
$ bash -c '
body="XX__VERIFY_BLOCK__YY"
verify="node a.js && node b.js"
body="${body//__VERIFY_BLOCK__/$verify}"
echo "$body"
'
XXnode a.js __VERIFY_BLOCK____VERIFY_BLOCK__ node b.jsYY
```

Every `&` in `$verify` was replaced with the literal matched pattern (`__VERIFY_BLOCK__`).
`\&` in the replacement avoids it (confirmed), which is the standard escape-hatch for
this bash behavior.

**Trigger condition in practice:** any `foreman.conf` that chains commands with `&&` in
`FOREMAN_CHECK_CMD`, `FOREMAN_TEST_CMD`, or `FOREMAN_FOCUSED_TEST_CMD` — an extremely natural
thing to write (`"npm run lint && npm run typecheck"`, `"cmd1 && cmd2 && cmd3"`, etc.).
These three variables feed `_foreman_verify` (line 107 substitution) and `_foreman_iterative`
(line 106 substitution) via the string-building at lines ~60–67 of the same file. Hit
this on the very first `foreman.conf` written for pixel-diffusion:

```
FOREMAN_TEST_CMD="node tests/verify_js_node.js && node tests/verify_sinkhorn.js && python tests/verify_python.py"
```

rendered (via `foreman dry-run`) as:

```
- `node tests/verify_js_node.js __VERIFY_BLOCK____VERIFY_BLOCK__ node tests/verify_sinkhorn.js __VERIFY_BLOCK____VERIFY_BLOCK__ python tests/verify_python.py`
```

**Blast radius:** confirmed this substitution idiom (`${var//pattern/replacement}` with
a computed, user-influenced `replacement`) is only used in `foreman-prompt.sh` — swept the
rest of `lib/` for the same pattern and found no other occurrences. So the fix is
localized to this one file, but every one of the 10 slots listed above is theoretically
exposed if the underlying `foreman.conf` value (or, for `__ORDER_SENTENCE__`, a
batch/order-file path; for `__STATUS_LINE__`/`__DONE_WORD__`, a customized status
line/word) ever contains a literal `&`. `FOREMAN_TEST_CMD`/`FOREMAN_CHECK_CMD`/
`FOREMAN_FOCUSED_TEST_CMD` are by far the likeliest in practice.

**Suggested fix:** escape `&` (and probably `\`, out of caution, even though I could not
get a backslash repro to actually misbehave — see "not reproduced" note below) in each
computed value immediately before it's used as a `replacement`, e.g.:

```sh
_foreman_verify_safe="${_foreman_verify//&/\\&}"
_foreman_body="${_foreman_body//__VERIFY_BLOCK__/$_foreman_verify_safe}"
```

...repeated for all ten slots, or better, factored into a small `_foreman_escape_repl()`
helper applied uniformly right before the substitution block. Alternatively, avoid
`${var//pat/repl}` for these slots entirely and use the same concatenation strategy
already used for the free-text blocks (split the template on each marker, join with the
literal value) — that sidesteps the whole class of "replacement text has shell-special
characters" bugs rather than escaping around it.

**Not reproduced (worth a broader sweep anyway):** tried to reproduce the backslash
hazard the existing comment warns about (Windows paths, `\1`-style regex
backreferences, trailing backslashes) directly against `${var//pat/repl}` and could not
get it to misbehave in isolated tests — only `&` actually corrupted output for me.
Possible the comment is about a different/additional bash version's behavior, or about
something specific to how `prompt-extra.md`/progress-note content is *read* (e.g.
multi-line content, `printf`, or a different code path) rather than this exact
`${var//pat/repl}` idiom. Worth double-checking with a wider set of adversarial inputs
(e.g. a `FOREMAN_TEST_CMD` containing a literal backslash-ampersand, `\\&`, or Windows
paths with trailing backslashes) before assuming `&` is the *only* special character
here.

---

## 2. CONFIRMED — `FOREMAN_EXEC=sandbox` (the default) is unusable: `sbx create --clone`
doesn't produce what foreman's own clone-mode check expects

**Severity:** High / blocking. `FOREMAN_EXEC=sandbox` is the documented default exec mode,
and on this machine every single `foreman run` fails at preflight before the agent is ever
invoked — reproduced twice in a row, including immediately after following the tool's
own suggested recovery command.

**Where:**
- Detection: `lib/exec/_sbx.sh` lines 13–15:
  ```sh
  _sbx_is_clone_mode() {
    [ "$(_sbx_sh 'git remote get-url origin 2>/dev/null' 2>/dev/null | tr -d '\r')" = "/run/sandbox/source" ]
  }
  ```
- Creation: `lib/exec/_sbx.sh` lines 33–39 (`_sbx_create`), called from
  `lib/exec/sandbox.sh`'s `exec_prepare()`:
  ```sh
  exec_prepare() {
    _sbx_create clone
    if ! _sbx_is_clone_mode; then
      warn "preflight: sandbox '$FOREMAN_SANDBOX' exists but is not in clone mode."
      ...
      return 1
    fi
    _sbx_probe
  }
  ```

**Observed sequence:**

1. `foreman run` — `sbx create --clone --name foreman-pixel-diffusion claude <repo>` runs,
   prints `mount C:\Projects\pixel-diffusion → /run/sandbox/source (ro, source)` (looks
   exactly like a correct clone-mode setup), then immediately:
   ```
   preflight: sandbox 'foreman-pixel-diffusion' exists but is not in clone mode.
              ... Recreate it: sbx rm --force foreman-pixel-diffusion
   ```
2. Followed the suggested recovery (`sbx rm --force foreman-pixel-diffusion`, confirmed
   via `sbx list` there was nothing else attached to that name), re-ran `foreman run`.
   **Identical failure**, same sandbox freshly (re-)created moments earlier.
3. Inspected the sandbox directly:
   ```
   $ sbx exec foreman-pixel-diffusion sh -c "git remote get-url origin"
   https://github.com/OriGonen/pixel-diffusion.git
   ```
   — not `/run/sandbox/source`. Compared to the host repo's own remote
   (`git remote -v` on the host): identical URL. `git log --oneline -3` inside the
   sandbox exactly matched the host's HEAD at time of creation, strongly suggesting the
   sandbox's `.git` (including its `origin` remote config) was copied wholesale from the
   host repo rather than produced by a fresh `git clone /run/sandbox/source` — which is
   what `_sbx_is_clone_mode` assumes `--clone` does.

**Root cause — NOT independently confirmed, needs the fixer to check:** either (a) the
currently-installed `sbx` build's `--clone` implementation no longer repoints `origin` to
`/run/sandbox/source` (behavior drift/regression relative to whatever `sbx` version
`_sbx_is_clone_mode` was originally written against), or (b) `_sbx_is_clone_mode` is
simply checking the wrong signal for the currently-installed `sbx`. Could not pin the
installed `sbx` version for comparison — `sbx --version` is not a recognized flag on this
build (`ERROR: unknown flag: --version`); `sbx create --help`'s description of `--clone`
("Run the agent on a private in-container clone of the host Git repository (mounted
read-only) instead of bind-mounting the workspace; the agent's commits are accessible via
the sandbox-<name> git remote on the host") does not itself promise anything about what
`origin` gets set to inside the clone, so foreman's assumption there may always have been
resting on an implementation detail rather than a documented `sbx` contract. Whoever
picks this up should diff against `sbx`'s changelog/release notes around `--clone`, or
just check empirically on a known-good historical `sbx` build if one is available.

**Impact:** `FOREMAN_EXEC=sandbox` — the default, and the *only* mode robust to native
modules / Windows-host + Linux-container splits per the tool's own top-of-file comment in
`lib/exec/sandbox.sh` — is completely unusable on this machine right now. Any repo that
actually needs that isolation (unlike pixel-diffusion, which has no native modules and no
install step) has no working path forward until this is fixed.

**Workaround used (not a general fix):** set `FOREMAN_EXEC=local` for the pixel-diffusion
batch. Safe only because that specific repo has nothing for the sandbox to protect
against (no native modules, no `npm ci`/`pip install` step). Does not help any repo that
actually needs sandbox isolation.

---

## 3. Minor / unconfirmed — `foreman order`'s ticket-count log line disagreed with reality

**Severity:** Low — cosmetic if it's just the log line; worth a quick look in case it's a
symptom of something in `foreman-next.sh --unordered`'s output framing.

Ran `foreman order .scratch/sinkhorn-speedup/issues` against a batch directory containing 9
ticket files. Output:

```
foreman order: reading 1 ticket(s) in .scratch/sinkhorn-speedup/issues ...
foreman order: wrote .scratch/sinkhorn-speedup/issues/order.md (cost $0.2292)
             review it — this is a first pass, not a guarantee.
```

But `order.md` came back with all 9 tickets correctly ordered, with per-ticket rationale
that accurately described each ticket's actual content and blocked-by relationships — so
the agent clearly saw and reasoned about all 9, not 1.

Traced the count in `lib/foreman-order.sh`: `tickets=()` is populated by reading
`foreman-next.sh "$BATCH_DIR" --unordered` line-by-line (lines 57–60), and the exact same
`"${tickets[@]}"` array is both what gets embedded in the ordering prompt (line 102) and
what `${#tickets[@]}` reports in the log line (line 106) — same array, no reassignment
between the two uses in the code as read. Given the ordering *output* was clearly correct
for all 9, I could not explain how the *count* would read 1 without either (a) something
about `foreman-next.sh --unordered`'s line-ending/output framing occasionally causing the
`while IFS= read -r f` loop to collapse multiple paths into one array element in some
runs, or (b) something else I didn't spot. **Did not get to the bottom of this** — didn't
want to spend more of this session on a cosmetic log line — but flagging because if it's
(a), it could theoretically also affect anything else in the toolkit that consumes
`foreman-next.sh`'s line-oriented output.

---

## 4. Usability — `FOREMAN_ISSUES_DIRS` default silently finds zero tickets when the batch
dir's own name matches the default subdir name

**Severity:** Low — documented behavior, not a bug, but the failure mode is opaque.

`FOREMAN_ISSUES_DIRS` defaults to `"issues"` (a subdirectory *inside* the batch dir). If a
batch directory is itself named `issues` (e.g. `.scratch/<feature>/issues/`, which is
literally what this toolkit's own `foreman init` scaffolds by convention) and tickets live
directly inside it rather than in a further-nested `issues/issues/`, the default finds
nothing. What surfaced from that:

```
$ foreman doctor
...
Batches
  .scratch/sinkhorn-speedup/issues         (order unreadable — run: foreman status .scratch/sinkhorn-speedup/issues)

$ foreman status .scratch/sinkhorn-speedup/issues
foreman-next.sh: the ORDER block in .scratch/sinkhorn-speedup/issues/order.md is empty

$ foreman order .scratch/sinkhorn-speedup/issues
foreman order: .scratch/sinkhorn-speedup/issues has no tickets — nothing to order.
```

None of these three messages name the actual resolved search path
(`.scratch/sinkhorn-speedup/issues/issues`) or mention `FOREMAN_ISSUES_DIRS` at all, so
tracking the cause down required reading `foreman.conf`'s own comments and inferring the
default-subdirectory behavior rather than being told directly. Given that `foreman init`'s
own scaffolding convention (batch dir literally named `issues/`) is exactly the shape
that trips this default, it's likely to recur for other users following the same
convention. Suggest either:

- changing the effective default to `.` (search the batch dir itself) since that matches
  what `foreman init` scaffolds, or
- having the "no tickets" / "order unreadable" messages name the resolved search
  directory (e.g. `... — looked in .scratch/sinkhorn-speedup/issues/issues (FOREMAN_ISSUES_DIRS=issues); is that right?`).

---

---

## 5. CONFIRMED — the built-in prompt never tells the agent it's in a single-shot
session, so an iteration can end waiting on a background job that can never notify it

**Severity:** High. Silent — the run reports `exit 0`, `subtype success`, no error
anywhere, but the ticket is neither landed nor retried as failed. Not project-specific:
every batch, on every repo, is exposed any time its verify/check/test command is slow
enough to tempt an agent into backgrounding it.

**Where:** `lib/exec/local.sh:17` and `lib/exec/_sbx.sh:70` both invoke:

```sh
claude --model "$FOREMAN_MODEL" --effort "$FOREMAN_EFFORT" --permission-mode "$FOREMAN_PERMISSION_MODE" \
  --print --output-format json -p "$1"
```

`--print` is a one-shot call: the process prints a single JSON response and exits. There
is no second turn, ever, for any batch — this is structural, not something a particular
`foreman.conf` or ticket can opt out of. But `lib/prompt.template.md` (the one prompt every
batch's every iteration uses, step 3 "Verify" / step 5 "Land it") never says this. It just
says "run the project's full checks" and "set the status line... commit," with nothing
about how those commands must be run.

**Observed failure (this session, ticket `01-real-photo-cost-fixtures.md` in
`pixel-diffusion`):** the agent implemented the ticket, then ran the batch's
`FOREMAN_TEST_CMD` (`sh tests/verify_all.sh`, ~9 minutes end-to-end at N=96/128) as a
backgrounded shell call and ended its turn with:

> "Waiting for the background `verify_sinkhorn.js` run to finish (or the fallback
> wakeup) before continuing with the build/full-suite checks and landing the ticket."

That "later" never comes — `--print` mode has no further turn to deliver a background
task's completion notification into. The CLI exited normally (`exit 0`, `subtype
success`, 71 turns, $1.40, 536s wall) having produced and verified real working code
(confirmed independently after the fact: the fixtures were correct and the full suite
passed), but the ticket's Status line was never flipped and nothing was committed. Foreman
correctly detected the dirty tree and stopped for a human (`lib/foreman-loop.sh` case 3,
line ~445) — that part worked as designed — but a human then has to manually review,
flip the status, and commit by hand for every ticket this happens to, which defeats the
point of an unattended batch run.

**Root cause:** the model has general-purpose background-task tooling (used correctly in
interactive sessions, where a later turn really does receive the notification) and
nothing in the foreman-authored prompt tells it that *this* session is the one context
where that tool's premise is false. Absent that, the model reasonably reaches for its
normal pattern on a slow command.

**Suggested fix:** add a line to `lib/prompt.template.md`, near `__VERIFY_BLOCK__` in
step 3 (and optionally repeated near step 5), stating plainly that this is a single,
non-interactive turn with no later turn to receive a background result — so check/test
commands must be run in the foreground and waited on synchronously, however long they
take, rather than backgrounded. This is a one-line addition to the shared template that
fixes it for every batch at once, rather than something each batch's `foreman.conf` author
has to independently discover and patch via `prompt-extra.md`.

**Workaround used (per-batch, not a fix):** added this instruction to
`.scratch/sinkhorn-speedup/issues/prompt-extra.md` in `pixel-diffusion`, which
`FOREMAN_PROMPT_EXTRA` splices into that batch's prompt automatically. Confirmed via
`foreman dry-run` that it appears in the assembled prompt. This only protects that one
batch — every other/future batch, in every repo, remains exposed until the shared
template is fixed.

---

## 6. CONFIRMED — limit-detection patterns don't cover the actual session-limit message,
so a mid-iteration usage-limit hit is misreported as a generic "left uncommitted changes"
stop instead of foreman's own clean pause-and-resume path

**Severity:** Medium-High. Not data-losing (the loop still stops safely), but it hides
the real cause and denies the user the tool's own better UX for exactly this situation —
a clean `PAUSED: usage limit reached · resets HH:MM` message with a ready-to-copy resume
command (`lib/foreman-loop.sh:422-426`, the `limit_hit` branch, which exits **10** and is
meant to be indistinguishable from "just rerun the same command").

**Where:** `lib/foreman-record.cjs:101-109`:

```js
const LIMIT_PATTERNS = [
  'usage limit reached',
  'rate limit',
  'rate_limit_error',
  'quota exceeded',
  'credit balance is too low',
  'insufficient credit',
  'billing'
];
const limitHit = LIMIT_PATTERNS.some((p) => haystack.includes(p));
```

**Observed:** ticket `02-profile-n96-solve.md`'s iteration ran 45 minutes ($2.35, 65,611
billed tokens) and ended with the CLI reply:

> "You've hit your session limit · resets 4:50pm (Europe/Ljubljana)"

None of `LIMIT_PATTERNS` matches that phrasing (`"session limit"` is not `"usage limit
reached"`, and there is no `"rate limit"`/`"quota"`/`"billing"` substring in it either),
so `limitHit` came back `false`. Something else in the raw payload did match
`TRANSIENT_PATTERNS` (the log shows `TRANSIENT ERROR SIGNAL DETECTED`), but that
classification never reaches the loop's `limit_hit` branch — it only affects the
same-run retry decision (`foreman-loop.sh:477-483`), and that retry never got a chance to
fire because the tree was left dirty by the interrupted iteration (one untracked scratch
file), which is checked earlier in the branch order (`foreman-loop.sh:445-451`) and always
wins. So the user just saw:

```
02-profile-n96-solve.md left uncommitted changes behind. Stopping so you can look.
?? tests/profile_sinkhorn.js
```

— exit **20** ("needs a human"), with no mention anywhere in the terminal output that
this was a session/usage limit at all, let alone when it resets. The information *was*
in the run log (`foreman-runs.log`, the "TRANSIENT ERROR SIGNAL DETECTED" line and the raw
reply text underneath it), but nothing surfaces it in the immediate `foreman run` output
the way the `limit_hit` path does.

**Root cause:** `LIMIT_PATTERNS` was evidently written against one specific historical
wording of Claude Code's limit message (`"usage limit reached|<epoch>"`, per the comment
at `foreman-record.cjs:159-161`) and never updated for `"You've hit your session limit"`,
which this session's CLI build actually emits. The two messages are the same underlying
event (the 5-hour usage window) worded differently.

**Suggested fix:** add `'session limit'` (and ideally `'hit your'` or a broader
`/\b(session|usage)\s+limit\b/i` match) to `LIMIT_PATTERNS`, and extend the
`resetMatch` regex at `foreman-record.cjs:163` to also parse the human-readable
`"resets 4:50pm (Europe/Ljubljana)"` form, not just the `usage limit reached|<epoch>`
pipe-delimited form — the epoch form may be specific to one CLI output mode while
`--print --output-format json` apparently returns the human-readable one. Whoever fixes
this should capture a real example payload first (this session's raw JSON reply, still
in `.scratch/sinkhorn-speedup/issues/foreman-runs.jsonl` in `pixel-diffusion` at run id
`20260907T130740Z-1332`) rather than guessing the exact field/format.

**Workaround used:** none needed structurally — the loop's dirty-tree stop is safe by
design, it just under-explains itself. Manually confirmed the local clock was already
past the stated reset time, deleted the one stray untracked file
(`tests/profile_sinkhorn.js`, incomplete scratch work from the interrupted attempt, ticket
never landed so nothing depended on it), and resumed with a plain `foreman run 2` — no
special resume procedure was actually needed once the tree was clean.

---

## 7. CONFIRMED — a ticket whose deliverable is large enough to consume a full turn ends
uncommitted, with no way to resume mid-ticket; the next iteration starts over from zero

**Severity:** Medium-High. Not data-losing by itself (the file survives on disk, foreman's
dirty-tree stop catches it), but it wastes a full paid iteration and forces a manual
commit-and-continue step for any ticket whose "write the deliverable" half and "run it /
report findings / commit" half don't both fit in one turn.

**Where:** structural, same single-shot-turn root as issue 5 (`lib/exec/local.sh:17`,
`lib/exec/_sbx.sh:70`) — no specific line to point at beyond that.

**Observed (this session, ticket `02-profile-n96-solve.md` in `pixel-diffusion`):** the
ticket asked for a ~340-line diagnostic script *plus* running it at three sizes *plus*
recording findings in the ticket's Comments *plus* committing. One iteration ran 449s,
billed 37,408 output tokens, and `exit 0`/success — but had only written the script
(`tests/profile_sinkhorn_n96.js`, verified afterward to be correct: passes its own
`--selftest`) before the turn ended. It never ran the script against the fixtures, never
touched `progress.txt`, never touched the ticket's Comments/checklist, and never
committed. Foreman's dirty-tree check correctly stopped the run:

```
02-profile-n96-solve.md left uncommitted changes behind. Stopping so you can look.
?? tests/profile_sinkhorn_n96.js
```

— same safe-but-uninformative stop as issues 5 and 6, third distinct root cause hitting
the identical symptom. Resolved manually by inspecting the file, confirming it worked,
and committing it by hand so the next iteration could build on it instead of
regenerating it from scratch.

**Root cause:** nothing about foreman's per-ticket loop lets an iteration "spend" more than
one turn on a ticket, and nothing paces the agent's own work within that turn against how
much of the ticket it can realistically finish — a large-but-single ticket (write code +
run it + report + commit) can exceed what one turn's output budget covers, and when it
does, everything after the point it stopped is simply not attempted, with no signal to
either the agent or the next iteration about *how much* of the ticket got done. Related:
`foreman-record.cjs:193` captures `session_id` from every run but nothing in the toolkit
ever reads it back — there is no `claude --resume <session_id>` path anywhere in
`lib/exec/`, so even though the underlying CLI supports resuming a specific session, foreman
always starts the next iteration as a brand-new session with only `progress.txt`'s tail
and the ticket file itself as context, never the actual turn that got cut off.

**Suggested fix (design only, not implemented — see note below):** two independent
angles, not mutually exclusive:
- Use the already-captured `session_id` to `claude --resume` the same session for the
  next iteration on a ticket that stopped dirty-but-not-failed, instead of starting cold
  — the model would still have its own prior turn's context (what it already wrote, why)
  rather than having to reconstruct intent from the file on disk.
- Have the loop treat "iteration ended with uncommitted new files, `exit 0`, no error
  signal" as a distinct case from a genuine dirty-tree conflict — e.g. auto-commit the
  untracked work as a WIP checkpoint (clearly labeled, not claiming the ticket is done)
  before continuing, similar to a `git stash`/checkpoint step, so the tree is clean for
  the next iteration without a human doing it by hand every time this shape of partial
  turn occurs.

**Explicitly out of scope for this session:** an early draft of the second idea above
(stash-based WIP preservation) was implemented directly in this checkout during this
session, then fully reverted at the user's explicit instruction — this report documents
the *idea* for whoever picks the fix up, not a patch that exists anywhere. No code
changes from that exploration remain in `C:\Projects\foreman`.

---

## 8. NOT A BUG — feature request: live progress visibility while an iteration is running

**Severity:** N/A (usability/UX request, not a defect).

**What's missing:** right now, once `foreman run` invokes `claude --print --output-format
json -p "..."` (`lib/exec/local.sh:17`, `lib/exec/_sbx.sh:70`), the terminal goes
completely silent until that single call returns — which, per issues 5/6/7 above, can be
7-plus minutes (449s, 536s) or run all the way to a session-limit cutoff (45 minutes).
There is no way from the terminal to tell "is this iteration still working," "how long
has it been running," or "what has it done so far" without opening a second shell and
tailing `foreman-runs.log`/`foreman-runs.jsonl` by hand.

**Requested, two parts:**

1. **A live minute counter as soon as an iteration starts**, so it's visible at a glance
   in the terminal that the loop is alive and how long the current iteration has been
   running — e.g. `02-profile-n96-solve.md: running... 03:12` ticking in place. This is
   pure wall-clock display, doesn't need anything from the model.

2. **Coarse "what is it doing right now" visibility, without spending extra model
   invocations to get it.** For example, surfacing something like `writing to
   tests/profile_sinkhorn_n96.js` in the terminal as the agent works, derived from tool
   calls already happening (file writes, commands run) rather than from an extra
   "summarize your status" prompt round-trip that would cost tokens. `--output-format
   json` collects the whole transcript and only emits it at the end; getting incremental
   visibility would likely mean switching to (or additionally parsing) a streaming output
   mode (e.g. `--output-format stream-json`) and rendering each tool-use event's target
   (file path / command) as a one-line status update, discarding the rest.

**Why this matters given issues 5-7 above:** all three of those describe an iteration
silently doing something for a long time and then ending in a state a human has to
untangle after the fact. Live visibility wouldn't fix any of the three root causes, but
it would let a human watching notice *while it's happening* — e.g. see it start a
background verify command (issue 5's failure mode) or see it still writing new files at
minute 7 with no commit yet (issue 7's failure mode) — instead of finding out only after
the CLI call has already returned and the loop has already stopped.

**Status:** not investigated further this session — flagging as a discussion item. Marked
explicitly "we should discuss it more with a grilling session when we get to it" (direct
request from whoever picks this up should read that as: don't just implement the first
idea that fits, sit down and hash out the actual UX/implementation approach first,
including whether `stream-json` is worth the switch and how much of its output is safe/
useful to surface without leaking full transcript content into every terminal).

---

## 9. `FOREMAN_EXEC=local`'s default permission mode can't commit — every iteration that
reaches `git add`/`git commit` fails and stops the loop

**Severity:** High (silent, and it compounds — see below).

**Where:** `lib/foreman-config.sh:200` (`FOREMAN_PERMISSION_MODE="${FOREMAN_PERMISSION_MODE:-acceptEdits}"`),
`lib/exec/local.sh:17` (`claude ... --permission-mode "$FOREMAN_PERMISSION_MODE" --print
--output-format json -p "$1"`).

**Observed:** on the `sinkhorn-speedup` batch (`FOREMAN_EXEC=local`, `foreman.conf` had no
`FOREMAN_CLAUDE_ARGS` set), three separate iterations in a row (tickets 03, 06, 07) each
did real, correct, verified work — code changes, regression pins, or a correctly-reasoned
"gate unmet, closing unstarted" — and then hit `git add`/`git commit` returning "this
command requires approval" with no live approver to grant it (this is `--print` mode:
there is no terminal for a permission prompt to go to). Each iteration recorded the
failure in `progress.txt` and ended with the ticket's changes fully done but uncommitted.
`foreman run`'s own dirty-tree guard then correctly refused to start the next iteration on
top of the leftover diff and stopped the batch — so from the terminal this looked like
"why did it only run 1 of 3 iterations," once per ticket, every time.

**Root cause:** `FOREMAN_PERMISSION_MODE` defaults to `acceptEdits`, which auto-accepts the
Edit/Write tools but not the Bash tool — and `git add`/`git commit` go through Bash. In
`FOREMAN_EXEC=local`'s non-interactive `--print` session there is no fallback prompt and no
human to answer one, so a Bash call outside an explicit allowlist doesn't pause, it just
fails permanently for that iteration. `foreman.conf`'s own template gestures at the fix
(`#FOREMAN_CLAUDE_ARGS=(--allowed-tools Bash Read Edit)`, commented out, and even that
example is broader than needed) but nothing in `foreman init`'s scaffolding, `foreman doctor`,
or the prompt template checks for or warns about this — a fresh `FOREMAN_EXEC=local` batch
is one dirty-tree stop away from discovering it, once per repo, the hard way.

**Compounding effect:** because the failure happens *after* the model has already done
the ticket's work (code, tests, progress notes) and *after* billing for that iteration,
this isn't a cheap fast-fail — each stop costs a full iteration's tokens/time/money
(observed: $0.29–$0.50 and 10–13 minutes per stop across tickets 03/06/07) for zero
net progress on the batch, on top of the manual `git add`/`git commit` a human then has
to do by hand before the loop can continue.

**Suggested fix:** either (a) have `foreman init`'s generated `foreman.conf` ship
`FOREMAN_CLAUDE_ARGS=(--allowed-tools "Bash(git add:*)" "Bash(git commit:*)")` uncommented
by default for `FOREMAN_EXEC=local` (or fold it into `exec_commit_note`/the local adapter
itself, since it already owns the "this mode commits directly into the tree" framing —
see `lib/foreman-prompt.sh:77-87`), or (b) have `foreman doctor` / `exec_preflight` in
`lib/exec/local.sh` detect that git-write tools aren't allowlisted under
`acceptEdits`/`--print` and fail loud before spending any money, instead of failing loud
only after the first ticket pays for it.

**Workaround applied this session:** added
`FOREMAN_CLAUDE_ARGS=(--allowed-tools "Bash(git add:*)" "Bash(git commit:*)")` to
`pixel-diffusion`'s `.scratch/sinkhorn-speedup/issues/foreman.conf` directly. Not verified
yet against a live `foreman run` as of this writing — flagging in case the exact
`--allowed-tools` pattern syntax needs adjustment (the `claude --help` text shows
`Bash(git *)` as its own example, which would be broader/simpler if the narrower
two-pattern form above turns out not to match).

---

## Summary for whoever picks this up

| # | Issue | Severity | Confirmed? | File(s) |
|---|-------|----------|------------|---------|
| 1 | `&` in `FOREMAN_*_CMD` corrupts rendered prompt via bash's sed-style replacement expansion | High (silent) | Yes, minimal repro included | `lib/foreman-prompt.sh:102-111` |
| 2 | `FOREMAN_EXEC=sandbox` default is fully blocked — `sbx create --clone`'s actual `origin` doesn't match `_sbx_is_clone_mode`'s expectation | High (blocking) | Yes, reproduced twice | `lib/exec/_sbx.sh:13-15,33-39`, `lib/exec/sandbox.sh` |
| 3 | `foreman order` ticket-count log line said 1 for a 9-ticket batch; output itself was correct | Low | No — anomaly observed, cause not isolated | `lib/foreman-order.sh:57-106` |
| 4 | `FOREMAN_ISSUES_DIRS` default silently finds 0 tickets for `foreman init`'s own scaffolding shape; error messages don't name the resolved path | Low (UX) | Yes, behavior confirmed; not calling it a bug per se | `foreman.conf` defaults / `foreman-status`/`foreman order`/`foreman doctor` messaging |
| 5 | Shared prompt template never states the session is single-shot (`--print`, no later turn), so an agent can background a slow verify command and end its turn waiting on a notification that can never arrive — ticket fully done in spirit but never landed | High (silent) | Yes, reproduced once, root cause structural (`--print` mode) | `lib/prompt.template.md` (step 3/5), `lib/exec/local.sh:17`, `lib/exec/_sbx.sh:70` |
| 6 | `LIMIT_PATTERNS` doesn't match "You've hit your session limit" — a real mid-run usage-limit hit is misreported as a generic dirty-tree stop instead of foreman's own clean pause/resume message | Medium-High | Yes, reproduced once | `lib/foreman-record.cjs:101-110,159-169` |
| 7 | A ticket whose deliverable exceeds one turn's output budget ends partially done and uncommitted, with no mid-ticket resume — captured `session_id` is never reused, next iteration starts cold | Medium-High | Yes, reproduced once, third distinct root cause hitting the same dirty-tree symptom as 5/6 | structural (`lib/exec/local.sh:17`, `lib/exec/_sbx.sh:70`); `foreman-record.cjs:193` (`session_id` captured, unused) |
| 8 | Not a bug — feature request: live minute counter + coarse "what it's doing" status while an iteration runs, without extra model invocations | N/A (UX) | N/A — request, not observed defect | `lib/exec/local.sh:17`, `lib/exec/_sbx.sh:70` (`--print --output-format json`, no incremental output today) |
| 9 | `FOREMAN_EXEC=local` defaults to `acceptEdits`, which doesn't cover Bash — `git add`/`git commit` fail "requires approval" with no live approver, once per ticket, after the ticket's work is already done and billed | High (silent, compounds cost) | Yes, reproduced 3x in a row (tickets 03, 06, 07) | `lib/foreman-config.sh:200`, `lib/exec/local.sh:17`; `foreman.conf`'s commented-out `FOREMAN_CLAUDE_ARGS` template |

**Note on 1-4:** a separate session fixed and pushed these four (not 5, 6, 7, 8, or 9) to branch
`worktree-fix-4-bugs` (commit `f14edf3`, 94/94 smoke tests passing, PR not yet opened
against `main`) — not merged as of this writing, so they're still present in whatever
checkout runs against `main`.

Environment: Windows 11, Git Bash, foreman at `c8456fc` (up to date with its own
`origin/main`), tested against `C:\Projects\pixel-diffusion`.
