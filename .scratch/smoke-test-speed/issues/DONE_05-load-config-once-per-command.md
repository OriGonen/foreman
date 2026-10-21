# 05: The config and the ticket list are loaded once per command, not once per question

**What to build:** `foreman status` asks the batch a handful of questions (how many are done,
which is next, what remains, which are human tickets, what warnings apply), and today each
one starts a fresh `bash foreman-next.sh`, which sources `foreman-config.sh` from nothing:
finds the repository root, asks git for the batch's prefix twice, loads `foreman.conf`,
resolves six paths, loads the exec adapter. The baseline trace shows that load running **7
times** in one `status` call. Make it run once, and let the ticket list be answered from
that one load. `foreman next` stays a command with the same output and exit codes. See
`spec.md` ("Where the library spawns go") and "Baseline" in
`DONE_03-baseline-and-write-hotspot-tickets.md`.

This hotspot is **not one of the five the spec named**. The measurement found it: it is the
largest single payoff, and it is why the repository-location, path-helper and CRLF hotspots
are smaller than `report.md` suggested (see 08, 09 and the note in 03).

**Blocked by:** 03 (the baseline). Take the "before" on a clean HEAD.

**Status:** done

**Share of the baseline spawns** (one `foreman status batch`, 3 tickets, Git Bash, 532 events
classified): sourcing `foreman-config.sh`, `foreman-repo.sh` and `foreman-exec.sh` is **269 events
(50%)**, about 38 per load. Six of the seven loads are avoidable: about **230 events (43%)**.
The launches themselves (5 from `next_sh`, 1 from `_foreman_batch_tickets`) are 6 of the 7
`bash` rows, and the six repeated ticket-listing pipelines in `foreman-next.sh` (`find`,
`sort`, `cut`, a `basename` per ticket, and 78 subshells around them) are most of the
benchmark's remaining "other".

- [x] `foreman status`, `foreman dry-run` and `foreman run`'s start-up load the batch's config once per command; the trace shows `foreman-config.sh` sourced once where it was sourced 7 times
- [x] The ticket list is computed once per command and every question above is answered from it (or from exported results a child process inherits, if a child process is kept); the design is the implementer's, recorded in the closing note
- [x] `foreman next` (and its `--list`, `--count`, `--all`, `--unordered` modes) prints what it printed and exits with the codes it exited with, including exit 1 for "nothing left" and exit 2 for a malformed batch, with the same messages
- [x] Callers that read `foreman-next.sh`'s status (`pick_status`, `next_sh` in the preflight) still see the same status for the same batch
- [x] Behaviour contract: output may change in wording or spacing, but **every existing smoke assertion passes with none edited**; which ticket is next, whether it is a human ticket, whether it has landed and which warnings are raised do not change
- [x] The benchmark's before and after are recorded here (median and the full spawn table); the expected effect is the `bash` row falling from 7 to about 1 and the total falling by roughly 40%. If the drop is under half of that, the closing note says why
- [x] `bash test/smoke.sh` passes in full; the closing note records `Full smoke suite: N passed in Mm Ss`

## Comments

**Closing note.** Design: the answer to `foreman next` is now a set of functions, in a new `lib/foreman-tickets.sh`, that `foreman-next.sh` (the command, a thin argument parser in front of them) and the loop both use. `next_sh` and `_foreman_batch_tickets` call `foreman_next_answer` in-process instead of starting `bash foreman-next.sh`, so a command loads its config once. `foreman order` does the same for its `--unordered` question (it already had the config loaded); `foreman init` and `foreman doctor` still start `bash foreman-next.sh` (init loads no config; doctor asks about many batches).

The ticket list is held as a **snapshot**: `foreman_tickets_hold`, called in the command's own shell (not inside a `$( )`, where it would die with the subshell), computes the ordered list once, and every later question, from a subshell or not, answers from it. `status` holds it for the whole command; the preflight holds it for `dry-run`. A `run` releases it before the start-up sweep (the sweep renames tickets), holds it again for the start-up questions, and releases it at the top of every loop pass, since an iteration can land, rename or reorder tickets; inside the loop every question recomputes, exactly as before, minus the config load. With no snapshot held, every question is computed fresh, so holding one is only ever a saving. The snapshot holds ticket **paths** only; whether a ticket has landed is still read from its file at each question. That is ticket 06's hotspot and is untouched, except that `--all`, `--unordered` and `next` (which stops at the first ticket not done) no longer grep every ticket.

`foreman next` prints the same and exits the same (0, 1 nothing left, 2 malformed): checked against an untouched copy of HEAD on eight batches (plain, human and followup tickets with an `order.md` and a `DONE_` ticket, an order entry that does not exist, an order file with no markers, an empty batch, all done, an empty ORDER block, CRLF `foreman.conf` and `order.md`) through `status`, `dry-run` and every `next` mode: output and exit codes identical, the one difference being the toolkit path printed in a message, because the old copy lived elsewhere. `foreman-config.sh` is sourced once per `status` and `dry-run` where it was sourced 7 times (counted from an xtrace of each). The one wording change is the loop's own `foreman-next.sh failed with status N`, now `foreman next failed with status N`, since nothing starts `foreman-next.sh` there; no assertion reads it.

**Benchmark, Git Bash** (`bash test/bench.sh 5`, bash 5.2.26, 2026-09-30, clean HEAD `c5e521a` before):

| | median | runs | spawns |
|---|---|---|---|
| before | 11.85 s | 12.27, 11.66, 11.85, 11.19, 12.24 | 533 |
| after | **4.21 s** | 4.26, 4.39, 4.01, 4.21, 3.93 | **176** |

Spawn table, before, then after:

```
before                                           after
  320  (subshells, command substitutions)          85  (subshells, command substitutions)
   56  grep        26  sed        21  git          45  grep        14  sed         3  git
   50  basename    23  dirname     7  bash          8  basename     5  dirname     1  bash
    6 each: cut, find, head, sort, tr                6 each: head, tr;  1 each: cut, find, sort
  533  total                                       176  total
```

The `bash` row fell from 7 to 1 (as expected) and the total fell by **67%**, against the expected 40%: the median by 64%. The drop beats the estimate because the config load also carried the `basename`/`dirname`/`sed`/`git` spawns that tickets 07-09 were sized on. What is left for them, for their re-measurement: `grep` 45 (ticket 06: the done and human checks per ticket, plus the `Checks:` field reads), `basename` 8, `dirname` 5, `sed` 14 (the config's status-line escape plus `foreman_ticket_field`), `git` 3. Ticket 08's and 09's own shares are now inside the one config load (about 4% of the new total each or less), so both are likely to close as re-measurement notes.

Code review (standards and spec, in parallel): no hard violations. Fixed from it: the snapshot could be clobbered if a non-ordered question was asked in the main shell while one was held (only the ordered list is held now, and any other question ends the snapshot); `foreman_next_answer` now rejects an unknown mode with exit 2 and the `foreman-next.sh` message, and accepts `--next`, as the command did; `foreman order` sources `foreman-tickets.sh` itself; two stale comments. Left alone, as judgement calls: the duplicated done-`grep` in `foreman_next_answer` (ticket 06 rewrites it), and `next_sh` as a thin wrapper.

Full smoke suite: 466 passed in 16m 3s

