# Assumptions

This toolkit was generalised from two rounds of single-purpose scripts:
`.scratch/qa-response/` (round 2) and `.scratch/qa-round-3/` (round 3, the mature set).
Both were hard-wired to this repo — `npm run check`, `npm test`, `better-sqlite3`, a
specific order file, a specific progress file.

Below is everything that was a judgement call rather than a straight lift, and how to
undo each one. Anything not listed here is unchanged behaviour from the round-3 scripts.

---

## What makes a directory a batch

**Assumed:** a directory is a ralph batch if and only if it contains a `ralph.conf` —
even an empty one.

Nothing else distinguishes a directory of tickets from any other directory of markdown,
and the alternative (a registry file listing batches) would be shared state, which is the
thing this reorganisation exists to remove. `ralph.conf` doubles as the marker and the
config, so `--status` on a batch never needs a second file to be in agreement.

*To undo:* nothing depends on the name except `ralph-config.sh`'s search and
`ralph-report.cjs`'s. Both look for the literal string `ralph.conf`.

## Omitting the batch argument

**Assumed:** when no batch is named and exactly one directory in the repo has a
`ralph.conf`, that is the batch. Two or more, and the tools refuse and list them.

A repo with one batch is the common case and typing its path every time is noise. A repo
with several has no defensible default — "most recently modified" would silently run the
wrong batch after an unrelated edit.

The search skips `node_modules`, `.git`, `.svelte-kit` and any `worktrees` directory. That
last one matters: `.claude/worktrees/` holds full copies of the repo, so without it every
batch would appear once per worktree.

*To undo:* delete the auto-detect block near the top of `ralph-config.sh` and make the
argument mandatory.

## Ordering: the order file is optional

**Assumed:** if `<batch>/order.md` exists it is authoritative; if it does not, every `*.md`
under `RALPH_ISSUES_DIRS` runs in filename order.

Round 2 had one issues directory with `NN-` prefixes and let the model pick from
`**Blocked by:**` lines. Round 3 spanned two directories whose numbering collided, so the
order moved into a file the loop parses. Both shapes are legitimate, so both are supported:
a small batch needs no order file, a batch spanning directories needs one.

**Not carried over:** `**Blocked by:**` resolution. Round 2's prompt asked the model to
read those lines and pick the lowest-numbered unblocked ticket. Nothing here parses them —
filename order is the contract, and a dependency filenames cannot express belongs in
`order.md`. Ticket files may still carry `Blocked by:` lines as prose for the reader, and
the prompt still tells the agent to stop rather than implement a missing dependency.

*To undo:* teach `ralph-next.sh` to parse the line before the `done_count` loop; the
ticket list is already in memory at that point.

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

**A slot left empty degrades to prose, it does not vanish.** With no `RALPH_CHECK_CMD` and
no `RALPH_TEST_CMD` the Verify step reads "run whatever this repo uses to type-check, lint
and test (check package.json, Makefile, or the contributing docs — and say in the progress
file what you settled on)". A dangling empty bullet, or a step that silently disappeared,
would be worse than either.

*To undo:* `prompt.template.md` is plain text with `__SLOT__` markers; edit it freely. The
slot values are computed at the top of `ralph-prompt.sh`.

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
for. `RALPH_SANDBOX_PROBE` exists to catch exactly that before anything is spent.

**In `local` mode the agent runs unsandboxed in your working tree, with
`--permission-mode acceptEdits`.** That is what "no isolation" means; use it on a repo and
a branch where that is acceptable.

*To undo:* the modes are three branches in `ralph-loop.sh`, gated by `exec_uses_sandbox`
and `exec_uses_clone`.

## Config precedence

**Assumed:** environment beats `ralph.conf` beats defaults.

`ralph.conf` is sourced as bash, so it would ordinarily clobber the environment. Instead
every `RALPH_*` variable present before sourcing is snapshotted and restored afterwards, so
`RALPH_MAX_COST_USD=10 bash ralph-loop.sh <batch>` works without editing a file. This
relies on no ralph script setting a `RALPH_*` variable before sourcing `ralph-config.sh` —
`RALPH_BATCH` and `RALPH_TOOL_DIR` are the deliberate exceptions and are handled.

## Renamed artifacts

**Assumed:** the per-batch logs are worth renaming from `runs.jsonl` / `runs.log` to
`ralph-runs.jsonl` / `ralph-runs.log`.

They can now live in any directory, so they need names that say what they are and that a
`**/`-anchored gitignore rule can match without catching an unrelated `runs.log`. The
existing `.scratch/qa-round-3/` logs were renamed in place; they were untracked, so no
history moved.

## Windows path handling

`git rev-parse --show-toplevel` answers `C:/Projects/x` while `pwd` answers `/c/Projects/x`,
and `realpath --relative-to` hands back the absolute path rather than failing when it
cannot relate two paths in different syntaxes. Both scripts that compute a repo-relative
batch path round-trip the repo root through `cd`+`pwd` first and reject an absolute answer
from `realpath`. This was a real bug caught in testing, not a precaution.

## Requirements

Bash 4+ (associative arrays, `compgen -v`), `git`, `node`, `awk`, plus `sbx` in the sandbox
modes or `claude` on `PATH` in `local` mode. Preflight checks all of these and exits 1
before spending anything.

---

## What was deleted

Both rounds are complete (11/11 and 21/21), so nothing was mid-flight when this landed.

- `.scratch/qa-round-3/`: `ralph-loop.sh`, `ralph-next.sh`, `ralph-prompt.sh`,
  `ralph-record.cjs`, `ralph-report.cjs`, `README.md` — superseded by `tools/ralph/`. The
  batch keeps `order.md`, `progress.txt` and its tickets, and gained a `ralph.conf` and a
  `prompt-extra.md` that reproduce its old behaviour exactly.
- `.scratch/qa-response/`: `ralph-loop.sh`, `ralph-once.sh`, `ralph-prompt.sh`,
  `ralph-usage-summary.cjs` — already superseded before this change (`ralph-loop.sh 1` is
  what `ralph-once.sh` was, and `ralph-report.cjs` reads a log that outlives the run). It
  gained a `ralph.conf` so its history stays readable, and is the worked example of the
  no-order-file case.

All of it is recoverable from git history.
