# Assumptions

This toolkit was generalised from two rounds of single-purpose scripts:
`.scratch/qa-response/` (round 2) and `.scratch/qa-round-3/` (round 3, the mature set).
Both were hard-wired to this repo — `npm run check`, `npm test`, `better-sqlite3`, a
specific order file, a specific progress file.

It then moved out of that repo entirely and became a machine-wide install; see *Where the
toolkit lives*, below.

Below is everything that was a judgement call rather than a straight lift, and how to undo
each one. Anything not listed here is unchanged behaviour from the round-3 scripts.

Where this file says "this repo", it means the repo a batch lives in — never this toolkit.

---

## Where the toolkit lives

**Assumed:** the toolkit is cloned once per machine and put on PATH as `foreman`. It is not
vendored into the repositories it works on.

Nothing in the code ever required it to be inside the repo: `FOREMAN_TOOL_DIR` comes from
`${BASH_SOURCE[0]}`, `REPO_ROOT` from `git rev-parse` in the caller's working directory, and
every batch path is resolved against the latter. The only things that assumed otherwise were
help text and error messages naming a literal `tools/foreman/…` path. Vendoring would mean a
fix has to be made once per project, which is the thing this move exists to prevent.

`FOREMAN_INVOKE` is how a message names the command: `foreman`, exported by `bin/foreman`, or the
install's absolute path when a `lib/` script is called directly. Like `FOREMAN_TOOL_DIR` and
`FOREMAN_BATCH` it is set before the environment snapshot in `foreman-config.sh`, so a batch's
`foreman.conf` cannot override it.

*To undo:* copy `lib/` into a repo and call the scripts directly. Everything works; the
messages print the script's path instead of `foreman`, and that repo still needs the
`.gitignore` / `.gitattributes` lines `foreman doctor` describes.

## Path resolution belongs in one file

**Assumed:** `foreman-repo.sh` is the only place that answers "where is the repo" and "where is
this batch inside it". `foreman-config.sh`, `foreman-init.sh` and `foreman-doctor.sh` all go
through it.

Round 3 had this logic twice — in `foreman-config.sh` and `foreman-init.sh` — as a
`realpath --relative-to` attempt with a prefix-strip fallback. Both copies compared two
absolute paths normalised through `cd`+`pwd`, which is correct only when both spellings
resolve the same way. They do not under a Git Bash mount alias: a repo reached as `/tmp/x`
and as `/c/Users/…/Temp/x` is one directory, and `cd C:/Users/…` normalises to the second
while the caller's `pwd` says the first. `foreman init` then refused a batch that was plainly
inside the repo. A real bug, caught while testing the extracted toolkit in a second
repository — the exact scenario this extraction exists to support.

The fix is to stop doing arithmetic on paths. `git rev-parse --show-prefix`, run from inside
the batch directory, *is* the repo-relative path, and git has already resolved the alias,
the symlink and the drive-letter spelling. `--show-toplevel` from the same directory then
confirms the batch is in the repository we mean rather than a different one.

*To undo:* the two functions are self-contained and pure; reinstate the `realpath` block in
each caller.

## Repo setup is a command, not a paragraph of README

**Assumed:** the two files a consuming repo must provide — three `.gitignore` patterns and
one `.gitattributes` line — are worth a `foreman doctor --fix` rather than instructions.

They are easy to get subtly wrong (an unanchored `foreman-runs.log` catches unrelated files;
the `.gitattributes` line matters only where the repo normalises line endings at all), easy
to forget entirely, and the failure from forgetting them is remote from its cause. `--fix`
only ever appends, and never touches a batch or a ticket, so it cannot destroy an existing
arrangement.

`doctor` deliberately does not source `foreman-config.sh`: that resolves a batch and fails when
there is none, and the point of `doctor` is to run *before* the first `foreman init`. It shares
`foreman-repo.sh` instead, which is the part that has to agree.

## Help text is the header comment, not a line range

Three scripts print their own leading comment block as `--help`. They did it with
`sed -n '2,60p'`, and the number had already drifted: `foreman-loop.sh --help` printed nine
lines of its own source. They now stop at the first line that is not a comment, so the
range cannot go stale again.

## What makes a directory a batch

**Assumed:** a directory is a foreman batch if and only if it contains a `foreman.conf` —
even an empty one.

Nothing else distinguishes a directory of tickets from any other directory of markdown,
and the alternative (a registry file listing batches) would be shared state, which is the
thing this reorganisation exists to remove. `foreman.conf` doubles as the marker and the
config, so `--status` on a batch never needs a second file to be in agreement.

*To undo:* nothing depends on the name except `foreman-config.sh`'s search and
`foreman-report.cjs`'s. Both look for the literal string `foreman.conf`.

## Omitting the batch argument

**Assumed:** when no batch is named and exactly one directory in the repo has a
`foreman.conf`, that is the batch. Two or more, and the tools refuse and list them.

A repo with one batch is the common case and typing its path every time is noise. A repo
with several has no defensible default — "most recently modified" would silently run the
wrong batch after an unrelated edit.

The search skips `node_modules`, `.git`, `.svelte-kit` and any `worktrees` directory. That
last one matters: `.claude/worktrees/` holds full copies of the repo, so without it every
batch would appear once per worktree.

*To undo:* delete the auto-detect block near the top of `foreman-config.sh` and make the
argument mandatory.

## Ordering: the order file is optional

**Assumed:** if `<batch>/order.md` exists it is authoritative; if it does not, every `*.md`
under `FOREMAN_ISSUES_DIRS` runs in filename order.

Round 2 had one issues directory with `NN-` prefixes and let the model pick from
`**Blocked by:**` lines. Round 3 spanned two directories whose numbering collided, so the
order moved into a file the loop parses. Both shapes are legitimate, so both are supported:
a small batch needs no order file, a batch spanning directories needs one.

**Not carried over:** `**Blocked by:**` resolution. Round 2's prompt asked the model to
read those lines and pick the lowest-numbered unblocked ticket. Nothing here parses them —
filename order is the contract, and a dependency filenames cannot express belongs in
`order.md`. Ticket files may still carry `Blocked by:` lines as prose for the reader, and
the prompt still tells the agent to stop rather than implement a missing dependency.

*To undo:* teach `foreman-next.sh` to parse the line before the `done_count` loop; the
ticket list is already in memory at that point.

## Ordering: `foreman init` has an agent order the tickets, by default

**Assumed:** filename order is a poor default for anything but a trivial batch, so
`foreman init` doesn't stop at generating `order.md` in filename order — it hands the batch to
a second script, `foreman-order.sh`, which reads every ticket and rewrites the order and the
reasoning above it, weighing dependencies, importance and each ticket's apparent load.
`--no-order` opts out; `foreman order <batch>` re-runs it by hand later.

This runs `claude` **locally, never in a sandbox**, regardless of the batch's `FOREMAN_EXEC`.
It edits no code — only `order.md` — so none of the reasons `sandbox` mode exists (native
modules, isolation from a real run) apply, and it should work in a repo that has no sandbox
set up at all yet. It is also the one agent call in this toolkit that isn't gated by any of
`FOREMAN_MAX_COST_USD` / `FOREMAN_MAX_MINUTES` — those budget a *run*, and ordering happens once,
outside of one.

It is a first pass, not a guarantee: nothing here verifies the order it picked is correct,
only that it read every ticket in the directory and didn't invent or drop one. Ticket text
is the only signal it has — a constraint that exists only in a person's head still has to go
in `order.md`'s prose by hand.

**Not done:** no cost cap on the ordering call itself, and no `--dry-run` for it (unlike
`foreman run`, there is no code to preview — the prompt sent is deterministic from the ticket
list, and printing it without sending would just be `cat`). If a batch is large enough that
one ordering call is itself worth previewing, that is a sign of a batch worth splitting.

*To undo:* pass `--no-order` at the call site, or delete the `foreman-order.sh` call in
`foreman-init.sh` to make it opt-in via `foreman order <batch>` instead of automatic.

## Ordering: an order entry may be repo- or batch-relative

**Assumed:** a line in the ORDER block resolves first against the repo root, then against
the batch directory.

Round 3's `order.md` listed full repo-relative paths, because its tickets lived outside its
own directory (`.scratch/qa-round-3/order.md` pointing at `.scratch/qa-round-3-ui/issues/`).
A self-contained batch would rather write `issues/01-foo.md`. Accepting both costs one
`if`, and an entry that resolves to neither is a hard error with the offending line quoted.

## The prompt: one template, filled from config

**Assumed:** the five-step structure (agree the seams → implement → verify → review → land)
is universal, and only the *commands* differ between projects.

That structure survived both rounds unchanged and is not project-specific. What was
project-specific — `npm run check`, `npm test`, `npx vitest run <file>`,
`mattpocock-skills:tdd`, `mattpocock-skills:code-review` — is now four config slots.

**A slot left empty degrades to prose, it does not vanish.** With no `FOREMAN_CHECK_CMD` and
no `FOREMAN_TEST_CMD` the Verify step reads "run whatever this repo uses to type-check, lint
and test (check package.json, Makefile, or the contributing docs — and say in the progress
file what you settled on)". A dangling empty bullet, or a step that silently disappeared,
would be worse than either.

*To undo:* `prompt.template.md` is plain text with `__SLOT__` markers; edit it freely. The
slot values are computed at the top of `foreman-prompt.sh`.

## The prompt: `prompt-extra.md` goes between Verify and Review

**Assumed:** one splice point is enough, and that is the right one.

Round 3's only genuinely project-specific prompt text was the Playwright instruction, and
it lived inside Verify. Extra guidance is usually about *how thoroughly to check something*,
which reads correctly there. Multiple named splice points would be more flexible and more
to get wrong.

*To undo:* move the `__PROMPT_EXTRA__` marker in `prompt.template.md`. Nothing else knows
where it is.

## The prompt: free text is concatenated, not substituted

Both free-text blocks — `prompt-extra.md` and the progress excerpt — are spliced by string
concatenation rather than `${var//__X__/$value}`. Bash's pattern substitution treats
backslashes in a replacement as escapes, which would quietly mangle any Windows path or
regex written in those files. The short config slots still use substitution: they are
author-written command names, and the readability is worth it.

## Execution modes

**Assumed:** `sandbox` (private clone) stays the default, and `sandbox-mount` and `local`
are added.

The clone is forced for *this* repo — see `.scratch/qa-round-3-ui/issues/14` — but the
constraint behind it is specific: a native module compiled for the host that the container
cannot load. A repo without one loses nothing by bind-mounting, and a repo without `sbx`
set up should not be blocked from using the loop at all.

The default stays `sandbox` because it is the mode that cannot silently half-work: a
bind-mount whose dependency tree is subtly wrong fails *after* the model's work is paid
for. `FOREMAN_SANDBOX_PROBE` exists to catch exactly that before anything is spent.

**In `local` mode the agent runs unsandboxed in your working tree, with
`--permission-mode acceptEdits`.** That is what "no isolation" means; use it on a repo and
a branch where that is acceptable.

*To undo:* each mode is one file in `lib/exec/` — delete the two sandbox adapters and
`local` is all that is left. See *`FOREMAN_EXEC` is a seam, not a set of conditionals*,
below, for how they stopped being three branches in `foreman-loop.sh`.

## Config precedence

**Assumed:** environment beats `foreman.conf` beats defaults.

`foreman.conf` is sourced as bash, so it would ordinarily clobber the environment. Instead
every `FOREMAN_*` variable present before sourcing is snapshotted and restored afterwards, so
`FOREMAN_MAX_COST_USD=10 foreman run <batch>` works without editing a file. This relies on no
foreman script setting a `FOREMAN_*` variable before sourcing `foreman-config.sh` — `FOREMAN_BATCH`,
`FOREMAN_TOOL_DIR`, `FOREMAN_HOME` and `FOREMAN_INVOKE` are the deliberate exceptions. All four
are set before the snapshot is taken, so they are snapshotted and restored like anything
from the environment, which is exactly right: a batch's `foreman.conf` has no business
redefining where the toolkit is or what it is called.

## Renamed artifacts

**Assumed:** the per-batch logs are worth renaming from `runs.jsonl` / `runs.log` to
`foreman-runs.jsonl` / `foreman-runs.log`.

They can now live in any directory, so they need names that say what they are and that a
`**/`-anchored gitignore rule can match without catching an unrelated `runs.log`. The
existing `.scratch/qa-round-3/` logs were renamed in place; they were untracked, so no
history moved.

## Windows path handling

Three spellings of one directory are all in play at once:

- `git rev-parse --show-toplevel` answers `C:/Projects/x`, `pwd` answers `/c/Projects/x`;
- a Git Bash mount alias makes `/tmp/x` and `/c/Users/…/Temp/x` the same directory;
- `realpath --relative-to` hands back the absolute path rather than failing when it cannot
  relate two paths written in different syntaxes.

Every one of those has caused a real failure here, none of them hypothetically. All of it
is now confined to `foreman-repo.sh`, which asks git for the answer instead of computing it —
see *Path resolution belongs in one file*. Nothing else in the toolkit does path
arithmetic, and nothing else should start.

## Requirements

Bash 4+ (associative arrays, `compgen -v`), `git`, `node`, `awk`, plus `sbx` in the sandbox
modes or `claude` on `PATH` in `local` mode. The loop's preflight checks all of these and
exits 1 before spending anything; `foreman doctor` checks the same set ahead of time, and
works out from the batches present which of `sbx` and `claude` actually matters here.

---

## `FOREMAN_EXEC` is a seam, not a set of conditionals

**Assumed:** where the agent runs is an adapter in `lib/exec/`, loaded once by
`foreman-exec.sh`, and no caller ever asks which mode is in force.

Before this, three arrangements existed — `sandbox`, `sandbox-mount`, `local` — with no
interface between them and the loop. The mode was re-decided at eleven points across four
files, in three spellings: `exec_uses_sandbox` / `exec_uses_clone` in `foreman-loop.sh`, a
bare `[ "$FOREMAN_EXEC" = "sandbox" ]` in `foreman-prompt.sh` for the commit note, and a
`grep FOREMAN_EXEC` over every batch's `foreman.conf` in `foreman-doctor.sh`. Three adapters
existed; the interface did not.

The interface is ten functions, documented at the top of `foreman-exec.sh`. Adapters read
only `FOREMAN_*` and `REPO_ROOT`, never a caller's locals, which is what lets `doctor` load
one and ask `exec_required_tool` without a batch resolved. `foreman-config.sh` no longer
holds a list of valid modes either: a mode is valid when `lib/exec/<mode>.sh` exists.

The point of it is the fourth adapter. `fake` answers the same interface with no model and
no container, so the loop's budgets, attempt accounting, verdict handling and all five stop
conditions can be exercised for nothing — see `test/smoke.sh`, which is the first test this
toolkit has had. Every bug listed above this line was caught in the field, by running it.

*To undo:* the adapters are self-contained; inline `lib/exec/sandbox.sh` and
`lib/exec/local.sh` back into `foreman-loop.sh` and reinstate the two predicates.

## One place answers "what tickets does this batch have"

**Assumed:** `foreman-next.sh --unordered` is that place, and `foreman-init.sh` and
`foreman-order.sh` call it.

All three used to scan for tickets themselves, and the copies disagreed. `foreman-next.sh`
honoured `FOREMAN_ISSUES_DIRS` and `FOREMAN_ISSUES_EXCLUDE`; the other two hard-coded
`<batch>/issues` and a literal `README.md|spec.md|order.md`. A batch whose `foreman.conf`
pointed its tickets anywhere else was therefore scaffolded from an empty directory, and
then handed to the ordering agent as a list of nothing — while `foreman run` worked fine on
the same batch.

`--unordered` rather than the existing `--all` because both callers need the tickets the
batch *has*, not the order someone already wrote: `init --force` regenerates `order.md`
and must not read the file it is about to replace, and `foreman order` exists to be re-run
after tickets change. It is also the one mode for which an empty answer is not an error —
a batch with no tickets yet is exactly what `foreman init` is there to scaffold.

*To undo:* reinstate the `find` block in each caller. `--all` had no callers before this
and still has none; it is a user-facing mode.

---

## What was deleted

These were changes in the `excuse-me` repo, where the toolkit was born. They are recorded
here because that is where the history is, not because this toolkit still has anything to
do with that repo.

Both rounds are complete (11/11 and 21/21), so nothing was mid-flight when this landed.

- `.scratch/qa-round-3/`: `foreman-loop.sh`, `foreman-next.sh`, `foreman-prompt.sh`,
  `foreman-record.cjs`, `foreman-report.cjs`, `README.md` — superseded by `tools/foreman/`. The
  batch keeps `order.md`, `progress.txt` and its tickets, and gained a `foreman.conf` and a
  `prompt-extra.md` that reproduce its old behaviour exactly.
- `.scratch/qa-response/`: `foreman-loop.sh`, `foreman-once.sh`, `foreman-prompt.sh`,
  `foreman-usage-summary.cjs` — already superseded before this change (`foreman-loop.sh 1` is
  what `foreman-once.sh` was, and `foreman-report.cjs` reads a log that outlives the run). It
  gained a `foreman.conf` so its history stays readable, and is the worked example of the
  no-order-file case.

All of it is recoverable from git history.
