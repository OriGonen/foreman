# ralph

A loop that implements one ticket per iteration, until a batch of tickets is done or a
budget stops it. Installed once per machine; point it at any directory of tickets, in any
repository.

```bash
cd <any git repo>
ralph doctor                    # is this repo ready?                  (free)
ralph init .scratch/my-batch    # scaffold a batch, then order its tickets
ralph status .scratch/my-batch  # what is left, what is next, where a human is needed (free)
ralph dry-run .scratch/my-batch # the plan and the exact prompt        (free)
ralph run .scratch/my-batch             # one iteration
ralph run .scratch/my-batch 5           # at most 5 iterations
ralph run .scratch/my-batch --unlimited # until done or a budget stops it
```

Everything marked *(free)* makes no model call and starts no sandbox.

## Install

```bash
git clone <this repo> ~/tools/ralph   # or anywhere you like
bash ~/tools/ralph/install.sh
ralph version
```

`install.sh` writes two small forwarding scripts — `ralph` and `ralph.cmd` — into the first
personal `bin` directory already on your PATH (`~/bin`, then `~/.local/bin`), so both Git
Bash and PowerShell get the same command. `bash install.sh --to <dir>` picks the directory
yourself.

It also copies the `ralph-human-followup-tickets` skill (see "Human tickets" below) into
`${CLAUDE_CONFIG_DIR:-~/.claude}/skills/ralph-human-followup-tickets/` — a copy, not a
symlink, marked with the checkout it came from. Re-running `install.sh` replaces a marked
copy with whatever this checkout now has, no `--force` needed: that is how a pulled update
reaches it. `--no-skill` installs only the shims; `--force` overwrites a same-named
directory (shim or skill) this installer didn't write; `--uninstall` removes both, but
leaves an unmarked directory alone; `ralph doctor` warns, for free, if an installed copy
ever drifts from this checkout.

Move the checkout later and just re-run `install.sh` to re-point the shims.

### Requirements

`git`, `node`, `awk`, and **bash 4+** (associative arrays and `compgen -v`). On Windows that
means Git Bash — there is no separate Windows implementation, and `ralph.cmd` forwards to
it.

Plus, depending on the execution mode a batch asks for: `sbx` for the sandbox modes, or
`claude` on PATH for `local`. `ralph doctor` checks all of this and tells you which one your
batches actually need.

## The one rule: the toolkit is stateless

The install holds nothing. Everything that differs between batches lives in the **batch
directory**, inside the repository being worked on:

| in the batch | what it is |
|---|---|
| `ralph.conf` | the batch's config — the only file that makes a directory a batch |
| `order.md` | the run order (optional — see below) |
| `progress.txt` | the agent's running notes, appended each iteration |
| `prompt-extra.md` | project-specific prompt text (optional) |
| `ralph-runs.jsonl` `ralph-runs.log` | append-only run telemetry, gitignored |
| `.ralph-iter.bundle` | transient; exists only inside one iteration |
| `.ralph-stall-marker` | disposable; left only when a stall could not be salvaged, so a rerun may rescue it — see "Pausing and resuming" |

Two batches never share any of it, and two *repositories* never share any of it either. Run
one, pause it, switch repos, run another, come back — each resumes exactly where it was.
Nothing accumulates in the install.

## Setting up a repository

Once per repo:

```bash
ralph doctor --fix
```

That appends the only two things a repo has to provide itself:

- `.gitignore` — `**/.ralph-iter.bundle`, `**/.ralph-stall-marker`, `**/ralph-runs.jsonl`,
  `**/ralph-runs.log`, so a
  batch's run state stays untracked. The patterns match anywhere because a batch is any
  directory with a `ralph.conf`.
- `.gitattributes` — `ralph.conf text eol=lf`, but only if the repo normalises line
  endings. `ralph.conf` is sourced as bash, and a CRLF checkout would make `RALPH_EXEC` read
  as `sandbox<CR>` and fail validation with a message that looks like a lie.

Review the diff and commit it. `--fix` only ever appends, and never touches a ticket.

## Setting up a batch

A batch is a directory containing tickets. A ticket is a markdown file with a status line:

```markdown
# 01 — do the thing

**Status:** todo

- [ ] the thing is done
```

`ralph init <dir>` writes the three files a batch needs, generating `order.md` from
`<dir>/issues/*.md`, then — unless `--no-order` is given — has an agent read the tickets and
rewrite that order. It never overwrites without `--force`, and it never touches a ticket.

Then edit `<dir>/ralph.conf`. The two lines that matter most are what "verify your work"
means in your project:

```sh
RALPH_CHECK_CMD="npm run check"
RALPH_TEST_CMD="npm test"
```

Everything else has a default; `lib/ralph.conf.template` documents the full set.

### Human tickets

Some steps only a person can do — an owner review, a naming decision, provisioning an
account. Mark a ticket for one on its own status line:

```markdown
# 15 — owner review of the landing-page copy

**Status:** ready-for-human
**Handoff:** .scratch/my-batch/handoff/15-owner-review.md

- [ ] the owner has reviewed the copy and left feedback in the handoff file
```

`RALPH_HUMAN_WORD` (default `ready-for-human`) is the word that marks it; set it empty in
`ralph.conf` to turn the feature off entirely — every ticket is then an agent's, as before.
Reaching a human ticket at the head of the order stops the run **before anything is
spent** — before the sandbox starts, before any budget check, before any prompt is sent —
and exits **30**, naming the ticket and its handoff file. Rerunning before the person has
finished it stops the same way again, at no cost. See "Pausing and resuming" below.

**The handoff file.** The `Handoff:` line names a file the person fills in: what they did,
where it is, what they decided. Record *where* a secret is stored — a vault path, an env
var name — never the secret's value.

**Followup tickets.** A human ticket is immediately followed, in the order, by an ordinary
agent ticket that verifies the handoff before anything builds on it. Like any ticket it
only does what its own text asks, so spell out what "good enough" means and what to do
if it isn't:

```markdown
# 16 — check the owner's review

**Status:** todo
**Blocked by:** 15
**Checks:** 15-owner-review.md

- [ ] the handoff file's feedback is concrete enough to act on
- [ ] if it isn't, send 15 back (see below) instead of flipping this ticket's status
```

`Checks:` names the human ticket's file, not a path — matched against the batch's tickets
with any `DONE_` prefix stripped on either side, so a rename never breaks it. **Sending a
human ticket back** means: set its status line to `ready-for-human` again, append a
`## Sent back by 16-check-owner-review.md` section saying what's missing, commit as
`check: send 15 back — …`, and leave the followup ticket's own status line unflipped. The
loop recognises that shape wherever it sees it — it is what `ralph_was_sent_back` and the
rename-gating in `lib/ralph-human.sh` look for — so once it lands, the next pick is the
human ticket again, and the run stops there (exit 30) with the reason visible in the
ticket itself.

A human ticket is renamed `DONE_` only once its followup ticket has landed, not when the
person flips its own status line — see the start-of-run sweep under "Pausing and
resuming" for why.

**The pattern: human → followup → apply.** A three-ticket shape for anything an agent can
only act on once a person has weighed in:

1. **15 — owner review** (human): the owner reviews the copy and leaves feedback in the
   handoff file.
2. **16 — check the owner's review** (followup, `Checks: 15-owner-review.md`): confirms the
   feedback is concrete enough to act on, or sends 15 back.
3. **17 — apply the owner's feedback** (agent, `Blocked by: 16`): rewrites the copy to
   match what the owner asked for.

**Writing the handoff files and followup tickets.** A person writes the human tickets
themselves (with Matt Pocock's `to-tickets`, or by hand), but nothing writes their handoff
files and followup tickets until `install.sh` puts the `ralph-human-followup-tickets` skill
in `~/.claude/skills/`. Type `/ralph-human-followup-tickets`, usually right after `to-tickets`
and before `ralph init`: it adds whichever of the three pieces above each human ticket is
still missing, never overwrites a handoff file, and tells you what to run next. Running it
again — on the same batch, or after adding one more human ticket — only adds what is new.

### Ordering

If `order.md` exists, the lines between its `<!-- ORDER:BEGIN -->` and `<!-- ORDER:END -->`
markers are the order, one ticket path per line (repo-relative or batch-relative, inside a
code fence or not, `#` to comment one out). If it does not exist, every `*.md` under
`RALPH_ISSUES_DIRS` runs in filename order — which is what the `NN-` prefixes are for. A
relative entry there is resolved against the batch directory, not the repo root, so `.`
means the batch directory itself.

`ralph init` doesn't leave that at filename order: right after scaffolding, it runs
`ralph order <batch>`, which has an agent read every ticket and rewrite the order, weighing
these in priority order — dependencies (what has to land before what, and which tickets
touch the same files closely enough to keep adjacent), human-ticket placement and
followup-ticket adjacency (see below, when the batch has either), importance (foundations
first, polish and sweep-every-surface tickets last), and each ticket's apparent load, so a
run isn't front-loaded with every large ticket back to back. It writes its reasoning into
the prose above the block, naming tickets specifically.

When the batch has human tickets, each one is placed as **late** as its dependents allow:
everything that does not depend on it, directly or transitively, goes before it, so the
unattended stretch before each stop is as long as possible. A followup ticket (its
`Checks:` line names the human ticket) is kept **immediately after** the ticket it checks,
with nothing built on unverified work in between.

That is a first pass, not a guarantee — read it, and move things by hand where it missed a
constraint that isn't in the ticket text. Re-run it any time the tickets change:

```bash
ralph order .scratch/my-batch
```

It costs one model call, touches only `order.md`, and runs locally — no sandbox, since it
edits no code. `ralph init --no-order` skips it and leaves `order.md` in plain filename
order, same as before this step existed.

It defaults to `RALPH_MODEL` — the same model that implements tickets — but sorting a list
is a smaller job than writing code, so point it at something cheaper without touching what
tickets run on:

```bash
RALPH_ORDERING_MODEL=claude-haiku-4-5 ralph order .scratch/my-batch
```

(or set `RALPH_ORDERING_MODEL` in the batch's `ralph.conf` to make that the default). Effort
for this pass stays fixed at `high` regardless of `RALPH_EFFORT`.

### The prompt

One built-in five-step prompt — agree the seams, implement, verify, review, land — serves
every batch. `lib/prompt.template.md` is the text; `ralph.conf` fills in the slots (check
command, test command, TDD skill, review skill); anything left empty degrades to generic
prose rather than naming a command that does not exist.

Anything that fits no slot goes in `<batch>/prompt-extra.md`, spliced in under its own
heading between Verify and Review — a project-specific instruction to drive UI tickets
through a real browser, say.

`ralph dry-run` prints the exact assembled prompt and sends nothing. Read it once before the
first real run of any new batch.

## Where the agent runs — `RALPH_EXEC`

| mode | what happens | when |
|---|---|---|
| `sandbox` (default) | `sbx` on a **private clone**; each iteration's commits come back as a git bundle and fast-forward your branch | the only mode that survives a host/container native-module split |
| `sandbox-mount` | `sbx` bind-mounting your working tree; commits land there directly | isolation wanted, no install step needed in the container |
| `local` | `claude` in your working tree, no sandbox | simplest; no isolation |
| `fake` | no agent at all — a scripted stand-in | testing ralph itself; see `test/smoke.sh` |

Each mode is one file in `lib/exec/`, satisfying the interface documented in
`lib/ralph-exec.sh`. Nothing outside those files asks which mode is in force, and nothing
holds a list of the modes that exist — adding a mode is adding a file.

The clone in `sandbox` mode is not a preference. A bind-mounted Windows workspace hands a
Linux container the host's compiled native modules, which it cannot load, and the container
cannot install its own because npm needs symlinks for `node_modules/.bin` and the Windows
mount refuses them. A clone on the container's own filesystem has neither problem, and the
host repo is mounted read-only so it cannot be clobbered. The cost is that commits no longer
appear in your tree by themselves, hence the sync-down / run / bundle-up dance in
`lib/exec/sandbox.sh`.

In `sandbox` and `sandbox-mount`, set `RALPH_SANDBOX_PROBE` to a command that must succeed
inside the sandbox before any money is spent, and `RALPH_SANDBOX_SETUP` to the command that
fixes it. Without them the first iteration on a fresh clone pays for the model's work and
then fails its verification step.

The sandbox is named `ralph-<repo>` by default, so each repository gets its own and every
batch in it shares that one — the setup cost is paid once per repo.

**The sandbox modes need a primary checkout, not a linked worktree.** `sbx create` acts on
the repository at the path you are standing in, and a worktree's `.git` is a file pointing
elsewhere. Run from the primary checkout, on whichever branch the batch should land on, or
set `RALPH_EXEC=local`. The loop refuses in preflight rather than discovering this later.

### Watching a run — `ralph run --live`

Without it, the terminal is silent from the moment the agent starts until it returns —
seven minutes, forty-five minutes, however long — with no way to tell whether the iteration
is alive or what it is doing.

```bash
ralph run .scratch/my-batch --live      # or RALPH_STREAM=1 in ralph.conf
```

A wall clock and one line per **file write and shell command**, drawn to stderr:

```
   03:12 · Edit lib/foo.js
```

Reads, greps and globs are skipped — they are the bulk of the traffic and say nothing about
progress. Writes and commands are the two signals that show a ticket actually moving.

Only the tool name and its first path or command argument are ever printed, truncated: a
`tool_use` event carries the *whole* input, and a `Write` carries the entire file body. The
input object is never rendered, no transcript is dumped, and no raw stream is kept on disk.

**Off by default**, and the default path is unchanged — `lib/ralph-stream.cjs` sits in the
pipeline either way and is a pass-through when the run is not being watched, so there is one
code path rather than two. `--live` also switches the agent to `--output-format stream-json`
(which the CLI requires `--verbose` alongside); the recorder still receives exactly the one
result object it always did. `ralph dry-run` reports which state a run would use.

### Tickets bigger than one turn

`claude --print --output-format json` is **one turn**. It prints a single JSON object and
exits; there is no second turn, for any batch, and no setting that buys one. A ticket whose
work exceeds that turn's output budget therefore ends with the deliverable half-written,
`exit 0`, `subtype success` and no error anywhere — and used to stop the run as "still not
implemented", so the next run started the same work again from nothing.

The agent handles this itself. The prompt asks it, before starting any substantial piece of
work, whether it can finish *that* and still land the ticket in what is left of the turn;
if not, it commits what it has as `wip: <ticket> — <what remains>`, **leaves the status line
unflipped**, and writes a `Remaining:` list in `progress.txt`.

The loop then treats that as what it is:

- HEAD moved, status unflipped, nothing errored → `⋯ progressed`, and the **same** ticket
  gets the next iteration, told it is continuing and pointed at the handoff note;
- the continuation is reviewed against the commit the ticket was **first** attempted from,
  not its own last chunk, so a ticket that took three passes is still reviewed as one diff;
- progress does not spend a `RALPH_TICKET_ATTEMPTS` retry — that counter counts unproductive
  attempts, which is what it was always for;
- `RALPH_MAX_CONTINUATIONS` (default 5) stops the run if one ticket keeps chunking without
  landing. That is a mis-sized ticket, not a retry problem, and splitting it is your call.

**The loop still never auto-commits.** The *author* commits its own work; the machinery only
stops calling that a failure. WIP commits stay in history — `wip: profile script —
remaining: run at N=96` is better history than a squash that hides the three passes.

`RALPH_CONTEXT_BUDGET_TOKENS` (default 200000) is the number the prompt asks the agent to
judge itself against. Nothing enforces it; the CLI has no such flag, and `--autocompact` is
the real backstop.

### Permissions — `RALPH_PERMISSION_MODE` and `RALPH_CLAUDE_ARGS`

`claude --print` has **nobody to ask**. Anything that would raise a permission prompt is
denied automatically, and there is no second turn in which to recover: the ticket's work
still happens, and still costs, and only the landing fails — showing up as a dirty tree
with no mention of permissions anywhere.

That matters because `acceptEdits` covers `Edit` and `Write` but leaves `Bash` to the
settings allowlist, and ralph's own prompt requires the agent to `git commit` its work.

So `RALPH_PERMISSION_MODE` has **no single default** — it is asked of the execution mode:

| `RALPH_EXEC` | default | why |
|---|---|---|
| `sandbox`, `sandbox-mount` | `bypassPermissions` | the container is the boundary; the gate protects nothing it does not, and costs a paid iteration each time it fires |
| `local`, `fake` | `acceptEdits` | no container — "no isolation" and "no permission check at all" are different things on a machine with real repositories on it |

Anything you set in `ralph.conf` or the environment wins over both. `ralph dry-run` prints
the mode that actually won, which is the only place outside a real run where you can see it.

`local` therefore needs the allowlist that lets its agent commit, and `ralph.conf.template`
ships it uncommented for exactly that reason:

```bash
RALPH_CLAUDE_ARGS=(--allowed-tools "Bash(git add:*)" "Bash(git commit:*)")
```

`ralph doctor` flags a `local` batch that has neither this nor `bypassPermissions` — at $0,
rather than after three tickets.

## Pausing and resuming

**Rerun the same command. That is the whole procedure.**

There is no state file and nothing to restore. Each iteration commits its ticket's flipped
status line together with the code that ticket produced, so the last commit and the resume
point cannot disagree. Whether the loop stopped on a budget, on a usage limit, on Ctrl-C, or
because the machine lost power, the next run picks up at the first ticket that has not
landed.

The loop pauses itself, cleanly, when:

| trigger | what it does |
|---|---|
| `RALPH_MAX_COST_USD` reached | stops **before** starting an iteration that would exceed it |
| `RALPH_MAX_MINUTES` reached | same |
| the iteration-count argument is reached | same |
| a usage / rate / billing limit is detected in the response | stops immediately, reporting the reset time when the response carries one |
| Ctrl-C | records the interrupted iteration, writes the footer, then stops |

All of those exit **10** and print how to resume.

It stops and asks for a human (exit **20**) when a ticket did not reach its done state after
its attempts, or when an iteration left uncommitted changes behind that nothing could
salvage. It never auto-commits that work itself — the point of the per-iteration review base
is that nothing lands unreviewed.

**Waiting on a human (exit 30)** is a different stop, for a different reason: nothing went
wrong, the next ticket in the order is simply a human ticket, and rerunning before it is
done stops here again, for free, same as any other resume. See "Human tickets" above for
what triggers it and what the loop prints.

Every run starts by renaming any landed ticket still lacking its `DONE_` prefix — the same
rename a landed ticket already triggers inline, just swept once up front so a ticket
finished by hand also gets it too. It skips this on a dirty tree (a stall's uncommitted
work may still need its marker to match HEAD), and it skips a human ticket until its
followup ticket has landed: renaming a human ticket the moment its own status line flips
would make a ticket sent back afterwards look finished when it is not.

A turn that ends cleanly and uncommitted, with the ticket unflipped and HEAD exactly where it
started, is a **stall** — the shape of a turn that simply ran out of room before reaching its
own checkpoint step. Rather than stopping, the loop runs a short **checkpoint turn**: a
single-purpose agent turn that reads the diff, commits it as `wip:`, and writes a
`Remaining:` note, without continuing the ticket's own work. That converts the stall into a
progression, and the same ticket continues on the next iteration. Only when the checkpoint
turn *also* cannot commit does the run stop, for the same reason it always did. See
`docs/adr/0001-checkpoint-turn-over-session-resume.md`.

**Rerunning a stop like that salvages it.** When a run ends on a stall it could not salvage,
it leaves a small marker, `.ralph-stall-marker`, in the batch directory naming the ticket, the
base commit and the sandbox. The next run checks for it before its first sync: if the tree is
dirty and the marker matches — same sandbox, same base commit, same ticket — it runs the
checkpoint turn first and then carries on with the batch. The marker is what proves the
uncommitted work is the loop's own. The sandbox is per *repository*, so a dirty clone may be
another batch's stall or your own session inside it, and committing that blind, under
whichever ticket this run picked first, is exactly the unreviewed commit the loop refuses to
make. With no marker, or one that does not match, the run refuses to sync and prints the
recovery note instead. The marker is disposable: deleting it by hand is always safe and costs
only the automatic rescue, and it is removed as soon as the tree is clean or a checkpoint
succeeds.

Within a run, a ticket is retried only when a second attempt could plausibly survive: the
model was briefly unavailable, the iteration ran out of context, or the CLI got far enough
to describe what went wrong. A crash that reports nothing at all is not retried — it looks
exactly like a logic failure, and a blind second attempt costs a whole iteration to learn
nothing. Running out of context is retried even when no JSON came back, since that is the
case a fresh context might carry, and the retry is told to work smaller; if it still fails
that way, the run stops saying the ticket is too large for one iteration rather than that it
merely did not land. `ralph report <batch> --failures` flags those as `out-of-context`.

Exit **0** means every ticket in the batch is done. Exit **1** is a preflight failure or bad
usage; nothing has been spent.

### Budgets

```bash
RALPH_MAX_COST_USD=25 RALPH_MAX_MINUTES=180 ralph run .scratch/my-batch --unlimited
```

The cost guard is the reliable brake. It is checked *before* each iteration and never
*starts* one once the budget is reached — so a run overshoots by at most the cost of a
single iteration: $24 spent against a $25 budget still buys one more full iteration, and
that one may cost $30. Stopping earlier would need an estimate of what the next iteration
will cost, which the toolkit has no model for.

Detecting a limit in the response is best-effort pattern-matching on top of it,
there so that hitting a wall mid-run pauses instead of burning the remaining iterations on
errors that would all fail identically.

A stall's checkpoint turn (see "Pausing and resuming" above) is the one deliberate
exception to the cost and time guards: it runs even when the turn that just stalled already
pushed the run past its budget, because a budget limits what to *commission*, not whether to
keep work already paid for — stopping instead would stop the checkpoint turn from committing
work the run has already spent money on. When that happens, the run's closing summary says
so explicitly — a budget was overshot to salvage stalled work, and by how much — rather than
letting the figures in the summary silently disagree with the budget that was set.

Any `RALPH_*` set in the environment beats the batch's `ralph.conf`, so a one-off run needs
no edit.

## The logs

Two files per batch, both **append-only**, both gitignored:

- `ralph-runs.jsonl` — one JSON object per iteration, forever: ticket, batch, run id,
  commits, exit status, subtype, turns, wall and API duration, every token count, cost, the
  pass/fail flags, and the agent's own reply.
- `ralph-runs.log` — the same runs as readable text, with the agent's reply inline and a
  header/footer per run.

**Nothing reads them back.** Not the loop, not `ralph-next.sh`. Truncate them, delete them,
or hand-edit them and the loop behaves identically — the tickets' status lines are the only
thing it treats as state. To read them:

```bash
ralph report .scratch/my-batch              # totals, then per run
ralph report .scratch/my-batch --by-ticket  # which tickets cost what
ralph report .scratch/my-batch --failures   # only what went wrong
```

That tool is manual and is never invoked by the loop.

## Files

| file | what it is |
|---|---|
| `bin/ralph` | the dispatcher — resolves a subcommand to a script in `lib/` |
| `bin/ralph.cmd` | the same, for PowerShell and cmd.exe |
| `install.sh` | writes the PATH shims; `--uninstall` removes them |
| `lib/ralph-loop.sh` | the loop: preflight, budgets, iteration, pause/resume, footer |
| `lib/ralph-config.sh` | resolves a batch into RALPH_* — sourced, never run |
| `lib/ralph-exec.sh` | the seam between the loop and where the agent runs — sourced, never run |
| `lib/exec/*.sh` | one adapter per `RALPH_EXEC` mode; `_`-prefixed files are shared implementation |
| `lib/ralph-repo.sh` | repo root and batch-relative path: the one place that crosses Windows path syntax — sourced, never run |
| `lib/ralph-next.sh` | `ralph next`: resolves the order against what has landed — also `--list`, `--count`, `--all`, `--unordered` |
| `lib/ralph-tickets.sh` | the ticket list and the questions asked of it, as functions `ralph-next.sh` and the loop share, so one command loads its config once — sourced, never run |
| `lib/ralph-prompt.sh` | assembles one iteration's prompt — sourced, never run |
| `lib/prompt.template.md` | the five-step prompt, with slots |
| `lib/ralph-record.cjs` | appends one iteration to both logs; writes the verdict the loop acts on |
| `lib/ralph-report.cjs` | manual log reader |
| `lib/ralph-stream.cjs` | sits between the agent and the recorder; draws the run when `--live`, a pass-through otherwise |
| `lib/ralph-strip-ansi.cjs` | removes `sbx`'s banner control codes — shared by the two above |
| `lib/ralph-init.sh` | scaffolds a batch, then runs `ralph-order.sh` unless told not to |
| `lib/ralph-order.sh` | has an agent order the tickets by dependency, importance and load |
| `lib/ralph-doctor.sh` | checks the machine, the repo and the batches; `--fix` writes the repo's two files |
| `lib/ralph.conf.template` | every knob, commented, with its default |
| `test/smoke.sh` | end-to-end tests of the loop, run through the `fake` adapter — no sandbox, no model, no money |
| `test/bench.sh` | times `ralph status` on a 3-ticket batch and counts its spawns by command — a measuring instrument, not a test; `bash test/bench.sh [runs]` |
| `test/fixture.sh` | sourced by the two above: builds a template repository once and copies it for each fixture |
| `assumptions.md` | the decisions taken while generalising this, and how to undo them |

Each `lib/` script is still directly callable — `bash lib/ralph-loop.sh <batch> --status`
does what `ralph status <batch>` does. The dispatcher exists for the typing, not because
anything depends on it.

## Using it in a new repository

There is nothing to copy.

```bash
cd <the repo>
ralph doctor --fix     # its .gitignore / .gitattributes lines, once
ralph init <batch-dir> # its first batch
```

The toolkit is not inside the repository and never becomes part of it: `RALPH_TOOL_DIR`
comes from the script's own location, the repository comes from `git rev-parse` where you
are standing, and the two are unrelated paths. Upgrading the install upgrades every project
at once.
