# Handoff — 07: Try the followup-tickets skill on a real batch

<!-- Fill in every section, then set ticket 07's status line to done, tick its boxes, and
     commit. This file is committed and read by an agent (ticket 07a): if anything involves a
     secret, record WHERE it is stored, never its value. -->

## The skill installs, and Claude Code lists it
uninstalled and then installed with this command:
PS C:\Projects\foreman> & "C:\Program Files\Git\bin\bash.exe" install.sh
I opened a claude code from terminal and I was able to see the skill
<!-- Where it was installed, and how you saw Claude Code list it. -->
C:\Users\user\.claude\skills\foreman-human-followup-tickets\
## The first run added a Handoff: line, a handoff file and a followup ticket for every human ticket, and nothing else

<!-- The human tickets in your batch, and what the skill wrote for each. Anything else it
     touched. -->
yes it worked

This is the output
```
❯ /foreman-human-followup-tickets

  Searched for 3 patterns, ran 4 shell commands

The em dashes were written as cp1252 bytes, which isn't valid UTF-8. I'm converting them and amending the commit.

  Ran 1 shell command

I added a Handoff: line, a handoff file and a followup ticket for both open human tickets in .scratch/tipjar-launch, and committed them as 6a5c3b3. Ticket 01 was already done, so I skipped it. I haven't run any foreman commands.

┌───────────────────────────────┬───────────────────────────────────────┬─────────────────────────────────────────┐
│         Human ticket          │             Handoff file              │             Followup ticket             │
├───────────────────────────────┼───────────────────────────────────────┼─────────────────────────────────────────┤
│ 04-create-payment-account.md  │ handoff/04-create-payment-account.md  │ 04a-followup-create-payment-account.md  │
├───────────────────────────────┼───────────────────────────────────────┼─────────────────────────────────────────┤
│ 06-register-domain-and-dns.md │ handoff/06-register-domain-and-dns.md │ 06a-followup-register-domain-and-dns.md │
└───────────────────────────────┴───────────────────────────────────────┴─────────────────────────────────────────┘

Each handoff file has one section per acceptance criterion of its ticket. Each followup ticket is blocked by its human ticket, with a Checks: line naming it, plus the four criteria and the passes/falls-short outcomes.

- Ticket 05: it is still blocked by 03, 04, not 04a. I didn't touch it. The loop only renames 04 once 04a passes, so 05 waits either way.
- foreman.conf: none exists, and there is no docs/agents/triage-labels.md. The labels are the defaults (ready-for-human, ready-for-agent), so nothing needs adding to foreman.conf.
- Encoding: my first write saved the em dashes in the wrong encoding. I fixed them to UTF-8 and amended the commit before finishing.

Next:  foreman init tipjar-launch   (or: foreman order tipjar-launch, if tipjar-launch/foreman.conf already exists — the new followup tickets only run once order.md lists them)
Then:  foreman status tipjar-launch should show no warnings.
```

## The second run changed nothing

<!-- What it said, and whether any file or commit changed. -->
ran it again and it didn't change anything
```
❯ /foreman-human-followup-tickets

  Searched for 3 patterns, ran 1 shell command

Single batch. Let me read the tickets.

  Ran 1 shell command

I made no changes: both not-done human tickets already carry all three pieces.

┌────────────────────────────┬───────────────┬──────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────────────────────┐
│        Human ticket        │ Handoff: line │                 Handoff file                 │                                  Followup ticket                                  │
├────────────────────────────┼───────────────┼──────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
│ 04-create-payment-account  │ present       │ handoff/04-create-payment-account.md exists  │ 04a-followup-create-payment-account.md has Checks: 04-create-payment-account.md   │
├────────────────────────────┼───────────────┼──────────────────────────────────────────────┼───────────────────────────────────────────────────────────────────────────────────┤
│ 06-register-domain-and-dns │ present       │ handoff/06-register-domain-and-dns.md exists │ 06a-followup-register-domain-and-dns.md has Checks: 06-register-domain-and-dns.md │
└────────────────────────────┴───────────────┴──────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────────────────────┘

- Done ticket: DONE_01-choose-name-and-license.md is done, so I skipped it.
- Labels: docs/agents/triage-labels.md doesn't exist, so the labels are the literal ready-for-human and ready-for-agent. There is no foreman.conf yet, and since the human label is the default, no FOREMAN_HUMAN_WORD line is needed.
- Commit: nothing to commit; the working tree stays clean.

Next:  foreman init tipjar-launch   (or: foreman order tipjar-launch, if tipjar-launch/foreman.conf already exists — the followup tickets only run once order.md lists them)
Then:  foreman status tipjar-launch should show no warnings.

✻ Cooked for 15s · done 9:23 PM
```
## The third run, after foreman init, added only the new ticket's pieces and pointed at foreman order; after ordering, foreman status showed no warnings

<!-- What it added, its closing message, and the `foreman status` output after `foreman order`. -->
```
❯ /foreman-human-followup-tickets

  Searched for 3 patterns, read 1 file, ran 2 shell commands

Only human ticket 08 was missing its pieces. Tickets 04 and 06 already had all three, so I left them alone. The check confirms 04, 06 and 08 each have a Handoff: line, a handoff file, and a followup ticket whose Checks: line names them.

I made one commit, ec22280, with three changes for ticket 08:
- Handoff: line: added under its status line in 08-legal-review-of-terms.md.
- Handoff file: handoff/08-legal-review-of-terms.md has one section per acceptance criterion.
- Followup ticket: issues/08a-followup-legal-review-of-terms.md, with status ready-for-agent and Blocked by: 08.

docs/agents/triage-labels.md doesn't exist, so the labels are the literal ready-for-human and ready-for-agent. That matches the default human label, so foreman.conf needs no FOREMAN_HUMAN_WORD line.

Next:  foreman order tipjar-launch (foreman.conf already exists, and 08a only runs once order.md lists it)
Then:  foreman status tipjar-launch should show no warnings.
```


PS C:\Projects\foreman-testbed\tipjar-demo> foreman order .scratch/tipjar-launch
foreman order: reading 11 ticket(s) in .scratch/tipjar-launch ...
foreman order: wrote .scratch/tipjar-launch/order.md (cost $0.1551)
             review it — this is a first pass, not a guarantee.
PS C:\Projects\foreman-testbed\tipjar-demo> foreman status .scratch/tipjar-launch
Batch: .scratch/tipjar-launch
Tickets done: 1 / 11  ·  human tickets remaining: 3

Next: 02-scaffold-cli.md

Remaining, in order:
  1  02-scaffold-cli.md
  2  03-config-loader.md
  3  04-create-payment-account.md   [HUMAN]
  4  04a-followup-create-payment-account.md   [CHECKS 04-create-payment-account.md]
  5  05-payment-client.md
  6  06-register-domain-and-dns.md   [HUMAN]
  7  06a-followup-register-domain-and-dns.md   [CHECKS 06-register-domain-and-dns.md]
  8  07-webhook-endpoint.md
  9  08-legal-review-of-terms.md   [HUMAN]
 10  08a-followup-legal-review-of-terms.md   [CHECKS 08-legal-review-of-terms.md]

The loop will run 2 ticket(s), then stop at 04-create-payment-account.md for a human.
PS C:\Projects\foreman-testbed\tipjar-demo>
## Everything the skill got wrong or unclear

<!-- One item per problem: what happened, what you expected, and the file it concerns. Write
     "none" if there were none. -->


1. Skill writes em dashes as cp1252 bytes (invalid UTF-8). Run 1 noticed and fixed it
   before finishing; run 3 did not. Expected: every file it writes is valid UTF-8 and it
   checks that before committing. In the fixture, handoff/08-legal-review-of-terms.md and
   issues/08a-followup-legal-review-of-terms.md still hold raw 0x97 bytes (commit ec22280).
   Concerns: skills/foreman-human-followup-tickets/SKILL.md (steps 3 and 5: nothing says to
   write UTF-8 or to verify it).

2. install.sh succeeds silently under WSL. In PowerShell, `bash` resolves to
   C:\Users\user\AppData\Local\Microsoft\WindowsApps\bash.exe (the WSL launcher), so
   `bash install.sh` installed the shims and skill into /home/ori, where Windows Claude Code
   cannot see them, and it printed no warning. `bash .\install.sh` also failed, because the
   backslash is eaten by the Linux shell. Worked: `bash install.sh --uninstall`, then
   `& "C:\Program Files\Git\bin\bash.exe" install.sh`. Expected: install.sh to detect WSL
   and refuse or warn, or the README to say to use Git Bash from PowerShell.
   Concerns: install.sh, README.md (install section).

3. On a run that changes nothing, the closing "Next: foreman init" message still prints
   (run 2). By design per SKILL.md step 6, but it read as noise. Minor.
