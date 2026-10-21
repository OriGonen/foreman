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
# Every run starts from a fresh repository in a temp directory, removed on the way out,
# so nothing carries over from one demo to the next.
FOREMAN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
demo_dir="$(mktemp -d)"
trap 'rm -rf "$demo_dir"' EXIT

# shellcheck source=fixture.sh
. "$FOREMAN_HOME/test/fixture.sh"
build_fixture_template "$demo_dir/template"
copy_fixture "$demo_dir/template" "$demo_dir/repo" "${DEMO_TICKETS:-4}"

[ $# -gt 0 ] || set -- 2 --live
cd "$demo_dir/repo" || exit 1
# `stream` prints a few agent events (a Write, a long Bash command) for the live view, then
# lands the ticket.
FOREMAN_EXEC=fake FOREMAN_FAKE_SLEEP="${DEMO_SLEEP:-8}" FOREMAN_FAKE_BEHAVIOUR=stream \
  "$FOREMAN_HOME/bin/foreman" run batch "$@"
