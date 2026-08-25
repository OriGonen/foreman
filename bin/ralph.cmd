@echo off
rem ralph, for PowerShell and cmd.exe. Git Bash is what the toolkit is written for; this
rem forwards to bin/ralph rather than reimplementing anything.
rem
rem It does NOT just run `bash`: in a plain cmd or PowerShell session the `bash` on PATH is
rem usually the WSL launcher in WindowsApps or System32, which lives in a different
rem filesystem and cannot open this checkout. Git for Windows' bash is found explicitly.
setlocal

set "RALPH_BASH="
if exist "%ProgramFiles%\Git\bin\bash.exe" set "RALPH_BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined RALPH_BASH if exist "%ProgramW6432%\Git\bin\bash.exe" set "RALPH_BASH=%ProgramW6432%\Git\bin\bash.exe"
if not defined RALPH_BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "RALPH_BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined RALPH_BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "RALPH_BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"

rem Last resort: derive it from wherever git itself is installed.
if not defined RALPH_BASH for /f "delims=" %%G in ('where git 2^>nul') do (
  if not defined RALPH_BASH if exist "%%~dpG..\bin\bash.exe" set "RALPH_BASH=%%~dpG..\bin\bash.exe"
)

if not defined RALPH_BASH (
  echo ralph: could not find Git for Windows' bash.exe. 1>&2
  echo        Install Git for Windows, or run ralph from a Git Bash shell. 1>&2
  exit /b 1
)

"%RALPH_BASH%" "%~dp0ralph" %*
exit /b %errorlevel%
