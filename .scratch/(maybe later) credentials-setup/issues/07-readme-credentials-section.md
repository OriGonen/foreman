# 07: README "Credentials" section replaces the env-var Docker section

**Status:** ready-for-agent

**Blocked by:** 06

**What to build:**

A reader of the README learns how to keep a sandbox run signed in without reading code.

Replace the env-var "Staying signed in to Docker" section with a "Credentials" section:
`foreman setup` (and `setup docker`, `setup claude`, `--check`), where the file lives and how to
move it (`FOREMAN_CREDENTIALS_FILE`), the three keys, that a real environment variable
overrides the file, that the file is plaintext and outside every repo, and that credentials
never go in `foreman.conf`. Update the loop's header note and `foreman`'s help to match.

**Acceptance criteria:**

- [ ] The README has a "Credentials" section covering the points above, and no longer tells
      the reader to `setx` Docker variables
- [ ] The loop's header note and `foreman`'s help agree with the README
- [ ] Every command shown in the section exists and behaves as described
