# Spec — the picked terminal designs, built into foreman-ui.sh and the commands

**Status:** ready-for-agent

Vocabulary: `CONTEXT.md`. The designs this spec builds: `designs/` in this directory
(see "Design references" below).

## Problem Statement

Every `foreman` command prints plain lines: a `Batch:` tag, `Tickets done: d / t`, a list,
a few ✓ / ▲ glyphs in the basic 16 ANSI colours. It is correct and greppable, but it does
not say at a glance how far a batch has got, what the next move is, or whether a machine is
ready — the reader has to parse sentences. The look was designed in rounds on a canvas and
one take was picked per command (below). None of it is built yet, and nothing in the
toolkit can draw it: `lib/foreman-ui.sh` knows five styles in 16 colours and has no notion
of a colour tier, a terminal width, or a scene drawn from block characters.

The picks:

| Command | Pick | What it looks like |
|---|---|---|
| `foreman help` | 1 · D1 | the big sunrise, redrawn, above the help text |
| intro | 2 · Intro3 | a 2.5s animation on bare `foreman` and `foreman help`, terminal only |
| `foreman run` | 3a | the figure beside the sun; the sun climbs as tickets land, quiet or `--live` |
| `foreman status` | 4a | the sunrise dome sized by how much is done, with a ✓ / ▶ list |
| `foreman doctor` | 5b | the site-inspection box; on a terminal an animated inspector runs while the checks run, then a whistle and a red sign or a thumbs-up and a check |
| `foreman init` | 7a | breaking ground: the mark, the files written, four NEXT steps |
| `foreman order` | 8b | the new order on a numbered stake line, tags and all |
| `foreman next --all` | 9b | the stake row, then the ✓ / ▶ list |
| `foreman report` | 10a | the bill up top (big total, outcome counts), then the ledger with cost bars |
| `foreman dry-run` | 11a | the low sun, WOULD RUN, SETTINGS, the prompt with line numbers |
| `foreman convert` | 12a | the sign repainted from RALPH to FOREMAN, then what changed |
| `foreman version` | 13a | the mark beside the build |

Colour: the best the terminal has — 24-bit, then 256, then 16 — and `FOREMAN_COLOR` and
`NO_COLOR` still win.

## Solution

Two renderings of every command, chosen once per call:

- **The show** — the picked design, drawn in the foreman palette at the best colour tier
  the terminal has. Used when the stream is a terminal, it is wide enough for the design,
  colour is on, and the run is not in CI.
- **Plain** — today's output, unchanged byte for byte. Used everywhere else: a pipe, a
  file, `$(…)`, CI, `TERM=dumb`, `NO_COLOR`, a narrow terminal. Scripts that read
  `foreman next` or `foreman version` keep working, and the smoke suite's ~719 existing
  assertions keep holding because it captures output with `$(…)`.

The one exception is `foreman doctor`, whose plain output becomes the 5b box (without the
inspector or colour), as picked; its smoke assertions change in its own ticket.

`lib/foreman-ui.sh` keeps deciding: colour tier, show or plain, width. It stays fork-free.
The drawing — block-character art, the sun, the stake lines, the box, the frames of an
animation — is done by one new node renderer, `lib/foreman-draw.cjs`, which the shell
starts once per show and feeds the facts it already has. The canvas generators are
JavaScript already and port to it almost unchanged. Plain output starts no process it does
not start today.

## User Stories

1. As a person running `foreman status` at a terminal, I see how far the batch has got from
   the height of the sun, before I read a word.
2. As a person running `foreman status`, I see which ticket is next and, when it is a human
   ticket, that it is mine and which handoff file to fill in.
3. As a person running `foreman help` or bare `foreman` at a terminal, I see the sunrise and
   then the commands, after a short intro.
4. As a person who has seen the intro, I can skip it with any key, or turn it off for good
   with `FOREMAN_INTRO=0`.
5. As a person watching `foreman run`, I see the figure and the sun, which climbs as each
   ticket lands; the pinned status bar and its keys work as before.
6. As a person watching `foreman run --live`, the agent's tool calls appear under the
   iteration as `│ mm:ss verb path` lines.
7. As a person running `foreman doctor`, I see an inspector at work while the checks run,
   and a verdict I cannot miss: a whistle and a red NOT PASSED sign, or a thumbs-up and a
   big check.
8. As a person running `foreman doctor` in CI or through a pipe, I get the box and an exit
   code, with no animation and no escape codes.
9. As a person starting a batch with `foreman init`, I see the files written, the agent's
   ordering result and four numbered next steps.
10. As a person running `foreman order`, I see the new order with moved tickets marked and
    the human and check tickets tagged, and any warning about a missing handoff line.
11. As a person running `foreman next --all`, I see the stake row and the list; when I pipe
    `foreman next`, I still get bare paths.
12. As a person running `foreman report`, I see the total cost large, the outcome counts,
    and a bar per run.
13. As a person running `foreman dry-run`, I see the plan, the settings and the prompt with
    line numbers, and the closing rule says nothing was sent.
14. As a person running `foreman convert`, I see what was renamed, rewritten, deleted and
    kept, and what is left for me on this machine.
15. As a person running `foreman version`, I see the mark and the build; piped, I get the
    same two lines as today.
16. As a person in a 24-bit terminal (Windows Terminal, iTerm2, most Linux terminals), I see
    the exact palette; in a 256-colour terminal its nearest shades; in a 16-colour one the
    old ANSI colours.
17. As a person who set `NO_COLOR` or `FOREMAN_COLOR=never`, I get plain output from every
    command.
18. As a person in a narrow terminal, I get plain output rather than a broken drawing.
19. As a developer, I can force the show into a capture (`FOREMAN_SHOW=always`), pin the
    tier (`FOREMAN_COLOR=truecolor|256|16`) and the width (`COLUMNS`), so the show is
    testable from the smoke suite.

## Implementation Decisions

### Colour tiers (`lib/foreman-ui.sh`)

- A colour tier is one of `none`, `16`, `256`, `24`. `ui_color_tier VAR FD` sets VAR to the
  tier for that stream. It is decided per call from builtins only, as `ui_color_on` is now:
  - `FOREMAN_COLOR=never` → none. `FOREMAN_COLOR=16|256|truecolor` → that tier, on every
    stream (the pinned forms, for tests and for terminals that lie).
  - `FOREMAN_COLOR=always` → on every stream, at the detected tier, or 16 when nothing is
    detected. This keeps every existing `${ESC}[32m✓` assertion true, as long as the suite
    unsets `COLORTERM` and `WT_SESSION` for those cases.
  - `auto` (the default): none when `NO_COLOR` is set, `TERM` is `dumb`, or FD is not a
    terminal. Otherwise 24 when `COLORTERM` is `truecolor` or `24bit` or `WT_SESSION` is
    set (Windows Terminal does not set `COLORTERM`); 256 when `TERM` contains `256color`;
    else 16.
- `ui_color_on FD` stays, as "the tier is not none".
- The five styles (ok, warn, error, accent, muted) map to the palette at 256 and 24 and to
  the old ANSI codes at 16, so a 16-colour terminal looks exactly as it does today.
- This reverses the header comment's "only the basic 16 colours, so the terminal's theme
  decides the shades". The reason (a designed palette, and the art needs its exact shades)
  goes in a new ADR, `docs/adr/0003-a-palette-over-the-terminal-theme.md`, with the rule that
  16 colours still means the theme's own.

### The palette

One table, defined once in `lib/foreman-ui.sh`, one line per name: the hex, the nearest
xterm-256 index (precomputed, not computed at runtime), and the 16-colour SGR code.
`foreman-draw.cjs` reads the table from `foreman-ui.sh` at start (a regex over one
assignment), so there is no second copy to drift. The names and hex:

| Name | Hex | Used for |
|---|---|---|
| sun | `#f6d58e` | the sun's core, highlights, TWEEEET |
| amber | `#e0a84a` | the sun's body, the mark, tags (HUMAN, CHECK) |
| rust | `#c9772f` | the sun's rim, the inspector's jacket |
| post | `#8a5a24` | stakes, sign posts, boots |
| earth | `#3a2a18` | the ground line, the dome's shade |
| shade | `#30231a` | the dome's far side |
| night | `#1c1a17` | the sky behind a low sun |
| ok | `#8fcf8f` | ✓, landed, the check |
| error | `#f08078` | ✗, NOT PASSED, failures |
| muted | `#a8a299` | secondary text |
| dim | `#5c574f` | rules, the ground's dust, `·` |
| text | `#ece8e1` | body text (24-bit only; otherwise the terminal's default) |
| ink | `#171614` | text on a tag's background |

Text colours apply to glyphs, tags and figures, as now — a sentence is never coloured, so
the show read without colour still says everything.

### Show or plain

- `ui_show FD` succeeds when the show is wanted on FD: the tier is not none, FD is a
  terminal, `CI` is unset, and `FOREMAN_SHOW` is not `never`. `FOREMAN_SHOW=always` forces
  it on any stream (and turns the tier to at least 16), for tests and for people who want
  the drawing in a file.
- The width is asked only on the show path: `COLUMNS` when set, else `stty size` as
  `foreman-keys.sh` already does (one process, on a path that starts node anyway). Each
  scene declares its minimum width (about 98 columns for the wide headers, 80 for the
  doctor box); narrower means plain.
- Where the shell has the facts as data (status, dry-run, next, the doctor checks), it
  builds one block of `key<TAB>value` lines and pipes it to
  `node foreman-draw.cjs SCENE --tier T --cols N`. Where node already produces the output
  (`report`, `convert`), those scripts require `foreman-draw.cjs` as a module and draw the
  scene themselves, taking tier and width from the same variables the shell sets.
- Show output goes to the same stream as today's plain output. Nothing that reaches
  `foreman-runs.log` or `progress.txt` changes.

### The renderer (`lib/foreman-draw.cjs`)

- One file, no dependencies, CommonJS like the other `.cjs` files. Exports `draw(scene,
  facts, {tier, cols})` and runs it when called as a script.
- Scenes are plain functions from facts to rows of `{t, style}` runs, the same shape the
  canvas boards use; one encoder turns rows into SGR at the tier (24: `38;2;r;g;b`, 256:
  `38;5;n`, 16: the style's ANSI code, with the art's shades folded onto yellow, red and
  dim). Half-block art (`▀▄█`) needs a foreground and a background per cell; at 16
  colours the background shades fold the same way.
- The sun, the dome, the mark, the figure, the inspector and the stake line are each a
  function, ported from the generators in `designs/source/*.dc.html`. Shared pieces live
  once: the mark heads init, report and version; the dome is status's and run's.
- Animation (intro, doctor): frames on a timer (`setTimeout`, about 70ms a step), cursor
  hidden while it plays and shown again on every exit path (end, any key, SIGINT, an
  exception). Any key skips to the last frame: stdin in raw mode, only when stdin is a
  terminal. The final frame is left on screen; the rest of the output follows it.
- `--frame N` / `--t N` draw one frame and exit, so a frame is testable.

### Per command

- **help (D1).** `usage()` in `bin/foreman` prints the D1 sunrise above the header-comment
  help when `ui_show 1`; plain is today's text. `foreman help` exits 0, bare `foreman` 1,
  as now.
- **intro (Intro3).** Plays before the help on bare `foreman` and `foreman help`, only on
  the show path, only when stdin is a terminal too (for the skip key), and never when
  `FOREMAN_INTRO=0`. 36 frames over 2.5s; its last frame is the D1 sunrise, so the help
  follows without a jump.
- **status (4a).** The dome's height follows done / total (the "sun is N% up" line); the
  right of the dome carries the batch, done of total, the spend from the run log, and the
  percentage. The list is the existing remaining-in-order, with ✓ for done, ▶ for next,
  HUMAN / CHECK tags and "after 07" on a followup. The closing line is the existing human
  ticket note and handoff path. All of it comes from what `foreman-loop.sh --status` already
  computes; it is passed as facts instead of printed.
- **dry-run (11a).** The low sun, WOULD RUN with ▶ on the first, SETTINGS in two columns
  (from the values `budget_label` and the conf already give), PROMPT with line numbers and
  a `⋮` fold for the middle when it is longer than the screen allows, and the closing rule
  "nothing was sent; no sandbox was started". The plain path keeps the full prompt between
  the `===` lines, because people pipe it.
- **run (3a).** At the start, the header: the figure, the dome at the current done count,
  and the run facts (run id, batch, model, exec, budget, done of total, the next human
  ticket). Each iteration keeps its `── iteration` rule and its say_event outcome, restyled
  as in the design (`1/3  05-…` then `✓ landed  sha  ·  time  ·  $`). When a ticket lands,
  the header is drawn again with the sun one step higher and a "↑ 05 landed · the sun climbs
  to N of M" line, before the next iteration starts. The pinned status bar from
  `foreman-keys.sh` stays the foot, restyled to the design's foot line (elapsed, iteration,
  spend of budget, live on/off, the keys). With `--live`, `foreman-stream.cjs` prints the
  agent's tool calls as `│ mm:ss verb path` lines when the show is on.
- **doctor (5b).** `foreman-doctor.sh` stops printing as it goes and instead records each
  check as it completes (section, state ok / miss / stale, text). On the show path it
  starts the renderer first, through a process substitution on its own file descriptor,
  and writes each check result to it as it completes; the inspector runs across the track
  while results arrive, the box below fills in, and at end of input the verdict plays
  (about 1.5s) and the box is left on screen. The `--fix` writes and the closing advice
  print after the box. Off the show path the renderer draws only the box, without colour,
  once all checks are in. The box holds every section the doctor has today — Machine,
  Skill, Repository, Batches, and "From before the rename" when it applies — and the exit
  code is unchanged.
- **init (7a).** The mark and "FOREMAN breaks ground", the batch and what was found, `+`
  per file written, the ordering result from `foreman order` (moved count, the human and
  check tickets, time, cost), and NEXT with four numbered steps. `--no-order` drops the
  ordering line.
- **order (8b).** A one-line spinner while the agent works (the shell already waits on it),
  then the numbered stake line: position, ticket, `moved` when it changed place, HUMAN /
  CHECK tags with "the loop stops here" / "checks 07", and ▲ warnings below.
- **next (9b).** Only `--all` and `--count` get a show. `--all` draws the stake row (a stake
  per ticket, the next one tall) over the ✓ / ▶ list and a "6 driven · 1 yours · 3 to go"
  line. Bare `foreman next` and `--list` print bare paths on every stream, as today, because
  they are read by scripts.
- **report (10a).** In `foreman-report.cjs`: the mark beside the total, the run and
  iteration counts, a bar of outcomes (landed, progressed, stalled, unproductive) and its
  legend, then TOTAL and BY RUN with a cost bar per run scaled to the largest. `--by-ticket`
  and `--failures` keep their tables, under the same header.
- **convert (12a).** In `foreman-convert.cjs`: the sign with RALPH struck through and
  FOREMAN painted on, the counts, then RENAMED / REWROTE / DELETED / KEPT and THIS MACHINE
  with ✓ / ▲. `--dry-run` says "would" throughout and the sign is not repainted.
- **version (13a).** The mark beside `FOREMAN <rev>`, where it is installed, and the
  one-line description. Piped, the same two lines as today. `foreman --version` is the
  same command.

### Design references

`designs/` holds each pick rendered from the canvas: `NN-name.ans` in 24-bit SGR (`cat` it
in a terminal to see the design) and `NN-name.txt` without colour, for diffing and grep.
The animations are a sequence of frames separated by `── caption` lines: intro all 36,
run all 18 steps quiet and live, doctor every second tick for both verdicts.
`designs/source/` holds the canvas boards themselves (`*.dc.html`): the generator code to
port is in each board's `data-dc-script` block. The sample facts in them (ticket names,
costs, dates) are examples, not requirements.

## Testing Decisions

- Every existing assertion stays as it is, except the doctor's, which change with its
  ticket. That is the test that plain output did not move.
- Colour tiers: a table of environments (`COLORTERM`, `WT_SESSION`, `TERM`, `NO_COLOR`,
  `FOREMAN_COLOR`, terminal or not) against the expected tier, through `ui_color_tier`. The
  terminal case uses `script` where it exists, or is checked by hand and noted.
- Each show is tested by forcing it: `FOREMAN_SHOW=always FOREMAN_COLOR=truecolor
  COLUMNS=120`, run through `foreman-strip-ansi.cjs`, and asserted on its key lines (the
  facts, not the art), plus one assertion on the raw output that the 24-bit form is used
  (`38;2;`) and one at `FOREMAN_COLOR=16` that it is not. A narrow `COLUMNS` gives the
  plain output.
- Animations are tested a frame at a time (`--frame` / `--t`) and with stdin not a
  terminal, where they must not wait for a key. The cursor is shown again after an
  interrupted animation: checked by hand, noted in the ticket.
- No golden files of whole drawings: they would change with every nudge to the art. The
  `.ans` files in `designs/` are the reference a person compares against by eye.
- Spawns stay counted: the plain path of status, next and version adds no process
  (`test/bench.sh` before and after); the show path adds one node.

## Out of Scope

- Changing what any command does, decides or exits with; only how it prints.
- The contents of `foreman-runs.log`, `foreman-runs.jsonl`, `progress.txt` and handoff
  files.
- A light-background palette. The palette is for dark terminals; a light one is a later
  pick.
- Redrawing the run header in place as the screen scrolls. It is printed again when a
  ticket lands; the pinned status bar remains the only line held in place.
- Unicode fallbacks for terminals without block characters. `TERM=dumb` and narrow
  terminals get plain; others are assumed to have `▀▄█`.

## Further Notes

- Windows Terminal is the main terminal here and does not set `COLORTERM`; `WT_SESSION`
  is the signal. mintty (Git Bash's own window) sets `COLORTERM=truecolor`.
- A node start costs about 0.1–0.2s under MSYS. That is spent only on the show path, where
  a person is watching, and never inside the loop's per-event printing: the run header is
  drawn by one node call per landed ticket, not per line.
- The canvas is private (https://claude.ai/artifact/1gZzR6gkwUu9PMKwuEXuqD); `designs/` is the
  copy that lives with the repo.
