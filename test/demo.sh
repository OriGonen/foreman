#!/bin/bash
# Shows `foreman run` on a terminal without an agent, a sandbox or any money: a throwaway
# repository with a batch of tickets, and the fake adapter (lib/exec/fake.sh) in place of
# claude. For trying the status bar, the keys and the live view, and for showing them.
#
#   bash test/demo.sh                 2 iterations, live view on
#   bash test/demo.sh 3               3 iterations, live view off (press L)
#   bash test/demo.sh --unlimited --live
#
# Arguments go to `foreman run batch` as they are; none at all means `2 --live`.
#
#   DEMO_TICKETS   tickets in the batch. Default 4.
#   DEMO_SLEEP     seconds each iteration's "agent" waits before acting. Default 8 — long
#                  enough to press keys while it runs.
#
# THE SHOWS, for a look by eye at what each command draws (README.md, "Terminal output"):
#
#   bash test/demo.sh shows                  every command's show once, each under a caption
#   bash test/demo.sh shows status next      only those, in that order
#
# The commands are help, version, init, status, dry-run, run, order, next, report, convert and
# doctor. They run against a throwaway batch with the fake adapter and a stub `claude` for init
# and order; `convert` on a throwaway ralph project, with its own HOME. Here DEMO_SLEEP is 1
# second, and CI and NO_COLOR are ignored, since the point is to see the show. Where stdout is
# not a terminal the show is forced at 120 columns in 24-bit colour (FOREMAN_SHOW, COLUMNS and
# FOREMAN_COLOR are yours to set), so `bash test/demo.sh shows | less -R` works. Exit status is 0
# if every command was run, whatever each of them said; the intro of `help` plays only on a
# terminal.
#
# Every run starts from a fresh repository in a temp directory, removed on the way out,
# so nothing carries over from one demo to the next.
shows_all="help version init status dry-run run order next report convert doctor"
if [ "${1:-}" = shows ]; then
  shift
  [ $# -gt 0 ] || set -- $shows_all
  for _c in "$@"; do
    case " $shows_all " in
      *" $_c "*) ;;
      *) printf 'demo.sh shows: no command called %s (one of: %s)\n' "$_c" "$shows_all" >&2; exit 2 ;;
    esac
  done
  SHOWS=1
fi
FOREMAN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
demo_dir="$(mktemp -d)"
trap 'rm -rf "$demo_dir"' EXIT

# shellcheck source=fixture.sh
. "$FOREMAN_HOME/test/fixture.sh"
build_fixture_template "$demo_dir/template"
copy_fixture "$demo_dir/template" "$demo_dir/repo" "${DEMO_TICKETS:-4}"

if [ -n "${SHOWS:-}" ]; then
  FOREMAN="$FOREMAN_HOME/bin/foreman"
  # The point is to see the show: CI and NO_COLOR would turn it off, and a pipe has no terminal.
  unset CI NO_COLOR
  if [ ! -t 1 ]; then
    export FOREMAN_SHOW="${FOREMAN_SHOW:-always}" COLUMNS="${COLUMNS:-120}"
    [ -n "${FOREMAN_COLOR:-}" ] || export FOREMAN_COLOR=truecolor
  fi
  export FOREMAN_EXEC=fake FOREMAN_FAKE_SLEEP="${DEMO_SLEEP:-1}"

  # A stub `claude` for init and order: it reads the prompt and says nothing was spent.
  mkdir -p "$demo_dir/stub"
  printf '#!/bin/bash\necho '"'"'{"total_cost_usd":0}'"'"'\n' > "$demo_dir/stub/claude"
  chmod +x "$demo_dir/stub/claude"

  cd "$demo_dir/repo" || exit 1
  # One ticket done, so the sun is already part-way up; the order file lists them all.
  sed -i 's/^\*\*Status:\*\* todo/**Status:** implemented/' batch/issues/01-ticket.md
  { echo '<!-- ORDER:BEGIN -->'; for f in batch/issues/*.md; do echo "$f"; done; echo '<!-- ORDER:END -->'; } > batch/order.md
  git add -A && git commit --quiet -m "demo: one ticket done, an order"
  # A batch for `init` to scaffold: tickets and nothing else.
  mkdir -p new-batch/issues
  printf '# One\n\n**Status:** todo\n\nFirst.\n' > new-batch/issues/01-one.md
  printf '# Two\n\n**Status:** todo\n\nSecond.\n' > new-batch/issues/02-two.md
  # A project that still says ralph, for `convert`, in a home of its own so no real file is read.
  mkdir -p "$demo_dir/ralph/batch" "$demo_dir/ralph/docs" "$demo_dir/home/.config/ralph"
  git -C "$demo_dir/ralph" init --quiet
  git -C "$demo_dir/ralph" config user.name demo; git -C "$demo_dir/ralph" config user.email demo@foreman.invalid
  printf 'RALPH_EXEC=fake\n' > "$demo_dir/ralph/batch/ralph.conf"
  printf '**/ralph-runs.jsonl\n' > "$demo_dir/ralph/.gitignore"
  printf 'Run `ralph run batch`, then read ralph-loop.sh.\nBuilt on the Ralph loop.\n' > "$demo_dir/ralph/docs/guide.md"
  printf 'RALPH_DOCKER_USERNAME=someone\n' > "$demo_dir/home/.config/ralph/env"
  git -C "$demo_dir/ralph" add -A; git -C "$demo_dir/ralph" commit --quiet -m "as ralph left it"

  ran=0
  for cmd in "$@"; do
    # The report reads the run log, which a run leaves; make one first if none has been shown.
    if [ "$cmd" = report ] && [ "$ran" = 0 ]; then "$FOREMAN" run batch 1 >/dev/null 2>&1; ran=1; fi
    case "$cmd" in
      help)    line="help" ;;
      version) line="version" ;;
      init)    line="init new-batch --no-commands" ;;
      status)  line="status batch" ;;
      dry-run) line="dry-run batch" ;;
      run)     line="run batch 1"; ran=1 ;;
      order)   line="order batch" ;;
      next)    line="next batch --all, then --count" ;;
      report)  line="report batch" ;;
      convert) line="convert" ;;
      doctor)  line="doctor" ;;
    esac
    printf '\n── foreman %s ──\n' "$line"
    case "$cmd" in
      init)    PATH="$demo_dir/stub:$PATH" "$FOREMAN" init new-batch --no-commands
               # what it wrote would be a dirty tree, which the commands after it refuse; and it
               # asks for a sandbox, which the doctor would then ask this machine for
               printf 'FOREMAN_EXEC=fake\n' >> new-batch/foreman.conf
               git add -A && git commit --quiet -m "demo: init" ;;
      order)   PATH="$demo_dir/stub:$PATH" "$FOREMAN" order batch ;;
      next)    "$FOREMAN" next batch --all; "$FOREMAN" next batch --count ;;
      convert) (cd "$demo_dir/ralph" && HOME="$demo_dir/home" "$FOREMAN" convert) ;;
      run)     "$FOREMAN" run batch 1 ;;
      *)       "$FOREMAN" ${line} ;;
    esac
  done
  exit 0
fi

[ $# -gt 0 ] || set -- 2 --live
cd "$demo_dir/repo" || exit 1
# `stream` prints a few agent events (a Write, a long Bash command) for the live view, then
# lands the ticket.
FOREMAN_EXEC=fake FOREMAN_FAKE_SLEEP="${DEMO_SLEEP:-8}" FOREMAN_FAKE_BEHAVIOUR=stream \
  "$FOREMAN_HOME/bin/foreman" run batch "$@"
