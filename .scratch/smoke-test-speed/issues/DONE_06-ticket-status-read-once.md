# 06: A ticket's status line is read once, and every question is answered from that read

**What to build:** Each question asked of a ticket (is it the done word, is it the human
word, what does its `Checks:` line say) is today a `grep`, or a `sed | head | tr | sed`
pipeline, run against the file again. Read what is needed from each ticket once per command
and answer every question from that read, with bash pattern matching rather than a process
per question; where the same ticket is asked about repeatedly within one command, reuse the
answer. See `spec.md`, "Ticket status checks".

**Blocked by:** 03 (the baseline) and 05 (take the "before" after 05 has landed: 05 changes
how many times these checks run, and this ticket's payoff should be measured against what
is left).

**Status:** done

**Share of the baseline spawns** (532 events, before 05): **107 events (20%)**, every one of
them outside the config load, so 05 does not remove them. They are 49 `grep` calls (28 in
`ralph_ticket_needs_human`, 18 in `ralph-next.sh`'s done/remaining split, 3 in
`ralph_human_warnings`); 6 `ralph_ticket_field` calls, each a `sed | head | tr | sed`
pipeline (12 `sed`, 6 `head`, 6 `tr`); and the 34 subshells around them (24 in
`ralph_ticket_field`, 6 in `print_remaining_marked`, 4 in `ralph_human_warnings`). The 3
tickets are each asked about 6 to 10 times.

- [x] Each ticket's file is read at most once per command for its status line, and the done, human and followup-name answers come from that read
- [x] No `grep`, `sed`, `head` or `tr` process is started per question per ticket; the benchmark's `grep` row falls accordingly
- [x] The empty-pattern rule holds: with `RALPH_HUMAN_WORD=` (feature off) nothing is a human ticket, and an empty pattern is never treated as matching every line
- [x] Done still wins over human; a `Checks:` value still reads the same with or without the bold markers, with a CRLF line ending, and with trailing whitespace
- [x] Behaviour contract: output may change in wording or spacing, but **every existing smoke assertion passes with none edited**; which ticket is next, whether it is a human ticket, whether it has landed and which warnings are raised do not change
- [x] The benchmark's before (taken after 05) and after are recorded here, median and spawn table; the expected effect is most of the 107 events, about 15-20% of the baseline total
- [x] `bash test/smoke.sh` passes in full; the closing note records `Full smoke suite: N passed in Mm Ss`

## Comments

**Closing note.** Design: a ticket's file is read once, in bash, by `_ralph_ticket_read` (`lib/ralph-tickets.sh`), and that one pass answers all three questions: done, human, and the `Checks:` name. `ralph_ticket_status TICKET` sets `_RALPH_TICKET_DONE`, `_RALPH_TICKET_HUMAN` and `_RALPH_TICKET_CHECKS` rather than printing them, so the hot callers (`print_remaining_marked`, `ralph_human_warnings`, `_ralph_checkers_of`, `ralph order`) ask with no subshell. `ralph_ticket_needs_human`, `ralph_ticket_is_done` and `ralph_ticket_field` stay as thin wrappers for every other caller. Done wins over human inside the one read.

The ticket-list snapshot from 05 now also holds those reads: `ralph_tickets_hold` reads every ticket once, `ralph_tickets_release` drops them, and the cache is only consulted while a snapshot is held, so the loop (which releases at the top of every pass) and `ralph next` read the file at each question, as before, and never see a stale status. With no snapshot a question costs one pass of bash and no process.

The patterns are still grep BREs (`RALPH_DONE_PATTERN`, `RALPH_HUMAN_PATTERN` are documented and can be set in `ralph.conf`), so `ralph-config.sh` derives an ERE from each once per command (`_ralph_bre_to_ere`) and the read matches lines with `[[ =~ ]]`. A BRE it does not translate (a backreference, a GNU word escape such as `\<`, `\{,n\}`, an unclosed bracket, or one bash refuses to compile) leaves the ERE empty, and that pass hands the file to grep once: a pattern is never read differently, only more slowly. The empty-pattern rule holds: an empty human pattern never reaches the match.

Checked that the behaviour contract holds, three ways. (1) The translator against `grep`, about 2,100 pattern-by-line comparisons (the defaults, alternation, intervals, brackets, literal `( ) { } | + ?`, leading `*`, `^` and `$` in every position), on Git Bash (bash 5.2) and on WSL (bash 4.4, glibc): no mismatches; the cases it cannot translate fall back. (2) Old (`git archive HEAD`) against new on four awkward batches (a human ticket and its followup, CRLF and bold and plain `Checks:`, an `order.md` with a `DONE_` ticket, an empty file, `doneish` and `ready-for-humanish` near-misses) under ten configurations (defaults, `RALPH_HUMAN_WORD=` off, another word, a custom status line, custom done and human patterns, a backreference and a GNU word escape and a broken bracket that force the fallback, `RALPH_DONE_PREFIX=` empty), through `status`, `dry-run` and every `next` mode: 240 runs, output and exit codes identical. (3) Two characterization cases added to the smoke suite before the change and green against the old code: `Checks:` read bold or plain, with CRLF and with trailing spaces (and an empty first `Checks:` line winning); and custom `RALPH_DONE_PATTERN` / `RALPH_HUMAN_PATTERN` matched as grep patterns. No existing assertion was edited.

**Benchmark, Git Bash** (`bash test/bench.sh 5`, bash 5.2.26, 2026-09-30; before is clean HEAD `8c79124`, after 05 landed):

| | median | runs | spawns |
|---|---|---|---|
| before | 4.03 s | 3.87, 4.03, 4.93, 3.82, 4.20 | 176 |
| after | **1.68 s** | 1.71, 1.71, 1.60, 1.65, 1.68 | **78** |

Spawn table, before, then after:

```
before                                           after
   85  (subshells, command substitutions)          55  (subshells, command substitutions)
   45  grep        14  sed                          8  basename       5  dirname
    8  basename     6  head, 6 tr                   3  git            2  sed
    5  dirname      3  git                          1 each: bash, cut, find, grep, sort
    1 each: bash, cut, find, sort
  176  total                                        78  total
```

98 of the 107 events in this ticket's share are gone: the `grep` row fell from 45 to 1 (the `grep -c .` in the config's batch discovery, not a status check), `head` and `tr` to 0, and `sed` from 14 to 2 (the config's status-line escape, run for each pattern; ticket 07's). That is 18% of the 532-event baseline, inside the expected 15-20%, and the median fell 58%. The 98 are 44 `grep`, 12 `sed`, 6 `head`, 6 `tr` and 30 subshells. The other 9 of the 107 were already gone before this ticket's "before" was taken (05 took `grep` from 49 to 45, for one), which is why the payoff is measured against what 05 left.

Left alone, on purpose: `ralph order` holds no snapshot (its list is `--unordered`, and it rewrites `order.md` afterwards), so it reads each ticket twice, once in its own loop and once for the warnings: two passes of bash, no process. `ralph_was_sent_back` (`grep | tail | tr | sed` on a `## Sent back by` heading) is not a status-line question and is asked of a human ticket only. `ticket_is_done` in the loop remains as a named wrapper.

Code review (standards and spec, in parallel): no hard violations. Fixed from it: `^^a` read as two anchors (a second `^` is a literal in a BRE) and `a\{,2\}` compiled in bash with a different meaning than grep's, so neither fell back (both now translate correctly or fall back, and both are in the translator comparison); a `head -n 1` per human ticket in the warnings became parameter expansion; three comments that overstated "no process" or misdescribed the empty-pattern guard. Left as judgement calls: the three result variables and three cache arrays move in lockstep (a fourth answer is four edits, a fair price in bash), and `ralph_ticket_needs_human` and `ticket_is_done` are thin wrappers kept as stable names.

Full smoke suite: 479 passed in 13m 4s

That is the 466 assertions of 05's run plus the 13 of the two new cases, with no existing assertion edited. (05 recorded 16m 3s; run time varies with what else the machine is doing, and this ticket's change does not touch the suite's harness.) One earlier full run of this same code failed 7 assertions in "a checkpoint turn is recorded as its own row" and passed alone and in a clean rerun: the fake adapter keeps its call counter in `$TMPDIR/ralph-fake-<pid>.calls` and never removes it, so a recycled PID inherits an old count (1,821 such files in `/tmp`). Not caused by this ticket, and not fixed here; the passing run above used a fresh `TMPDIR`, which avoids it. Filed as a follow-up task.
