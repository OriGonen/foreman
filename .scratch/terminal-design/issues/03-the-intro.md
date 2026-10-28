# 03: The intro on bare foreman and foreman help

**What to build:** Bare `foreman` and `foreman help` at a terminal play the Intro3
animation (36 frames, 2.5s), ending on the D1 sunrise, then print the help. Any key skips
to the end, and `FOREMAN_INTRO=0` turns it off. It never plays when stdout or stdin is not
a terminal, or in CI. This ticket adds the renderer's animation support, which the
doctor's inspector reuses. See `spec.md`, "The renderer" (Animation) and "Per command".
The design is `designs/02-intro3-frames.ans`, from `designs/source/Intro3.dc.html`.

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] Frames play on a timer at the design's pace; the last frame is left on screen and the help follows it without a jump
- [ ] Any key skips to the last frame; stdin is raw only while it plays and is restored after
- [ ] The cursor is hidden while it plays and shown again on every exit: at the end, on a key, on Ctrl-C, and on an error
- [ ] With `FOREMAN_INTRO=0`, in `CI`, with stdout piped, or with stdin not a terminal, there is no intro and help is as in 02
- [ ] `--frame N` draws one frame and exits
- [ ] Smoke: `--frame 0` and `--frame 35` hold the design's key rows; a forced show with stdin from `/dev/null` does not wait
- [ ] Checked by hand: the skip key works, and Ctrl-C mid-intro leaves a visible cursor and a sane terminal
- [ ] README documents `FOREMAN_INTRO`
- [ ] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
