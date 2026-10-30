# 14: Document the show

**What to build:** A person reading the README knows the output has two renderings, and
how to steer them. It covers the show and plain, the colour tiers, `FOREMAN_COLOR`,
`FOREMAN_SHOW`, `FOREMAN_INTRO`, `NO_COLOR` and `CI`, and that scripts get plain. The
header comments of `foreman-ui.sh` and `foreman-draw.cjs` describe the split and how to add
a scene. See `spec.md`, "Solution".

**Blocked by:** 03, 05, 06, 07, 09, 10, 11, 12, 13

**Status:** implemented

- [x] README: a "Terminal output" section, with the environment variables and what each does
- [x] `CONTEXT.md`: "the show" and "plain output", if code and docs use them as terms
- [x] `foreman-draw.cjs`'s header names each scene, the facts it takes, and where its design lives
- [x] `test/demo.sh` shows each command's show once, for a look by eye
- [x] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
