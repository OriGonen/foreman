# 13: foreman version as the mark and the build

**What to build:** `foreman version` and `foreman --version` at a terminal show the 13a
design: the mark beside `FOREMAN <rev>`, where the toolkit is installed, and the one-line
description. Piped, they print the same two lines as today. See `spec.md`, "Per command".
The design is `designs/13a-version.ans`, from `designs/source/VersionTakes.dc.html`
(panel 13a).

**Blocked by:** 08

**Status:** ready-for-agent

- [ ] `--version` is the same as `version`
- [ ] Piped output is byte for byte today's two lines
- [ ] Smoke: the forced show holds the rev and the install path; plain output is two lines
- [ ] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
