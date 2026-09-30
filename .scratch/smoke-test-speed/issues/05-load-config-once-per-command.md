# 05: The config and the ticket list are loaded once per command, not once per question

**What to build:** `ralph status` asks the batch a handful of questions (how many are done,
which is next, what remains, which are human tickets, what warnings apply), and today each
one starts a fresh `bash ralph-next.sh`, which sources `ralph-config.sh` from nothing:
finds the repository root, asks git for the batch's prefix twice, loads `ralph.conf`,
resolves six paths, loads the exec adapter. The baseline trace shows that load running **7
times** in one `status` call. Make it run once, and let the ticket list be answered from
that one load. `ralph next` stays a command with the same output and exit codes. See
`spec.md` ("Where the library spawns go") and "Baseline" in
`DONE_03-baseline-and-write-hotspot-tickets.md`.

This hotspot is **not one of the five the spec named**. The measurement found it: it is the
largest single payoff, and it is why the repository-location, path-helper and CRLF hotspots
are smaller than `report.md` suggested (see 08, 09 and the note in 03).

**Blocked by:** 03 (the baseline). Take the "before" on a clean HEAD.

**Status:** ready-for-agent

**Share of the baseline spawns** (one `ralph status batch`, 3 tickets, Git Bash, 532 events
classified): sourcing `ralph-config.sh`, `ralph-repo.sh` and `ralph-exec.sh` is **269 events
(50%)**, about 38 per load. Six of the seven loads are avoidable: about **230 events (43%)**.
The launches themselves (5 from `next_sh`, 1 from `_ralph_batch_tickets`) are 6 of the 7
`bash` rows, and the six repeated ticket-listing pipelines in `ralph-next.sh` (`find`,
`sort`, `cut`, a `basename` per ticket, and 78 subshells around them) are most of the
benchmark's remaining "other".

- [ ] `ralph status`, `ralph dry-run` and `ralph run`'s start-up load the batch's config once per command; the trace shows `ralph-config.sh` sourced once where it was sourced 7 times
- [ ] The ticket list is computed once per command and every question above is answered from it (or from exported results a child process inherits, if a child process is kept); the design is the implementer's, recorded in the closing note
- [ ] `ralph next` (and its `--list`, `--count`, `--all`, `--unordered` modes) prints what it printed and exits with the codes it exited with, including exit 1 for "nothing left" and exit 2 for a malformed batch, with the same messages
- [ ] Callers that read `ralph-next.sh`'s status (`pick_status`, `next_sh` in the preflight) still see the same status for the same batch
- [ ] Behaviour contract: output may change in wording or spacing, but **every existing smoke assertion passes with none edited**; which ticket is next, whether it is a human ticket, whether it has landed and which warnings are raised do not change
- [ ] The benchmark's before and after are recorded here (median and the full spawn table); the expected effect is the `bash` row falling from 7 to about 1 and the total falling by roughly 40%. If the drop is under half of that, the closing note says why
- [ ] `bash test/smoke.sh` passes in full; the closing note records `Full smoke suite: N passed in Mm Ss`
