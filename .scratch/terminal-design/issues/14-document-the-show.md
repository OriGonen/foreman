# 14: Document the show

**What to build:** A person reading the README knows the output has two renderings, and
how to steer them. It covers the show and plain, the colour tiers, `FOREMAN_COLOR`,
`FOREMAN_SHOW`, `FOREMAN_INTRO`, `NO_COLOR` and `CI`, and that scripts get plain. The
header comments of `foreman-ui.sh` and `foreman-draw.cjs` describe the split and how to add
a scene. See `spec.md`, "Solution".

**Blocked by:** 03, 05, 06, 07, 09, 10, 11, 12, 13

**Status:** ready-for-agent

- [ ] README: a "Terminal output" section, with the environment variables and what each does
- [ ] `CONTEXT.md`: "the show" and "plain output", if code and docs use them as terms
- [ ] `foreman-draw.cjs`'s header names each scene, the facts it takes, and where its design lives
- [ ] `test/demo.sh` shows each command's show once, for a look by eye
- [ ] Full smoke suite passes; the closing note records `Full smoke suite: N passed in Mm Ss`
