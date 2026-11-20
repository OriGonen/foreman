#!/bin/bash
# The control directory of a run: the one place that says what is in it and how to read and write it.
# Sourced, never run: by foreman-config.sh (so the loop, `foreman stop` / `keys` and the status facts
# have it) and by foreman-keys.sh. Its node twin is foreman-ctl.cjs, which defines the same names for
# foreman-stream.cjs, foreman-json.cjs and the app; test/node/ctl.test.cjs holds the two lists together.
#
# The directory is `<batch>/.foreman-run/` when the repository ignores that name (`**/.foreman-run/`),
# and a temporary one otherwise (foreman-loop.sh); only the first can be reached by `foreman keys` and
# `foreman stop`, from another terminal or the app. The loop removes it when the run ends, except `out`.
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
