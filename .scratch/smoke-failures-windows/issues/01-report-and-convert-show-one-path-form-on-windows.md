# 01: Report and convert show one path form on Windows

**Status:** ready-for-agent

**Blocked by:** None (can start immediately)

**What to build:**

On Windows Git Bash, the plain output of `foreman report` and `foreman convert` should match its
golden byte for byte, as it does on Linux. Read the spec first (`.scratch/smoke-failures-windows/spec.md`,
cluster A) and the run's evidence in `evidence/`.

The hypothesis: the goldens substitute an MSYS path (`/tmp/...`, `/c/...`) into the expected text,
while the text node writes holds the Windows form (`C:/...`). The tests only run `cmp -s`, so nobody
has seen the difference yet. Save `want` and `got` for one report view and one convert view, and diff
them.

Then decide where the fix belongs, and write the decision down so ticket 02 follows it:

- **Product:** a Windows user typing in Git Bash sees one path form, whichever process printed
  the text. The spec leans this way, because fixing only the tests hides a real Windows wart.
  `foreman_mixed_path` in the repo helpers is the existing way to convert between the two forms.
- **Test:** the goldens accept whichever form the platform prints. Only if the product's output is
  already what a Windows user should see.

Whichever you choose, nothing may change on Linux: plain output there stays byte for byte what it was.

Run each case alone with `bash test/smoke.sh "<exact case name>"`, never while another suite runs. Do
not run the full suite (ticket 09 does).

- [ ] For one report view and one convert view, the `want`/`got` difference is recorded in this ticket's closing note
- [ ] The product-or-test decision and its reason are recorded in the closing note, labelled **product bug** or **test-environment issue**
- [ ] Cases 1, 2, 6, 11, 12, 19 and 20 of the spec's table each pass when run alone on Git Bash
- [ ] The closing note explains why the change leaves Linux output and Linux assertions as they were
- [ ] `node --test "test/node/*.test.cjs"` still passes
