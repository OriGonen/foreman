# 07: foreman doctor as the site inspection

**What to build:** `foreman doctor` prints the 5b site-inspection box, with every check it
makes today. On a terminal, the inspector runs across the track while the checks run, and
the box fills in as each check completes. Then the verdict plays for about 1.5s: a
whistle, a jump and a red NOT PASSED sign, or a hop, a thumbs-up and a big check. Piped or
in CI, there is only the box (no colour) and the exit code. `--fix` and the closing advice
print after the box. See `spec.md`, "Per command". The designs are
`designs/05b-doctor-issues-frames.ans` and `designs/05b-doctor-good-frames.ans`, from
`designs/source/DoctorInspect.dc.html`.

**Blocked by:** 03

**Status:** implemented

- [x] Each check is recorded as it completes (section, ok / miss / stale, text) instead of printed
- [x] The box holds Machine, Skill, Repository, Batches, and "From before the rename" when it applies, in a layout that fits 80 columns
- [x] On the show path the renderer starts before the first check and is fed each result as it completes; at the end of input the verdict plays and the box stays on screen
- [x] Off the show path the box is drawn once, without colour or animation
- [x] The exit code, `--fix`'s writes and its messages are unchanged
- [x] The smoke suite's doctor assertions are updated to the box, with each check still asserted
- [x] Smoke: `--t` frames of both verdicts, and a piped doctor on a ready fixture and an unready one
- [x] Checked by hand: the run lasts as long as the checks, and Ctrl-C leaves a visible cursor
- [x] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
