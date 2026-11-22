#!/bin/bash
# The control directory of a run: the one place that says what is in it and how to read and write it.
# Sourced, never run: by foreman-config.sh (so the loop, `foreman stop` / `keys` and the status facts
# have it) and by foreman-keys.sh. Its node twin is foreman-ctl.cjs, which defines the same names for
# foreman-stream.cjs, foreman-json.cjs and the app; test/node/ctl.test.cjs holds the two lists together.
#
# The directory is `<batch>/.foreman-run/` when the repository ignores that name (`**/.foreman-run/`),
# and `<git-dir>/foreman-run/<key>` otherwise (ctl_dir, below): either way the loop, `foreman keys` /
# `foreman stop`, the status facts and the app find it by asking the same question, so the one-run
# lock, steering and the live view work with or without the ignore line. The loop removes it when the
# run ends, except `out`.
#
# The loop, the key reader (foreman-keys.sh), `foreman keys` / `foreman stop` and the stream filter
# talk through small files in it, so none has to signal another:
#   budget     the iteration budget, 0 for unlimited. Seeded by the loop, then written only
#              by the key reader (temp file plus mv, so the loop never reads half a number).
#   live       1 while the live view is on, else 0. Seeded by the loop, then written only
#              by the key reader; read by foreman-stream.cjs when there is no bar.
#   iteration  the iteration now running, written by the loop. Only read by the key reader.
#   screen     "ROWS COLS KEPT" while the loop has a status bar open: the terminal's size and
#              how many bottom rows are held back. Written by the loop, then by the key reader on a
#              resize or an L. No file, no bar: each key press prints a line instead.
#   activity   "EPOCH LABEL" while an iteration runs with a bar open: when it started and what
#              the agent did last. Written by foreman-stream.cjs, removed by the loop after.
#   foot       the epoch second the run started, when the loop is showing the design (ticket 06):
#              the bar is then the design's foot, `0m41s elapsed · iteration 1 of 3 · $0.34 of $25
#              · live off`, and the live view's row has its spinner. No file, the bar it always was.
#   spent      "COST BUDGET" for the foot: what the run has spent so far and the cost budget (0 for
#              none). Written by the loop after every iteration.
#   pid        "MSYS_PID WINDOWS_PID": the loop's pid, and the one Windows knows it by (`/proc/$$/winpid`;
#              the same number off Windows). Written by the loop last, once the files above are in
#              place, so a pid is a run that is ready. Read by `foreman status --json`, `foreman keys`
#              and `foreman stop`, to know a run is in flight (run_pid_alive, below).
#   run        "RUN_ID STARTED_AT": the run's id and its start time (UTC, ISO 8601). Written once.
#   feed       the calls `--live` shows, one per line, `00:41 · Write README.md`: the clock since the
#              iteration's agent started, and the label. Written by foreman-stream.cjs only while the
#              live view is on, emptied by the loop at each iteration. No file until there is a call.
#   stop       exists once `foreman stop --now` has asked the run to end; its content is the stopper's
#              pid. Read by the loop after each agent turn (check_stop_file).
#   out        the run's own stdout and stderr, when the app started it. Not the loop's: the app creates
#              it, and it outlives the run (ctl_clear keeps it) so a preflight failure can still be read.
#
# Names are the values of CTL_F_*, so no caller spells one; CTL_FILES lists them all. Callers build
# paths as "$dir/$CTL_F_BUDGET" and the like: no function call, so the key reader's idle loop (builtins
# only, see foreman-keys.sh) can use them too.

# Sourced from more than one place in one shell: the names are readonly, so define them once.
[ -z "${_FOREMAN_CTL_LOADED:-}" ] || return 0
_FOREMAN_CTL_LOADED=1

readonly CTL_DIRNAME=.foreman-run
readonly CTL_GITDIRNAME=foreman-run
readonly CTL_F_BUDGET=budget
readonly CTL_F_LIVE=live
readonly CTL_F_ITERATION=iteration
readonly CTL_F_SCREEN=screen
readonly CTL_F_ACTIVITY=activity
readonly CTL_F_FOOT=foot
readonly CTL_F_SPENT=spent
readonly CTL_F_PID=pid
readonly CTL_F_RUN=run
readonly CTL_F_FEED=feed
readonly CTL_F_STOP=stop
readonly CTL_F_OUT=out
CTL_FILES=("$CTL_F_BUDGET" "$CTL_F_LIVE" "$CTL_F_ITERATION" "$CTL_F_SCREEN" "$CTL_F_ACTIVITY" "$CTL_F_FOOT" \
  "$CTL_F_SPENT" "$CTL_F_PID" "$CTL_F_RUN" "$CTL_F_FEED" "$CTL_F_STOP" "$CTL_F_OUT")

# ctl_rel_dir BATCH_DIR VAR: sets VAR to the repo-relative control directory of a batch (BATCH_DIR is
# repo-relative, `.` for a batch at the repo root).
ctl_rel_dir() {
  if [ "$1" = . ]; then printf -v "$2" '%s' "$CTL_DIRNAME"; else printf -v "$2" '%s' "$1/$CTL_DIRNAME"; fi
}

# ctl_key BATCH_DIR VAR: sets VAR to the batch's repo-relative path as one directory name, the name of
# its control directory under the git directory. Letters, digits, `_`, `-` and anything outside ASCII
# stay; every other ASCII character becomes `%XX` (upper-case hex), `%` included, so it reverses and
# never holds a `/`, a `.` or a character Windows refuses: `.scratch/b` is `%2Escratch%2Fb`, `.` is
# `%2E`. foreman-ctl.cjs keyOf spells it the same. By code, not by class, so no locale changes it.
ctl_key() {
  local s="$1" out="" c n i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    printf -v n '%d' "'$c"
    if [ "$n" -ge 0 ] && [ "$n" -lt 128 ] && ! { [ "$n" -ge 48 ] && [ "$n" -le 57 ]; } &&
       ! { [ "$n" -ge 65 ] && [ "$n" -le 90 ]; } && ! { [ "$n" -ge 97 ] && [ "$n" -le 122 ]; } &&
       [ "$n" -ne 95 ] && [ "$n" -ne 45 ]; then
      printf -v c '%%%02X' "$n"
    fi
    out+="$c"
  done
  printf -v "$2" '%s' "$out"
}

# ctl_dir BATCH_DIR VAR: sets VAR to where the batch's run keeps its control directory, and CTL_WHERE
# to `batch` or `git`. Asked from the repository root (where every caller stands; BATCH_DIR is
# repo-relative). THE one answer, for the loop that makes it and for everything that reads it:
#   - `<batch>/.foreman-run` when the repository ignores it (git check-ignore on its `pid`), as
#     `doctor --fix` leaves a repository: repo-relative.
#   - otherwise `<git-dir>/foreman-run/<key>` (ctl_key): a place git never shows as a change, so a run
#     needs no ignore line to be locked, stopped or watched. `git rev-parse --git-dir` is `.git` in a
#     plain checkout (repo-relative again) and the worktree's own git directory, absolute (`C:/...`
#     from Git for Windows), in a worktree: one control directory per checkout of a batch.
# Fails, with VAR empty, only when git knows no git directory here, which in a repository it always does.
ctl_dir() {
  local rel gd key
  ctl_rel_dir "$1" rel
  if git check-ignore -q -- "$rel/$CTL_F_PID" 2>/dev/null; then
    CTL_WHERE=batch
    printf -v "$2" '%s' "$rel"
    return 0
  fi
  CTL_WHERE=git
  printf -v "$2" '%s' ""
  gd="$(git rev-parse --git-dir 2>/dev/null)" && [ -n "$gd" ] || return 1
  gd="${gd//\\//}"
  ctl_key "$1" key
  printf -v "$2" '%s' "${gd%/}/$CTL_GITDIRNAME/$key"
}

# ctl_full DIR VAR: sets VAR to the path to open for a control directory as ctl_dir gives it: an absolute
# one as it is, a repo-relative one under REPO_ROOT.
ctl_full() {
  case "$1" in
    /*|[A-Za-z]:[\\/]*) printf -v "$2" '%s' "$1" ;;
    *) printf -v "$2" '%s' "$REPO_ROOT/$1" ;;
  esac
}

# ctl_write DIR NAME VALUE: writes VALUE and a newline to DIR/NAME whole, a temp file plus mv, so no
# reader sees half of it.
ctl_write() {
  printf '%s\n' "$3" > "$1/$2.tmp" && mv -f "$1/$2.tmp" "$1/$2"
}

# ctl_clear DIR: removes DIR's files, except `out`; DIR itself when there is no `out`.
ctl_clear() {
  local dir="$1" f keep=0
  local -a victims=()
  [ -d "$dir" ] || return 0
  for f in "$dir"/* "$dir"/.[!.]*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ "${f##*/}" = "$CTL_F_OUT" ]; then keep=1; else victims+=("$f"); fi
  done
  if [ "$keep" -eq 0 ]; then rm -rf "$dir"; elif [ "${#victims[@]}" -gt 0 ]; then rm -rf "${victims[@]}"; fi
}

# ctl_write_pid DIR: records the calling shell as the run in DIR: its pid, and the one Windows knows it
# by (`taskkill` and a Windows program's liveness check want that one; elsewhere the two are the same).
ctl_write_pid() {
  local winpid=""
  read -r winpid 2>/dev/null < "/proc/$$/winpid"
  printf '%s %s\n' "$$" "${winpid:-$$}" > "$1/$CTL_F_PID"
}

# ctl_read_pid DIR: sets CTL_PID_MSYS and CTL_PID_WIN from DIR's pid file; both empty when it is not
# there or is empty.
ctl_read_pid() {
  CTL_PID_MSYS="" CTL_PID_WIN=""
  read -r CTL_PID_MSYS CTL_PID_WIN _ 2>/dev/null < "$1/$CTL_F_PID"
}

# Whether the run a control directory's `pid` file names ("MSYS_PID WINDOWS_PID") is still that run.
# THE one answer, for the loop's start guard, `foreman stop` / `keys` and the `runalive` fact of
# `status --json`: a pid that is merely alive is not enough, because Windows recycles pids and a run
# killed too hard to clean up leaves its file behind. Under MSYS a recycled MSYS pid has a different
# Windows pid (`/proc/<pid>/winpid`), so that must match what the loop recorded. Where there is no
# winpid (Linux, macOS) it is `kill -0`, as it always was.
run_pid_alive() {    # run_pid_alive MSYS_PID WIN_PID
  local msys="${1:-}" win="${2:-}" now=""
  [[ "$msys" =~ ^[0-9]+$ ]] && kill -0 "$msys" 2>/dev/null || return 1
  if [ -n "$win" ] && [ -r "/proc/$msys/winpid" ]; then
    read -r now 2>/dev/null < "/proc/$msys/winpid"
    [ "$now" = "$win" ] || return 1
  fi
  return 0
}

# Ending what a run started, for the loop (end_turn) and `foreman stop --now` (stop_now, stop_force),
# which both walk the MSYS process tree below the run. Under MSYS that tree has a hole: a native
# Windows program (claude.exe, node.exe, cmd.exe: it does not load the MSYS runtime) shows in /proc
# under the MSYS process that started it, but what IT starts — the MSYS bash.exe its Bash tool runs,
# and that bash's own children — are Windows children of it and are not in /proc beneath it. `kill`
# on a native process is TerminateProcess on that one process, so once it is gone those are orphans
# that nothing can reach from the turn any more. The native process's Windows tree has to be taken
# down while it is still there to hang from: `taskkill /T`. That alone is not enough, though: an MSYS
# process's Windows parent is the short-lived process its fork became (the bash's `sleep` is a child of
# a Windows process that is already gone), so `taskkill /T` stops at the MSYS bash it reaches. What
# that bash started is found by its MSYS parent instead, from a /proc snapshot taken before the kill
# (afterwards they are all re-parented to init). Off Windows (no winpid, no taskkill) there is no
# native process, and none of this applies.

# Whether the MSYS pid is a native Windows process: one with a Windows pid, on a host with taskkill,
# that has not loaded the MSYS runtime (the DLL's mapping is what tells an MSYS program apart). A
# process that cannot be read, or has just gone, is not one: it gets the signal it always did.
proc_is_native() {    # proc_is_native PID
  local winpid="" maps=""
  [ -r "/proc/$1/winpid" ] && command -v taskkill >/dev/null 2>&1 || return 1
  read -r winpid 2>/dev/null < "/proc/$1/winpid"
  [[ "$winpid" =~ ^[0-9]+$ ]] || return 1
  IFS= read -r -d '' maps 2>/dev/null < "/proc/$1/maps"
  [ -n "$maps" ] || return 1
  [[ "$maps" != *msys-2.0.dll* && "$maps" != *cygwin1.dll* ]]
}

# Ends PID without its signal handlers: the Windows way where it has a Windows pid (`taskkill /F /T`
# takes the process's Windows tree with it), and `kill -9` as well, which is all there is where it has
# not. A NATIVE process also takes with it what its MSYS children started (see above): the table of
# /proc is read first, `taskkill` says which Windows pids it ended, and everything that was below any
# of those in the table is ended too — native ones with their own trees, MSYS ones with `kill -9`.
proc_kill_tree() {    # proc_kill_tree PID
  local winpid="" out="" line rest a b w p i d grew killed=" "
  local -a pid=() par=() win=() found=()
  read -r winpid 2>/dev/null < "/proc/$1/winpid"
  if [[ "$winpid" =~ ^[0-9]+$ ]] && command -v taskkill >/dev/null 2>&1; then
    if proc_is_native "$1"; then
      for p in /proc/[0-9]*; do
        p="${p#/proc/}"
        read -r line 2>/dev/null < "/proc/$p/stat" || continue
        rest="${line##*) }"
        read -r a b _ <<< "$rest"
        [[ "$b" =~ ^[0-9]+$ ]] || continue
        w=""; read -r w 2>/dev/null < "/proc/$p/winpid"
        pid+=("$p"); par+=("$b"); win+=("$w")
      done
    fi
    out="$(MSYS_NO_PATHCONV=1 taskkill /F /T /PID "$winpid" 2>&1)"
    # One line per process ended, the first number on it that process's own pid, in whatever language.
    while IFS= read -r line; do
      [[ "$line" =~ ([0-9]+) ]] && killed+="${BASH_REMATCH[1]} "
    done <<< "$out"
    for i in "${!pid[@]}"; do
      [ "${pid[$i]}" != "$1" ] && [ -n "${win[$i]}" ] && [[ "$killed" == *" ${win[$i]} "* ]] && found+=("${pid[$i]}")
    done
    grew=1
    while [ "$grew" -eq 1 ] && [ "${#found[@]}" -gt 0 ]; do
      grew=0
      for i in "${!pid[@]}"; do
        [ -n "${pid[$i]}" ] || continue
        for p in "${found[@]}"; do
          if [ "${par[$i]}" = "$p" ]; then found+=("${pid[$i]}"); pid[i]=""; grew=1; break; fi
        done
      done
    done
    for d in ${found[@]+"${found[@]}"}; do
      kill -0 "$d" 2>/dev/null || continue
      if proc_is_native "$d"; then proc_kill_tree "$d"; else kill -9 "$d" 2>/dev/null; fi
    done
  fi
  kill -9 "$1" 2>/dev/null
  return 0
}
