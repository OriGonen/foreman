@echo off
rem ralph - forwards to bin/ralph under Git Bash, so PowerShell and cmd.exe get the same
rem command as the bash shell does. Git Bash is what the toolkit is written for; there is
rem no separate Windows implementation to drift.
setlocal
set "RALPH_BIN=%~dp0ralph"
where bash >/dev/null 2>/dev/null || (echo ralph: bash is not on PATH. Install Git for Windows. 1>&2 & exit /b 1)
bash "%RALPH_BIN%" %*
exit /b %errorlevel%
