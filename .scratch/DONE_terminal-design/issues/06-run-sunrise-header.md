# 06: foreman run with the figure and the climbing sun

**What to build:** `foreman run` at a terminal shows the 3a design. The header holds the
figure, the dome at the current done count, and the run facts. It is drawn when the run
starts, and drawn again one step higher, with a "↑ 05 landed" line, after each landed
ticket. Each iteration's lines are restyled as in the design. The pinned status bar
becomes the design's foot. With `--live`, the agent's tool calls print as
`│ mm:ss verb path`. Plain output and the run log are unchanged. See `spec.md`, "Per
command". The designs are `designs/03a-run-quiet-steps.ans` and
`designs/03a-run-live-steps.ans`, from `designs/source/RunSunrise.dc.html`.

**Blocked by:** 04

**Status:** implemented

- [x] The header draws at the start with the run id, batch, model, exec, budget, done of total and the next human ticket
- [x] After a landed ticket the header draws again with the sun higher; progressed, stalled, sent-back and failed iterations do not move the sun
- [x] The iteration line and outcome match the design (`1/3  05-…`, then `✓ landed  sha  ·  time  ·  $`)
- [x] The pinned bar shows the elapsed time, the iteration, spend of budget, live on/off and the keys; its keys and resize handling work as before
- [x] `--live` prints tool calls as `│ mm:ss verb path` on the show path; plain `--live` is unchanged
- [x] One node call per header draw, and none per event line
- [x] Plain run output and `foreman-runs.log` are byte for byte today's
- [x] Smoke: a forced-show run of the demo fixture holds the header facts, and a second header after a landed ticket
- [ ] Checked by hand: a real `foreman run 2 --live` in Windows Terminal, including a resize
- [x] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
