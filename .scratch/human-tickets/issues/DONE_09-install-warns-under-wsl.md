# 09: install.sh warns when it runs under WSL, and the README says how to run it on Windows

**Status:** done

**Blocked by:** None (can start immediately)

**What to build:**

Reported by the handoff for ticket 07 (problem 2). In PowerShell, `bash` resolves to
`C:\Users\user\AppData\Local\Microsoft\WindowsApps\bash.exe`, the WSL launcher. `bash install.sh`
therefore ran inside WSL and installed the shims and the skill into the WSL home
(`/home/ori`), where Windows Claude Code and PowerShell cannot see them, and printed no warning.
`bash .\install.sh` failed too, because the Linux shell ate the backslash. What worked:
`bash install.sh --uninstall` (to clean the WSL install), then
`& "C:\Program Files\Git\bin\bash.exe" install.sh`.

Make `install.sh` detect that it is running under WSL (for example `/proc/version` mentions
`microsoft`, or `WSL_DISTRO_NAME` is set) and say plainly that what it installs goes into the
WSL home and not the Windows one, and how to run it from Git Bash instead. Warn rather than
refuse: installing for WSL itself is legitimate. Update the README Install section to say that
from PowerShell the command is `& "C:\Program Files\Git\bin\bash.exe" install.sh` (or run it
from Git Bash), and why plain `bash` may not do.

**Acceptance criteria:**

- [x] Under WSL, `install.sh` prints a warning naming the WSL home it is installing into and the
      Git Bash command to use for Windows; outside WSL it prints nothing new
- [x] The warning does not change the exit code or what is installed
- [x] The README's Install section shows the PowerShell command using Git Bash's `bash.exe` and
      says a plain `bash` there may be the WSL launcher
- [x] A smoke case covers the detection (forced through an environment variable or a fake
      `/proc/version` seam, not a real WSL), and `bash test/smoke.sh` passes in full

**Note:** `install.sh` detects WSL from `WSL_DISTRO_NAME` or `microsoft` in `/proc/version`
(`FOREMAN_PROC_VERSION` is the test seam for the latter) and prints a warning, at the top of every
mode except `--help`, naming `$HOME` and the Git Bash command. Nothing else changed. The README's
Install section gained the PowerShell command and the reason a plain `bash` may not do. New smoke
case: "install.sh warns under WSL, ...".

Full smoke suite: 495 passed in 6m 47s
