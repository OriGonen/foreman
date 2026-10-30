# 03: The intro on bare foreman and foreman help

**What to build:** Bare `foreman` and `foreman help` at a terminal play the Intro3
animation (36 frames, 2.5s), ending on the D1 sunrise, then print the help. Any key skips
to the end, and `FOREMAN_INTRO=0` turns it off. It never plays when stdout or stdin is not
a terminal, or in CI. This ticket adds the renderer's animation support, which the
doctor's inspector reuses. See `spec.md`, "The renderer" (Animation) and "Per command".
The design is `designs/02-intro3-frames.ans`, from `designs/source/Intro3.dc.html`.

**Blocked by:** 02

**Status:** implemented

- [x] Frames play on a timer at the design's pace; the last frame is left on screen and the help follows it without a jump
- [x] Any key skips to the last frame; stdin is raw only while it plays and is restored after
- [x] The cursor is hidden while it plays and shown again on every exit: at the end, on a key, on Ctrl-C, and on an error
- [x] With `FOREMAN_INTRO=0`, in `CI`, with stdout piped, or with stdin not a terminal, there is no intro and help is as in 02
- [x] `--frame N` draws one frame and exits
- [x] Smoke: `--frame 0` and `--frame 35` hold the design's key rows; a forced show with stdin from `/dev/null` does not wait
- [ ] Checked by hand: the skip key works, and Ctrl-C mid-intro leaves a visible cursor and a sane terminal
- [x] README documents `FOREMAN_INTRO`
- [x] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`

## Closing note

- Built: in `lib/foreman-draw.cjs` the Intro3 port (36 takes: sun, walk, stake, three blows, turn, salute; words `tink`/`TONK` over the art), `frames` on every scene, `--frame N` (0 to 35; default the last), `drawFrames`, `play(frames, {out, input, stepMs, signals})` and `--play [--step MS]`; `encode` takes `{erase}` so a frame clears the rest of each short row (not a row as wide as the terminal). `usage_show` in `bin/foreman` plays it before the help when stdin and stdout are terminals, `CI` is unset, `FOREMAN_INTRO` is not `0` and the terminal is 66+ columns; the last frame is the sunrise, so the help text follows it with no second picture.
- Exit codes of `--play`: 0 played or skipped, 130 Ctrl-C (the dispatcher exits 130, no help), 4 nowhere to play (stdin/stdout not a terminal, or under 20 rows): the dispatcher draws the still sunrise. The dispatcher also prints `ESC[?25h` itself after node, for a node that was killed.
- Checked cell by cell against `designs/02-intro3-frames.txt` and `.ans` at 24 bits: all 36 frames identical, bar one cell in each design file where the file itself holds a U+FFFD (an export artefact). The design's last two takes are the same picture. Its canvas is 66 wide, so the last frame's ground is two columns wider than the help's 64.
- Skip key and Ctrl-C were checked on a pty (`script`): the bytes show `?25l` once and `?25h` after, `status=130`, and `stty -a` reports `icanon echo` afterwards (now in the smoke suite). NOT done: looking at it in a real window, which a sandbox cannot do; left unchecked for a person (the by-hand box above stays unchecked, as in 02).
- Full smoke suite: 1174 passed in 1m 6s, 1 failed — "convert moves a ralph project…" (CRLF prose), which fails identically before this ticket.
