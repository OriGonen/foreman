# 08: foreman init as breaking ground

**What to build:** `foreman init` at a terminal shows the 7a design. It has the mark and
"FOREMAN breaks ground", the batch and what was found, and a `+` per file written. Then
come the ordering result (moved count, the human and check tickets, time, cost) and NEXT
with four numbered steps. This ticket adds the mark, which report and version reuse. See
`spec.md`, "Per command". The design is `designs/07a-init.ans`, from
`designs/source/InitTakes.dc.html`.

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] The mark is one renderer function, shared with report and version
- [ ] Files written are listed with `+`; `--force` over an existing batch says which were replaced
- [ ] `--no-order` drops the ordering line; a failed ordering says so in its place
- [ ] Plain init is byte for byte today's
- [ ] Smoke: a forced-show init of a fixture batch, with and without `--no-order`
- [ ] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
