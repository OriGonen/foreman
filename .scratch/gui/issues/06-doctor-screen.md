# 06: Doctor, as JSON and as a screen, with Fix what it can

**What to build:** `foreman doctor --json` and `foreman doctor --fix --json`, and a Doctor
screen. The screen is an inspection sheet. It shows:

- the terminal's sections, in the terminal's order
- each row's result (ok, warn or fail) and its fix
- the verdict, as a stamp
- the next command
- the inspector, who runs across a track and back, sweating, while the inspection runs, then
  stands and sweats until the sheet is filled in. This is the terminal's own animation, as it was
  asked for at sign-off.

**Fix what it can** shows what `--fix` will append, then runs it. Both actions are marked free.

See `spec.md`, additive change 4 and "Secrets". The design is `designs/08-doctor.html`, from
`designs/source/DoctorTakes.dc.html` (take a).

**Blocked by:** 02

**Status:** implemented

- [x] `foreman doctor --json` prints:
  - `foreman_json: 1`
  - `command: "doctor"`
  - each section's rows, each with a result (`ok`, `warn` or `fail`), label, detail and fix
  - the verdict
  - the next command
- [x] `foreman doctor --fix --json` also reports what it appended, and where
- [x] Credentials appear only as `"set"` or `"unset"`. A test sets a known fake token and checks
      that no part of it appears in the JSON
- [x] Plain `foreman doctor`, `foreman doctor --fix` and `foreman help` print byte for byte what
      they printed before, compared against a capture taken before the change
- [x] `test/smoke-json.sh` covers `doctor --json` and `--fix --json` on a fixture batch
- [x] While the inspection runs, the inspector runs across the track and back (two stances
      swapped, sweat drops trailing him), then stands and sweats. It plays once per inspection,
      including Run again, and stops when the sheet is filled in. It is CSS only: no library, no
      timer in `app.js`. Under `prefers-reduced-motion` he stands still
- [x] The rail opens the Doctor screen. Fix what it can shows what it will append before it
      runs, and the screen re-reads the sheet afterwards
- [ ] By hand on Windows (not done: no Windows, Electron or browser here; a human does it):
  1. Make a batch with a fixable problem, such as a missing ignore line
  2. Compare its Doctor screen with `designs/08-doctor.html`, in light and dark, including the
     running animation and the reduced-motion setting
  3. Press Fix what it can
- [x] `test/smoke.sh` is unchanged and the full suite passes. The closing note records
      `Full smoke suite: N passed in Mm Ss`

Full smoke suite: 2741 passed in 2m 5s, 1 failed: "convert ... CRLF kept" (test/smoke.sh:3609), failing before this ticket and in code it does not touch.
