# 09: Full smoke suite on Windows, alone

**Status:** ready-for-agent

**Blocked by:** 01, 02, 03, 04, 05, 06, 07, 08

**What to build:**

The sweep is done when the whole smoke suite passes on Windows Git Bash, run alone. Read the spec
(`.scratch/smoke-failures-windows/spec.md`) and the closing notes of tickets 01 to 08.

Run `bash test/smoke.sh` once, in the background, with no other suite running on the machine. It takes
about 28 minutes. Then run `node --test "test/node/*.test.cjs"`.

For any case that fails: if one of tickets 01 to 08 owns it and its fix fell short, fix it here. If
it's new or a product bug too big for this ticket, write it a ticket of its own under `.scratch/`.
If it's a timing case that ticket 06 recorded as flaky under load, rerun it alone and record the result.

Then close the spec. Fill in its **Done when** boxes from the tickets' closing notes, and under a
`## Comments` heading at the bottom, give each of the spec's clusters A to G a one-line summary: what it
turned out to be, how it was classified, and which ticket fixed it or now owns it.

- [ ] A full `bash test/smoke.sh` ran alone on Git Bash and shows 0 failures, or only failures that have their own tickets under `.scratch/`
- [ ] `node --test "test/node/*.test.cjs"` passes
- [ ] Every failure left over is listed in the closing note with the ticket that owns it
- [ ] The spec's Done-when boxes are ticked where met, and its `## Comments` section summarises each cluster
- [ ] The closing note records `Full smoke suite: N passed in Mm Ss`
