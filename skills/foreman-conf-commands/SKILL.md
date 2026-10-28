---
name: foreman-conf-commands
description: Fill in a batch's foreman.conf check, test and sandbox-setup commands from what the repo itself shows. Run by `foreman init`.
disable-model-invocation: true
argument-hint: <batch-dir>
---

# foreman-conf-commands

Fills in the command slots of `<batch>/foreman.conf` — the lines that tell Foreman's agent
what "verify your work" means in this repo, and how to make a fresh sandbox clone ready to
run them. Every value comes from **evidence**: a file in this repo that already runs or
names the command. A slot with no evidence stays commented out, which is safe: Foreman's
prompt then falls back to generic prose instead of naming a command that does not exist.

`foreman init` runs this headless, right after it writes `foreman.conf`, as
`/foreman-conf-commands <batch>`. A person can also type it in Claude Code.

## The slots

| Slot | What it is |
|---|---|
| `FOREMAN_CHECK_CMD` | the fast static gate: type-check, lint, format check — whatever the repo has, in one command. Not the tests. |
| `FOREMAN_TEST_CMD` | the whole test suite, run once, then exit. |
| `FOREMAN_FOCUSED_TEST_CMD` | one test file, with the literal `<file>` where its path goes (`npx vitest run <file>`, `pytest <file>`). |
| `FOREMAN_SANDBOX_SETUP` | installs the dependencies a fresh clone lacks, from the lockfile (`npm ci`, `pnpm install --frozen-lockfile`, `uv sync`, `bundle install`). |
| `FOREMAN_SANDBOX_PROBE` | a cheap command that succeeds only once SETUP has run (`test -d node_modules`, `python -c "import <a dependency>"`). Foreman runs SETUP only when the probe fails, so SETUP without a PROBE never runs: set both or neither. |

Where they run: the agent runs every one of these from the repo root, non-interactively, by
default inside a Linux sandbox holding a fresh clone with none of the repo's gitignored
directories. So each is a POSIX shell command that exits on its own: the run-once form of a
test runner (`vitest run`, not `vitest`), never a watch mode, a dev server or a prompt.

When `foreman.conf` sets `FOREMAN_EXEC=local`, skip the two SANDBOX slots: they are ignored
there. Toolchains that fetch their own dependencies on first build (`go`, `cargo`) need no
SETUP or PROBE either.

## Steps

### 1. Find the batch

`$ARGUMENTS` names it. If that is empty, the batch is the one directory in the repo holding a
`foreman.conf`; ask if there are several. If the batch has no `foreman.conf`, stop and say
`run: foreman init <batch>` — this skill fills one in, it never creates one.

Done when you have one `foreman.conf` to work on, and know which slots are already **set**
(an uncommented line, even an empty one: that is a person's decision, and stays as it is).

### 2. Gather the evidence

Read, don't run: this is a read-only survey of files, and the headless run has no permission
to execute commands anyway. Look at, strongest evidence first:

1. **CI** — `.github/workflows/*`, `.gitlab-ci.yml`, `.circleci/config.yml`, `azure-pipelines.yml`,
   `Jenkinsfile`. What CI runs on every push is the repo's own answer to "is this change good".
2. **Task runners** — `package.json` `scripts` (and which lockfile sits beside it: that picks npm,
   pnpm, yarn or bun), `Makefile`, `justfile`, `Taskfile.yml`, `pyproject.toml` / `tox.ini` /
   `noxfile.py`, `Cargo.toml`, `go.mod`, `Gemfile`, `composer.json`, `build.gradle`, `pom.xml`.
3. **Prose** — `CONTRIBUTING.md`, `README.md`, `CLAUDE.md`, `AGENTS.md`, `docs/`.

In a monorepo, prefer the one root-level command that covers every package (a workspace
script, a root `Makefile` target) over one package's.

For each slot you are filling, note the command and the file that shows it. Done when every
unset slot has either a command with its source file, or a reason it has none.

### 3. Choose, slot by slot

Set a slot only when the evidence names that command, or names the tool and its config so
plainly that the command is unambiguous (a `vitest.config.ts` and a `"test": "vitest"` script
make `npx vitest run <file>` the focused form). Where two sources disagree, CI wins. Where the
repo has no such step at all — no linter, no type-checker — the slot stays empty; that is an
answer, not a gap to fill with a guess.

Prefer the repo's own entry point over the raw tool: `npm run lint`, not the `eslint`
invocation it wraps, so the command keeps working when the script changes.

Done when every unset slot has a decided value or a decided "leave empty".

### 4. Edit `foreman.conf`

For each slot with a value, turn its commented-out line (`#FOREMAN_TEST_CMD=...`, with no space
after the `#` — the indented ones are examples) into the set line, in place, so it stays under its explanatory comment; put on the line directly above it
one comment naming the evidence:

```sh
# foreman-conf-commands: from .github/workflows/ci.yml
FOREMAN_TEST_CMD="npm test"
```

Quote with double quotes; use single quotes when the command itself contains a double quote.
The file is sourced by bash, so the value must survive that untouched. If a slot has no
commented line to replace, append the pair at the end of the file.

Edit only those lines. The rest of `foreman.conf`, and every other file, stays as it was, and
nothing is committed — the person reviews the conf before the batch's first run.

Done when every chosen value is in `foreman.conf`, each with its evidence comment, and
`bash -n <batch>/foreman.conf` would parse it.

### 5. Report

Reply with one line per slot: the value you set and its source file, or `left empty` and why.
Keep it short — `foreman init` prints the conf's set lines itself.
