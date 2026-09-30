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

**Status:** ready-for-agent

**Share of the baseline spawns** (532 events, before 05): **107 events (20%)**, every one of
them outside the config load, so 05 does not remove them. They are 49 `grep` calls (28 in
`ralph_ticket_needs_human`, 18 in `ralph-next.sh`'s done/remaining split, 3 in
`ralph_human_warnings`) and 12 `ralph_ticket_field` calls (12 `sed`, 6 `head`, 6 `tr`, and 24
subshells around them). The 3 tickets are each asked about 6 to 10 times.

- [ ] Each ticket's file is read at most once per command for its status line, and the done, human and followup-name answers come from that read
- [ ] No `grep`, `sed`, `head` or `tr` process is started per question per ticket; the benchmark's `grep` row falls accordingly
- [ ] The empty-pattern rule holds: with `RALPH_HUMAN_WORD=` (feature off) nothing is a human ticket, and an empty pattern is never treated as matching every line
- [ ] Done still wins over human; a `Checks:` value still reads the same with or without the bold markers, with a CRLF line ending, and with trailing whitespace
- [ ] Behaviour contract: output may change in wording or spacing, but **every existing smoke assertion passes with none edited**; which ticket is next, whether it is a human ticket, whether it has landed and which warnings are raised do not change
- [ ] The benchmark's before (taken after 05) and after are recorded here, median and spawn table; the expected effect is most of the 107 events, about 15-20% of the baseline total
- [ ] `bash test/smoke.sh` passes in full; the closing note records `Full smoke suite: N passed in Mm Ss`
