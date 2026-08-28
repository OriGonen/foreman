# ralph

A loop that implements one ticket per iteration, until a batch of tickets is done or a
budget stops it. Installed once per machine; point it at any directory of tickets, in any
repository.

```bash
cd <any git repo>
ralph doctor                    # is this repo ready?                  (free)
ralph init .scratch/my-batch    # scaffold a batch, then order its tickets
ralph status .scratch/my-batch  # what is left, what is next           (free)
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
Bash and PowerShell get the same command. It writes nothing else and nothing outside that
directory. `bash install.sh --to <dir>` picks the directory yourself; `--uninstall` removes
the two shims and leaves the checkout alone.

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

Two batches never share any of it, and two *repositories* never share any of it either. Run
one, pause it, switch repos, run another, come back — each resumes exactly where it was.
Nothing accumulates in the install.

## Setting up a repository

Once per repo:

```bash
ralph doctor --fix
```

That appends the only two things a repo has to provide itself:

- `.gitignore` — `**/.ralph-iter.bundle`, `**/ralph-runs.jsonl`, `**/ralph-runs.log`, so a
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

### Ordering

If `order.md` exists, the lines between its `<!-- ORDER:BEGIN -->` and `<!-- ORDER:END -->`
markers are the order, one ticket path per line (repo-relative or batch-relative, inside a
code fence or not, `#` to comment one out). If it does not exist, every `*.md` under
`RALPH_ISSUES_DIRS` runs in filename order — which is what the `NN-` prefixes are for.

`ralph init` doesn't leave that at filename order: right after scaffolding, it runs
`ralph order <batch>`, which has an agent read every ticket and rewrite the order, weighing
three things — dependencies (what has to land before what, and which tickets touch the same
files closely enough to keep adjacent), importance (foundations first, polish and
sweep-every-surface tickets last), and each ticket's apparent load, so a run isn't
front-loaded with every large ticket back to back. It writes its reasoning into the prose
above the block, naming tickets specifically.

That is a first pass, not a guarantee — read it, and move things by hand where it missed a
constraint that isn't in the ticket text (a human step that has to happen first, say).
Re-run it any time the tickets change:

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
its attempts, or when an iteration left uncommitted changes behind. It never auto-commits
that work — the point of the per-iteration review base is that nothing lands unreviewed.

Exit **0** means every ticket in the batch is done. Exit **1** is a preflight failure or bad
usage; nothing has been spent.

### Budgets

```bash
RALPH_MAX_COST_USD=25 RALPH_MAX_MINUTES=180 ralph run .scratch/my-batch --unlimited
```

The cost guard is the reliable brake and is checked *before* each iteration, so it never
overshoots. Detecting a limit in the response is best-effort pattern-matching on top of it,
there so that hitting a wall mid-run pauses instead of burning the remaining iterations on
errors that would all fail identically.

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
| `lib/ralph-next.sh` | resolves the order against what has landed — also `--list`, `--count`, `--all`, `--unordered` |
| `lib/ralph-prompt.sh` | assembles one iteration's prompt — sourced, never run |
| `lib/prompt.template.md` | the five-step prompt, with slots |
| `lib/ralph-record.cjs` | appends one iteration to both logs; writes the verdict the loop acts on |
| `lib/ralph-report.cjs` | manual log reader |
| `lib/ralph-init.sh` | scaffolds a batch, then runs `ralph-order.sh` unless told not to |
| `lib/ralph-order.sh` | has an agent order the tickets by dependency, importance and load |
| `lib/ralph-doctor.sh` | checks the machine, the repo and the batches; `--fix` writes the repo's two files |
| `lib/ralph.conf.template` | every knob, commented, with its default |
| `test/smoke.sh` | end-to-end tests of the loop, run through the `fake` adapter — no sandbox, no model, no money |
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
