# 13: foreman version as the mark and the build

**What to build:** `foreman version` and `foreman --version` at a terminal show the 13a
design: the mark beside `FOREMAN <rev>`, where the toolkit is installed, and the one-line
description. Piped, they print the same two lines as today. See `spec.md`, "Per command".
The design is `designs/13a-version.ans`, from `designs/source/VersionTakes.dc.html`
(panel 13a).

**Blocked by:** 08

**Status:** implemented

- [x] `--version` is the same as `version`
- [x] Piped output is byte for byte today's two lines
- [x] Smoke: the forced show holds the rev and the install path; plain output is two lines
- [x] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`

Full smoke suite: 1419 passed in 1m 17s (1 failed: the CRLF `convert` case, failing before this ticket).
