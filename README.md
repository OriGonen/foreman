# ralph

A loop that implements one ticket per iteration, until a batch of tickets is done or a
budget stops it. Point it at any directory with tickets in it.

```bash
bash tools/ralph/ralph-init.sh .scratch/my-batch          # scaffold a batch
bash tools/ralph/ralph-loop.sh .scratch/my-batch --status  # what is left, what is next
bash tools/ralph/ralph-loop.sh .scratch/my-batch --dry-run # the plan and the exact prompt
bash tools/ralph/ralph-loop.sh .scratch/my-batch           # go
bash tools/ralph/ralph-loop.sh .scratch/my-batch 5         # go, at most 5 iterations
```

`--status` and `--dry-run` make no model call and cost nothing.

## The one rule: this directory is stateless

Everything that differs between batches lives in the **batch directory**, never here:

| in the batch | what it is |
|---|---|
| `ralph.conf` | the batch's config — the only file that makes a directory a batch |
| `order.md` | the run order (optional — see below) |
| `progress.txt` | the agent's running notes, appended each iteration |
| `prompt-extra.md` | project-specific prompt text (optional) |
| `ralph-runs.jsonl` `ralph-runs.log` | append-only run telemetry, gitignored |
| `.ralph-iter.bundle` | transient; exists only inside one iteration |

Two batches never share any of it. Run one, pause it, run another, come back — each
resumes exactly where it was. The scripts here read config and write nothing.

## Setting up a batch

A batch is a directory containing tickets. A ticket is a markdown file with a status line:

```markdown
# 01 — do the thing

**Status:** todo

- [ ] the thing is done
```

`ralph-init.sh <dir>` writes the three files a batch needs, generating `order.md` from
`<dir>/issues/*.md`. It never overwrites without `--force`, and it never touches a ticket.

Then edit `<dir>/ralph.conf`. The two lines that matter most are what "verify your work"
means in your project:

```sh
RALPH_CHECK_CMD="npm run check"
RALPH_TEST_CMD="npm test"
```

Everything else has a default; `ralph.conf.template` documents the full set.

### Ordering

If `order.md` exists, the lines between its `<!-- ORDER:BEGIN -->` and `<!-- ORDER:END -->`
markers are the order, one ticket path per line (repo-relative or batch-relative, inside a
code fence or not, `#` to comment one out). If it does not exist, every `*.md` under
`RALPH_ISSUES_DIRS` runs in filename order — which is what the `NN-` prefixes are for.

Use an order file as soon as the order is not the filename order: tickets spread across
two issue directories whose numbering collides, a foundation everything else reads, a
sweep-every-surface ticket that has to go last. Put the *reasoning* in the prose above the
block — that is where a constraint no ticket file can express belongs.

### The prompt

One built-in five-step prompt — agree the seams, implement, verify, review, land — serves
every batch. `prompt.template.md` is the text; `ralph.conf` fills in the slots (check
command, test command, TDD skill, review skill); anything left empty degrades to generic
prose rather than naming a command that does not exist.

Anything that fits no slot goes in `<batch>/prompt-extra.md`, spliced in under its own
heading between Verify and Review. `.scratch/qa-round-3/prompt-extra.md` is a worked
example: a project-specific instruction to drive UI tickets through a real browser.

`--dry-run` prints the exact assembled prompt and sends nothing. Read it once before the
first real run of any new batch.

## Where the agent runs — `RALPH_EXEC`

| mode | what happens | when |
|---|---|---|
| `sandbox` (default) | `sbx` on a **private clone**; each iteration's commits come back as a git bundle and fast-forward your branch | the only mode that survives a host/container native-module split |
| `sandbox-mount` | `sbx` bind-mounting this working tree; commits land here directly | isolation wanted, no install step needed in the container |
| `local` | `claude` in this working tree, no sandbox | simplest; no isolation |

The clone in `sandbox` mode is not a preference. A bind-mounted Windows workspace hands a
Linux container the host's compiled native modules, which it cannot load, and the container
cannot install its own because npm needs symlinks for `node_modules/.bin` and the Windows
mount refuses them. A clone on the container's own filesystem has neither problem, and the
host repo is mounted read-only so it cannot be clobbered. The cost is that commits no
longer appear here by themselves, hence the sync-down / run / bundle-up dance in
`ralph-loop.sh`.

In `sandbox` and `sandbox-mount`, set `RALPH_SANDBOX_PROBE` to a command that must succeed
inside the sandbox before any money is spent, and `RALPH_SANDBOX_SETUP` to the command that
fixes it. Without them the first iteration on a fresh clone pays for the model's work and
then fails its verification step.

## Pausing and resuming

**Rerun the same command. That is the whole procedure.**

There is no state file and nothing to restore. Each iteration commits its ticket's flipped
status line together with the code that ticket produced, so the last commit and the resume
point cannot disagree. Whether the loop stopped on a budget, on a usage limit, on Ctrl-C,
or because the machine lost power, the next run picks up at the first ticket that has not
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

It stops and asks for a human (exit **20**) when a ticket did not reach its done state
after its attempts, or when an iteration left uncommitted changes behind. It never
auto-commits that work — the point of the per-iteration review base is that nothing lands
unreviewed.

Exit **0** means every ticket in the batch is done. Exit **1** is a preflight failure or
bad usage; nothing has been spent.

### Budgets

```bash
RALPH_MAX_COST_USD=25 RALPH_MAX_MINUTES=180 bash tools/ralph/ralph-loop.sh .scratch/my-batch
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
node tools/ralph/ralph-report.cjs .scratch/my-batch              # totals, then per run
node tools/ralph/ralph-report.cjs .scratch/my-batch --by-ticket  # which tickets cost what
node tools/ralph/ralph-report.cjs .scratch/my-batch --failures   # only what went wrong
```

That tool is manual and is never invoked by the loop.

## Files

| file | what it is |
|---|---|
| `ralph-loop.sh` | the loop: preflight, budgets, iteration, pause/resume, footer |
| `ralph-config.sh` | resolves a batch into RALPH_* — sourced, never run |
| `ralph-next.sh` | resolves the order against what has landed — also `--list`, `--count`, `--all` |
| `ralph-prompt.sh` | assembles one iteration's prompt — sourced, never run |
| `prompt.template.md` | the five-step prompt, with slots |
| `ralph-record.cjs` | appends one iteration to both logs; writes the verdict the loop acts on |
| `ralph-report.cjs` | manual log reader |
| `ralph-init.sh` | scaffolds a batch |
| `ralph.conf.template` | every knob, commented, with its default |
| `assumptions.md` | the decisions taken while generalising this, and how to undo them |

## Using it in another repo

Copy `tools/ralph/` across and run `ralph-init.sh`. The only repo-specific thing in here is
the default model name; everything else comes from the batch's `ralph.conf`. Add to the new
repo's `.gitignore`:

```gitignore
**/.ralph-iter.bundle
**/ralph-runs.jsonl
**/ralph-runs.log
```

If the repo normalises line endings, keep `*.sh text eol=lf` in `.gitattributes` — CRLF
breaks heredoc delimiters and shebangs.
