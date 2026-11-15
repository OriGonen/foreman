#!/bin/bash
# The spike for ticket 09, as a script: how to end a detached run's tree the way Ctrl-C would.
#
#   bash .scratch/gui/notes/09-spike.sh            run every candidate, print one line each
#   bash .scratch/gui/notes/09-spike.sh -v         also say what each process saw
#
# For each candidate it stands up a tree shaped like a run's — a detached bash "loop" that traps INT
# the way foreman-loop.sh does, whose foreground child is a native program (node, as claude and the
# feed are) with a child of its own — started the way the app starts a run (`node -e` with
# `detached`, `windowsHide`, stdin ignored). Then it does the candidate to it and reports, after a
# few seconds: did the loop's INT handler run (`loop-int`), is the loop still alive, is the agent
# (`agent`) and its child (`grandchild`) still alive. The result worth wanting is
# `loop-int=yes loop=exited agent=gone grandchild=gone`.
#
# Written on Linux, where it was run; the Windows column of 09-stop-now.md is for whoever runs it in
# Git Bash. It uses /proc (MSYS has it) and `tasklist` where there is one.
set -uo pipefail
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
TAG="spike$$"

# The loop: INT sets a flag and writes loop-int, as on_interrupt does, and the loop waits for its
# agent before it looks at the flag — a bash that has a trap set runs it only when the foreground
# child is done. It also looks for the `stop` file once the agent is gone (check_stop_file).
cat > "$W/loop.sh" <<'LOOP'
#!/bin/bash
dir="$1"
trap 'echo "$(date +%T) INT" >> "$dir/loop-int"; PAUSE=1' INT TERM
printf '%s %s\n' "$$" "$(cat /proc/$$/winpid 2>/dev/null || echo $$)" > "$dir/pid"
# agent: a native program with a child of its own that is also native
node -e 'const {spawn}=require("child_process"); const c=spawn(process.execPath,["-e","setInterval(()=>{},1000)","'"$2"'-grandchild"],{stdio:"ignore"});
  require("fs").writeFileSync(process.argv[1]+"/agent",process.pid+" "+c.pid); setInterval(()=>{},1000)' "$dir" "$2-agent"
echo "agent returned $?" >> "$dir/loop-log"
[ -e "$dir/stop" ] && echo "stop file seen" >> "$dir/loop-log"
echo "loop done" >> "$dir/loop-log"
LOOP

# What the app does: detached, no console, stdin ignored.
start() {    # start DIR
  mkdir -p "$1"
  node -e 'const {spawn}=require("child_process");
    const p=spawn("bash",[process.argv[1],process.argv[2],process.argv[3]],{detached:true,windowsHide:true,stdio:["ignore","ignore","ignore"]}); p.unref()' \
    "$W/loop.sh" "$1" "$TAG"
  for _ in $(seq 1 50); do [ -s "$1/agent" ] && [ -s "$1/pid" ] && return 0; sleep 0.2; done
  echo "the stand-in tree did not start" >&2; return 1
}
alive() { kill -0 "$1" 2>/dev/null; }
# Windows pids need tasklist; elsewhere kill -0 on the pid is it.
walive() {
  if command -v tasklist >/dev/null 2>&1; then tasklist //FI "PID eq $1" 2>/dev/null | grep -q "$1"; else alive "$1"; fi
}
report() {    # report NAME DIR
  local d="$2" lp lw ap gp int=no loop=exited agent=gone grand=gone
  read -r lp lw < "$d/pid"; read -r ap gp < "$d/agent"
  [ -s "$d/loop-int" ] && int=yes
  walive "$lw" && loop=ALIVE
  walive "$ap" && agent=ALIVE
  walive "$gp" && grand=ALIVE
  printf '%-34s loop-int=%-3s loop=%-6s agent=%-5s grandchild=%s\n' "$1" "$int" "$loop" "$agent" "$grand"
  [ "$VERBOSE" -eq 0 ] || { [ -f "$d/loop-log" ] && sed 's/^/    loop: /' "$d/loop-log"; }
  # whatever is left, so the next candidate starts clean
  walive "$ap" && kill -9 "$ap" 2>/dev/null; walive "$gp" && kill -9 "$gp" 2>/dev/null
  walive "$lw" && kill -9 "$lp" 2>/dev/null
  true
}
descendants() {    # pids below $1 from /proc
  local root="$1" p l r a b; local -a all=() par=() found=("$root")
  for p in /proc/[0-9]*; do p="${p#/proc/}"; read -r l 2>/dev/null < "/proc/$p/stat" || continue; r="${l##*) }"; read -r a b _ <<< "$r"; all+=("$p"); par+=("$b"); done
  local grew=1 i q
  while [ "$grew" = 1 ]; do grew=0
    for i in "${!all[@]}"; do [ -n "${all[$i]}" ] || continue
      for q in "${found[@]}"; do [ "${par[$i]}" = "$q" ] && { found+=("${all[$i]}"); echo "${all[$i]}"; all[i]=""; grew=1; break; }; done
    done
  done
}

try() {    # try NAME 'commands using $d $lp $lw $ap $gp'
  local name="$1" body="$2" d="$W/$1" lp lw ap gp
  start "$d" || return
  read -r lp lw < "$d/pid"; read -r ap gp < "$d/agent"
  eval "$body"
  sleep 4
  report "$name" "$d"
}

try A-kill-INT-loop        'kill -INT "$lp"'
try B-kill-INT-all-below   'kill -INT "$lp"; for p in $(descendants "$lp"); do kill -INT "$p"; done'
try C-stop-file-only       ': > "$d/stop"'
try D-kill-f-INT-agent     'kill -f -INT "$ap" 2>/dev/null || kill -INT "$ap"'
try E-taskkill-agent-tree  'MSYS_NO_PATHCONV=1 taskkill /F /T /PID "$ap" >/dev/null 2>&1 || kill -9 "$ap"'
try F-taskkill-loop-tree   'MSYS_NO_PATHCONV=1 taskkill /F /T /PID "$lw" >/dev/null 2>&1 || kill -9 "$lp"'
try G-chosen               ': > "$d/stop"; kill -INT "$lp"; for p in $(descendants "$lp"); do kill -INT "$p"; done; sleep 5; for p in $(descendants "$lp"); do MSYS_NO_PATHCONV=1 taskkill /F /T /PID "$p" >/dev/null 2>&1; kill -9 "$p" 2>/dev/null; done'
