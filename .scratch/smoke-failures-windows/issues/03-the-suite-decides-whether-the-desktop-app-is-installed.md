# 03: The suite decides whether the desktop app is installed

**Status:** ready-for-agent

**Blocked by:** None (can start immediately)

**What to build:**

The init and doctor cases should give the same result on every machine, whether or not the machine
running the suite has the app installed. Read the spec first
(`.scratch/smoke-failures-windows/spec.md`, clusters B and E).

The likely cause, found while slicing: foreman decides the app is installed when
`gui/node_modules/electron` exists in the checkout it runs from. In this checkout it does. So
`foreman init` adds the `.foreman-run/` line to `.gitignore` and reports it. `foreman doctor` then
expects that line, so a repo that would be ready elsewhere isn't ready here, and `--fix` writes
something else. The baseline worktree had no `node_modules`, which is why it passed. Confirm or kill
this with evidence (run the doctor case alone and read the box, then diff init's output against its golden).

Cases in scope, from the spec's table: 3 and 7 (`plain foreman init is byte for byte what it was`),
17, 18, and 21 (`doctor asks the adapter what this repo needs`, which failed only in the run at
`abfb292`, like the others). If case 21 turns out to have another cause, explain and fix it here anyway.

The fix: the suite pins the answer to "is the app installed" for the cases that don't care. A case
of its own covers each answer, so the app's `.gitignore` line keeps being checked: init writes it,
doctor expects it and `--fix` adds it when the app is there, and none of that happens when the app is
absent. Label the fix product bug or test-environment issue. If pinning it needs a product seam, keep
that seam narrow and say in a comment why it exists.

Run each case alone, never while another suite runs. Do not run the full suite.

- [ ] The cause of each of cases 3, 7, 17, 18 and 21 is recorded in the closing note with evidence
- [ ] Each of those cases passes when run alone on Git Bash, in this checkout, where the app is installed
- [ ] Smoke cases assert init's and doctor's behaviour both with the app installed and without it
- [ ] Each fix is labelled product bug or test-environment issue in the closing note
- [ ] The closing note explains why Linux results are unchanged on a machine without the app
