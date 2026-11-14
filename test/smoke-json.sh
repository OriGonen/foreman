#!/bin/bash
# Tests for the machine-readable side of the CLI (`--json`) and for the app's own logic in gui/.
# Built on test/fixture.sh, like test/smoke.sh, and kept apart from it: test/smoke.sh is not
# edited by the app's tickets, and must keep passing as it is.
#
#   bash test/smoke-json.sh            run everything
#   bash test/smoke-json.sh status     the cases whose name contains "status"
#
# Each case builds its own repository under $TMPDIR (removed on exit), runs foreman on it with
# the `fake` exec adapter — no sandbox, no model, no money — and asserts on what came out. The
# cases run one after another: they are quick, and an order that reads top to bottom is easier
# to follow than a runner.
#
# `node --test` in gui/ (the app's plain-Node logic: bash.cjs, watch.cjs, foreman.cjs,
# model.js) runs as the last case when node is there.
#
# Plain output is "unchanged" is checked against captures in test/golden/, taken on the same
# fixture before the change they guard: status-plain.txt and help.txt. To retake one on purpose:
#   FOREMAN_JSON_GOLDEN=write bash test/smoke-json.sh golden
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOREMAN_HOME="$(cd "$TEST_DIR/.." && pwd)"
FOREMAN="$FOREMAN_HOME/bin/foreman"
FILTER="${1:-}"

# The terminal this is started from must not decide how foreman prints, and nothing here may read
# the operator's credentials or skills (the same guards test/smoke.sh has).
unset COLORTERM WT_SESSION NO_COLOR
_smoke_legacy=$(compgen -v RALPH_)
[ -z "$_smoke_legacy" ] || unset $_smoke_legacy

WORK="$(mktemp -d "${TMPDIR:-/tmp}/foreman-json-XXXXXX")"
export TMPDIR="$WORK"
export FOREMAN_CREDENTIALS_FILE="$WORK/no-such-credentials-file"
export CLAUDE_CONFIG_DIR="$WORK/no-such-claude-config"
cleanup() {
  local try
  for try in 1 2 3; do
    rm -rf "$WORK" 2>/dev/null
    [ -e "$WORK" ] || return 0
    sleep 1
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

passed=0
failed=0
fail() { printf '  FAIL  %s\n' "$*" >&2; failed=$((failed + 1)); }
pass() { passed=$((passed + 1)); }
assert_eq() { if [ "$1" = "$2" ]; then pass; else fail "$3: expected '$2', got '$1'"; fi; }
assert_contains() { case "$1" in *"$2"*) pass ;; *) fail "$3: expected to find '$2'" ;; esac; }
assert_missing() { case "$1" in *"$2"*) fail "$3: did not expect '$2'" ;; *) pass ;; esac; }

case_is() {
  case "$1" in *"$FILTER"*) ;; *) return 1 ;; esac
  printf '\n%s\n' "$1"
  return 0
}

. "$TEST_DIR/fixture.sh"
export FOREMAN_HOME
build_fixture_template "$WORK/template"

# Run foreman in $1 with the rest as arguments. Stdout in $OUT, stderr in $ERR, status in $ST.
# FOREMAN_SHOW=never, as the app runs it: a pipe is never drawn, but nothing here should depend on
# that.
run_foreman() {
  local repo="$1"; shift
  OUT="$(cd "$repo" && FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN" "$@" 2>"$WORK/stderr")"
  ST=$?
  ERR="$(cat "$WORK/stderr")"
}

# One JSON value out of a document: jv DOC 'expression over j'. Prints it as JSON, so `null`,
# strings and numbers stay distinguishable.
jv() {
  printf '%s' "$1" | node -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
      let j; try { j = JSON.parse(s); } catch (e) { console.log("<not json>"); return; }
      let v; try { v = eval(process.argv[1]); } catch (e) { v = "<error: " + e.message + ">"; }
      console.log(JSON.stringify(v));
    });' "$2"
}

# The batch the status cases share, in $1 (a new repository): five tickets in filename order, with
# every shape a status line can have —
#   01  landed, and renamed DONE_ (as the loop does), no blockers
#   02  an agent ticket, blocked by 01             <- next
#   03  a human ticket with a handoff file
#   04  its followup (Checks: 03)
#   05  a ticket whose Checks: names nothing, for a warning
# and the run record the app reads: two iterations on 01 (one before the rename, one after, so the
# `ticket` field has both spellings), one on 02, and a run log whose last run paused.
make_status_repo() {
  local repo="$1" issues
  copy_fixture "$WORK/template" "$repo" 5
  issues="$repo/batch/issues"
  git -C "$repo" mv "$issues/01-ticket.md" "$issues/DONE_01-ticket.md"
  printf '# 01: First thing\n\n**What to build:** the first thing.\n\n**Status:** implemented\n\n**Blocked by:** none\n' \
    > "$issues/DONE_01-ticket.md"
  printf '# 02: Second thing\n\n**Status:** ready-for-agent\n\n**Blocked by:** 01\n' > "$issues/02-ticket.md"
  mkdir -p "$repo/batch/handoff"
  printf 'Fill me in.\n' > "$repo/batch/handoff/03-handoff.md"
  printf '# 03: Try it by hand\n\n**Status:** ready-for-human\n\n**Handoff:** handoff/03-handoff.md\n' \
    > "$issues/03-ticket.md"
  printf '# 04: Followup: check the handoff\n\n**Status:** ready-for-agent\n\n**Checks:** 03-ticket.md\n' \
    > "$issues/04-ticket.md"
  printf '# 05: Last thing\n\n**Status:** ready-for-agent\n\n**Checks:** ghost.md\n' > "$issues/05-ticket.md"
  git -C "$repo" add -A >/dev/null
  git -C "$repo" commit --quiet -m "a batch with every shape of ticket"

  {
    printf '%s\n' '{"run_id":"20261021T091200Z-11","started_at":"2026-10-21T09:12:00Z","iteration":1,"ticket":"batch/issues/01-ticket.md","status_flipped":false,"committed":true,"cost_usd":1.25,"duration_ms":600000}'
    printf '%s\n' '{"run_id":"20261021T091200Z-11","started_at":"2026-10-21T09:30:00Z","iteration":2,"ticket":"batch/issues/DONE_01-ticket.md","status_flipped":true,"committed":true,"cost_usd":0.5,"duration_ms":300000}'
    printf '%s\n' '{"run_id":"20261022T101000Z-22","started_at":"2026-10-22T10:10:00Z","iteration":1,"ticket":"batch/issues/02-ticket.md","status_flipped":false,"committed":true,"cost_usd":0.25,"duration_ms":120000}'
    printf 'this line is not a record\n'
  } > "$repo/batch/foreman-runs.jsonl"
  cat > "$repo/batch/foreman-runs.log" <<'EOF'

#############################################################################
# run 20261021T091200Z-11 started 2026-10-21T09:12:00Z
#############################################################################

# ---- run 20261021T091200Z-11 finished 2026-10-21T09:40:00Z ----
# complete
#############################################################################

#############################################################################
# run 20261022T101000Z-22 started 2026-10-22T10:10:00Z
#############################################################################

# ---- run 20261022T101000Z-22 finished 2026-10-22T10:12:00Z ----
# paused: iteration budget reached
# next up: batch/issues/02-ticket.md
#############################################################################
EOF
}

# ---------------------------------------------------------------------------
# Plain output is unchanged
# ---------------------------------------------------------------------------

if case_is "golden: plain status and help are byte for byte what they were"; then
  repo="$WORK/golden-repo"
  make_status_repo "$repo"
  (cd "$repo" && FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN" status batch > "$WORK/status.out" 2>&1)
  assert_eq "$?" 0 "status exits 0"
  (cd "$repo" && "$FOREMAN" help > "$WORK/help.raw" 2>&1 < /dev/null)
  # The one thing in `help` that depends on where this checkout is: the README path. The capture
  # keeps it as @FOREMAN_HOME@, so it holds on any machine.
  sed "s|$FOREMAN_HOME|@FOREMAN_HOME@|g" "$WORK/help.raw" > "$WORK/help.out"
  if [ "${FOREMAN_JSON_GOLDEN:-}" = write ]; then
    cp "$WORK/status.out" "$TEST_DIR/golden/status-plain.txt"
    cp "$WORK/help.out" "$TEST_DIR/golden/help.txt"
    printf '  retook test/golden/status-plain.txt and help.txt\n'
  fi
  # cmp, not a string compare: a command substitution would drop trailing newlines.
  cmp -s "$WORK/status.out" "$TEST_DIR/golden/status-plain.txt" && pass || fail "plain status differs from test/golden/status-plain.txt"
  cmp -s "$WORK/help.out" "$TEST_DIR/golden/help.txt" && pass || fail "foreman help differs from test/golden/help.txt"
fi

if case_is "plain status starts no node; --json starts it once"; then
  # A shim `node` ahead of the real one on PATH logs every start. Plain status on a pipe starts
  # none (the picture is only drawn at a terminal), and that must stay so; the JSON path is the
  # only one allowed to start one.
  repo="$WORK/spawn-repo"
  make_status_repo "$repo"
  mkdir -p "$WORK/shim"
  real_node="$(command -v node)"
  cat > "$WORK/shim/node" <<EOF
#!/bin/bash
echo "\$1" >> "$WORK/node-calls"
exec "$real_node" "\$@"
EOF
  chmod +x "$WORK/shim/node"
  : > "$WORK/node-calls"
  (cd "$repo" && PATH="$WORK/shim:$PATH" FOREMAN_SHOW=never "$FOREMAN" status batch >/dev/null 2>&1)
  assert_eq "$(grep -c . "$WORK/node-calls")" 0 "plain status started no node"
  (cd "$repo" && PATH="$WORK/shim:$PATH" FOREMAN_SHOW=never "$FOREMAN" status batch --json >/dev/null 2>&1)
  assert_eq "$(grep -c . "$WORK/node-calls")" 1 "status --json started node once"
fi

# ---------------------------------------------------------------------------
# foreman status --json
# ---------------------------------------------------------------------------

if case_is "status --json: one object, versioned, naming its command"; then
  repo="$WORK/json-repo"
  make_status_repo "$repo"
  run_foreman "$repo" status batch --json
  assert_eq "$ST" 0 "exits 0"
  assert_eq "$ERR" "" "says nothing on stderr"
  assert_eq "$(jv "$OUT" 'typeof j')" '"object"' "it parses, and is one object"
  assert_eq "$(jv "$OUT" 'j.foreman_json')" 1 "foreman_json is 1"
  assert_eq "$(jv "$OUT" 'j.command')" '"status"' "it names its command"
  assert_eq "$(printf '%s\n' "$OUT" | grep -c .)" 1 "on one line, so a reader can take it whole"
  assert_eq "$(jv "$OUT" 'j.batch.path')" '"batch"' "the batch path is repo-relative"
  assert_eq "$(jv "$OUT" 'j.batch.name')" '"batch"' "and has its name"
  # The root is where the app runs foreman from; in mixed form, so it has no backslash.
  assert_eq "$(jv "$OUT" '/\\/.test(j.repo_root)')" false "the repo root has no backslash"
  assert_eq "$(jv "$OUT" 'j.repo_root.length > 0')" true "the repo root is given"
fi

if case_is "status --json: the counts, the next ticket and the human tickets are the plain output's"; then
  repo="$WORK/json-facts-repo"
  make_status_repo "$repo"
  run_foreman "$repo" status batch
  plain="$OUT"
  run_foreman "$repo" status batch --json
  json="$OUT"
  assert_contains "$plain" "Tickets done: 1 / 5" "the plain counts, to compare with"
  assert_eq "$(jv "$json" 'j.counts.done')" 1 "done matches"
  assert_eq "$(jv "$json" 'j.counts.total')" 5 "total matches"
  assert_contains "$plain" "Next: 02-ticket.md" "the plain next, to compare with"
  assert_eq "$(jv "$json" 'j.next.file')" '"batch/issues/02-ticket.md"' "next matches, repo-relative"
  assert_eq "$(jv "$json" 'j.next.human')" false "and is not a human ticket"
  assert_contains "$plain" "human tickets remaining: 1" "the plain human count, to compare with"
  assert_eq "$(jv "$json" 'j.human_remaining')" 1 "human tickets match"
  assert_eq "$(jv "$json" 'j.tickets.filter(t => t.human).map(t => t.name)')" '["03-ticket"]' \
    "the human ticket is the one the plain output marks"
  assert_contains "$plain" "  2  03-ticket.md   [HUMAN]" "plain marks 03 human"
  assert_contains "$plain" "  3  04-ticket.md   [CHECKS 03-ticket.md]" "plain marks 04 a followup"
  assert_eq "$(jv "$json" 'j.tickets.find(t => t.number === "04").checks')" '"03-ticket.md"' "JSON carries 04's Checks"
  # The remaining tickets, in the order the plain output lists them.
  plain_names="$(printf '%s\n' "$plain" | sed -n 's/^ *[0-9]*  \([0-9][0-9a-z]*-ticket\.md\).*/\1/p' | tr '\n' ' ')"
  json_names="$(jv "$json" 'j.tickets.filter(t => !t.done).map(t => t.name + ".md").join(" ") + " "' | tr -d '"')"
  assert_eq "$json_names" "$plain_names" "the same remaining tickets in the same order"
  # The words of the run-until note are the CLI's own.
  assert_contains "$plain" "The loop will run 1 ticket(s), then stop at 03-ticket.md for a human." "plain says where it stops"
  assert_eq "$(jv "$json" 'j.run_until.text')" '"The loop will run 1 ticket(s), then stop at 03-ticket.md for a human."' \
    "JSON gives the same sentence"
  assert_eq "$(jv "$json" 'j.run_until.tickets')" 1 "and the number in it"
  assert_eq "$(jv "$json" 'j.run_until.stop')" '"batch/issues/03-ticket.md"' "and where it stops"
  # The warning is the plain output's, without its prefix.
  assert_contains "$plain" "warning: batch/issues/05-ticket.md Checks: ghost.md, which is not a ticket in this batch" \
    "plain warns about 05"
  assert_eq "$(jv "$json" 'j.warnings')" '["batch/issues/05-ticket.md Checks: ghost.md, which is not a ticket in this batch"]' \
    "JSON carries the warning"
fi

if case_is "status --json: each ticket, in order, with its fields"; then
  repo="$WORK/json-tickets-repo"
  make_status_repo "$repo"
  run_foreman "$repo" status batch --json
  json="$OUT"
  assert_eq "$(jv "$json" 'j.tickets.map(t => t.file)')" \
    '["batch/issues/DONE_01-ticket.md","batch/issues/02-ticket.md","batch/issues/03-ticket.md","batch/issues/04-ticket.md","batch/issues/05-ticket.md"]' \
    "files, in order, repo-relative with forward slashes, the DONE_ one under its own name"
  assert_eq "$(jv "$json" 'j.tickets.map(t => t.number)')" '["01","02","03","04","05"]' "numbers"
  assert_eq "$(jv "$json" 'j.tickets.map(t => t.state)')" '["done","next","todo","todo","todo"]' "state words"
  assert_eq "$(jv "$json" 'j.tickets.map(t => t.status)')" \
    '["implemented","ready-for-agent","ready-for-human","ready-for-agent","ready-for-agent"]' "status words"
  assert_eq "$(jv "$json" 'j.tickets.map(t => t.title)')" \
    '["First thing","Second thing","Try it by hand","Followup: check the handoff","Last thing"]' \
    "titles, without the heading's number"
  assert_eq "$(jv "$json" 'j.tickets.map(t => t.done)')" '[true,false,false,false,false]' "done"
  assert_eq "$(jv "$json" 'j.tickets.map(t => t.human)')" '[false,false,true,false,false]' "human"
  assert_eq "$(jv "$json" 'j.tickets.map(t => t.blocked_by)')" '["none","01",null,null,null]' "Blocked by"
  assert_eq "$(jv "$json" 'j.tickets.map(t => t.checks)')" '[null,null,null,"03-ticket.md","ghost.md"]' "Checks"
  assert_eq "$(jv "$json" 'j.tickets.map(t => t.handoff)')" '[null,null,"batch/handoff/03-handoff.md",null,null]' \
    "Handoff, as the path foreman resolves it"
  assert_eq "$(jv "$json" 'j.tickets.map(t => t.name)')" \
    '["01-ticket","02-ticket","03-ticket","04-ticket","05-ticket"]' "names without the DONE_ prefix or .md"
fi

if case_is "status --json: spend per ticket counts both spellings of a renamed ticket"; then
  repo="$WORK/json-spend-repo"
  make_status_repo "$repo"
  run_foreman "$repo" status batch --json
  json="$OUT"
  assert_eq "$(jv "$json" 'j.tickets.map(t => t.spent_usd)')" '[1.75,0.25,null,null,null]' \
    "01 has 1.25 before the rename and 0.5 after; 02 has 0.25; the rest have spent nothing"
  assert_eq "$(jv "$json" 'j.spent_usd')" 2 "the batch's total (a line that is not a record is not counted)"
  assert_eq "$(jv "$json" 'j.runs')" 2 "and how many runs it came from"
  # No record at all is nothing spent, not 0.
  repo2="$WORK/json-nospend-repo"
  make_status_repo "$repo2"
  rm -f "$repo2/batch/foreman-runs.jsonl" "$repo2/batch/foreman-runs.log"
  run_foreman "$repo2" status batch --json
  assert_eq "$(jv "$OUT" 'j.spent_usd')" null "no run log: spent is null"
  assert_eq "$(jv "$OUT" 'j.last_run')" null "and there is no last run"
  assert_eq "$(jv "$OUT" 'j.runs')" 0 "and no runs"
fi

if case_is "status --json: last_run is what the run log's last run says"; then
  repo="$WORK/json-lastrun-repo"
  make_status_repo "$repo"
  run_foreman "$repo" status batch --json
  assert_eq "$(jv "$OUT" 'j.last_run')" \
    '{"id":"20261022T101000Z-22","end":"paused","exit":10,"reason":"iteration budget reached"}' "paused"

  log="$repo/batch/foreman-runs.log"
  endings=(
    "# complete|complete|0|null"
    "# stopped: waiting on a human — batch/issues/03-ticket.md|waiting_on_human|30|\"batch/issues/03-ticket.md\""
    "# stopped: needs a human|needs_human|20|null"
  )
  for e in "${endings[@]}"; do
    IFS='|' read -r line end code reason <<< "$e"
    printf '\n# run 20261023T080000Z-33 started 2026-10-23T08:00:00Z\n# ---- run 20261023T080000Z-33 finished 2026-10-23T08:05:00Z ----\n%s\n' "$line" > "$log"
    run_foreman "$repo" status batch --json
    assert_eq "$(jv "$OUT" 'j.last_run')" \
      "{\"id\":\"20261023T080000Z-33\",\"end\":\"$end\",\"exit\":$code,\"reason\":$reason}" "$end"
  done

  # `# reason:` after a needs-a-human stop is the loop's own words (a later ticket writes it).
  printf '\n# run 20261023T080000Z-33 started 2026-10-23T08:00:00Z\n# ---- run 20261023T080000Z-33 finished 2026-10-23T08:05:00Z ----\n# stopped: needs a human\n# reason: login expired\n' > "$log"
  run_foreman "$repo" status batch --json
  assert_eq "$(jv "$OUT" 'j.last_run.reason')" '"login expired"' "a # reason: line is the reason"

  # A run that started and has not finished (still going, or killed): there is an id, and no end.
  printf '\n# run 20261024T080000Z-44 started 2026-10-24T08:00:00Z\n' >> "$log"
  run_foreman "$repo" status batch --json
  assert_eq "$(jv "$OUT" 'j.last_run')" '{"id":"20261024T080000Z-44","end":null,"exit":null,"reason":null}' \
    "started and not finished"
fi

if case_is "status --json: a batch that is all done, and one with a human ticket next"; then
  repo="$WORK/json-edge-repo"
  make_status_repo "$repo"
  # 02 landed: the human ticket is next, and says where its handoff is.
  sed -i 's/^\*\*Status:\*\* ready-for-agent/**Status:** done/' "$repo/batch/issues/02-ticket.md"
  run_foreman "$repo" status batch --json
  assert_eq "$(jv "$OUT" 'j.next.file')" '"batch/issues/03-ticket.md"' "the human ticket is next"
  assert_eq "$(jv "$OUT" 'j.next.human')" true "and says so"
  assert_eq "$(jv "$OUT" 'j.next.handoff')" '"batch/handoff/03-handoff.md"' "with its handoff"
  assert_eq "$(jv "$OUT" 'j.run_until')" null "nothing to run before it, so no run-until note"
  assert_eq "$(jv "$OUT" 'j.tickets.map(t => t.state)')" '["done","done","next","todo","todo"]' "states follow"

  # And sent back by its followup.
  printf '\n## Sent back by 04-ticket.md\n\nthe handoff is empty\n' >> "$repo/batch/issues/03-ticket.md"
  run_foreman "$repo" status batch --json
  assert_eq "$(jv "$OUT" 'j.next.sent_back_by')" '"04-ticket.md"' "sent back is named, as plain status says"

  # Everything landed.
  sed -i 's/^\*\*Status:\*\* ready-for-[a-z]*/**Status:** done/' "$repo"/batch/issues/0[345]-ticket.md
  run_foreman "$repo" status batch --json
  assert_eq "$ST" 0 "an all-done batch is still a status"
  assert_eq "$(jv "$OUT" 'j.next')" null "nothing is next"
  assert_eq "$(jv "$OUT" 'j.counts')" '{"done":5,"total":5}' "5 of 5"
  assert_eq "$(jv "$OUT" 'j.human_remaining')" 0 "no human ticket left"
fi

if case_is "status --json: a status line other than the default, and a batch name from foreman.conf"; then
  repo="$WORK/json-conf-repo"
  make_status_repo "$repo"
  printf 'FOREMAN_BATCH_NAME="Pretty name"\n' >> "$repo/batch/foreman.conf"
  run_foreman "$repo" status batch --json
  assert_eq "$(jv "$OUT" 'j.batch.name')" '"Pretty name"' "the name foreman.conf gives"
  assert_eq "$(jv "$OUT" 'j.batch.path')" '"batch"' "and the path is still the directory"
fi

if case_is "status --json: a ticket file that vanished mid-read is a ticket without fields, not an error"; then
  # The loop renames a landed ticket to DONE_<name>; a read that races it can find the listed path
  # gone. The listing is foreman's, so the ticket stays; only what is read from its file is empty.
  repo="$WORK/json-vanish-repo"
  make_status_repo "$repo"
  run_foreman "$repo" status batch --json
  assert_eq "$ST" 0 "exits 0"
  # (Simulated at the module's seam: the same facts, a ticket file that is not there.)
  facts="$(printf 'repo\t/x\nbatch\tbatch\nname\tbatch\nstatusline\t**Status:**\ndoneprefix\tDONE_\nrunjsonl\tnone.jsonl\nrunlog\tnone.log\nticket\tnext\tbatch/issues/gone.md\t0\t0\t\t\n')"
  out="$(cd "$repo" && printf '%s' "$facts" | node "$FOREMAN_HOME/lib/foreman-json.cjs" status)"
  assert_eq "$(jv "$out" 'j.tickets[0].title')" null "no title"
  assert_eq "$(jv "$out" 'j.tickets[0].file')" '"batch/issues/gone.md"' "but the file is still listed"
fi

# ---------------------------------------------------------------------------
# foreman status --json --all
# ---------------------------------------------------------------------------

if case_is "status --json --all: every batch in the repo, counts only, finished ones last"; then
  repo="$WORK/json-all-repo"
  make_status_repo "$repo"
  # A second batch with two tickets, one of them done, deeper in the tree...
  mkdir -p "$repo/.scratch/second/issues"
  cp "$repo/batch/foreman.conf" "$repo/.scratch/second/foreman.conf"
  printf '# 01: a\n\n**Status:** implemented\n' > "$repo/.scratch/second/issues/01-a.md"
  printf '# 02: b\n\n**Status:** todo\n' > "$repo/.scratch/second/issues/02-b.md"
  # ...a finished one, renamed as the loop renames it...
  mkdir -p "$repo/.scratch/DONE_old/issues"
  cp "$repo/batch/foreman.conf" "$repo/.scratch/DONE_old/foreman.conf"
  printf '# 01: a\n\n**Status:** implemented\n' > "$repo/.scratch/DONE_old/issues/01-a.md"
  # ...and one whose tickets cannot be listed (an order file that names a ticket that is not there).
  mkdir -p "$repo/.scratch/broken/issues"
  cp "$repo/batch/foreman.conf" "$repo/.scratch/broken/foreman.conf"
  printf '<!-- ORDER:BEGIN -->\nissues/nope.md\n<!-- ORDER:END -->\n' > "$repo/.scratch/broken/order.md"
  git -C "$repo" add -A >/dev/null && git -C "$repo" commit --quiet -m "more batches"

  run_foreman "$repo" status --json --all
  json="$OUT"
  assert_eq "$ST" 0 "exits 0, with no batch named"
  assert_eq "$(jv "$json" 'j.foreman_json')" 1 "versioned"
  assert_eq "$(jv "$json" 'j.command')" '"status"' "names its command"
  assert_eq "$(jv "$json" 'j.all')" true "and says it is the list of every batch"
  assert_eq "$(jv "$json" 'j.batches.map(b => b.path)')" \
    '[".scratch/broken",".scratch/second","batch",".scratch/DONE_old"]' \
    "every batch, sorted, with the finished one last"
  assert_eq "$(jv "$json" 'j.batches.map(b => b.finished)')" '[false,false,false,true]' "which is finished"
  assert_eq "$(jv "$json" 'j.batches.find(b => b.path === "batch").counts')" '{"done":1,"total":5}' "batch: counts"
  assert_eq "$(jv "$json" 'j.batches.find(b => b.path === "batch").human_remaining')" 1 "batch: human tickets"
  assert_eq "$(jv "$json" 'j.batches.find(b => b.path === "batch").next')" '"batch/issues/02-ticket.md"' "batch: next"
  assert_eq "$(jv "$json" 'j.batches.find(b => b.path === ".scratch/second").counts')" '{"done":1,"total":2}' "second: counts"
  assert_eq "$(jv "$json" 'j.batches.find(b => b.path === ".scratch/DONE_old").counts')" '{"done":1,"total":1}' "done batch: counts"
  assert_eq "$(jv "$json" 'j.batches.find(b => b.path === ".scratch/DONE_old").next')" null "done batch: nothing next"
  assert_eq "$(jv "$json" 'j.batches.find(b => b.path === ".scratch/broken").counts')" null "broken: no counts"
  assert_contains "$(jv "$json" 'j.batches.find(b => b.path === ".scratch/broken").error')" "nope.md" \
    "broken: the CLI's own message says why"
  assert_eq "$(jv "$json" 'j.batches.find(b => b.path === "batch").tickets')" undefined "counts only: no ticket list"

  # `--all` and a batch is a mistake, as is `--all` without `--json`.
  run_foreman "$repo" status batch --json --all
  assert_eq "$ST" 1 "--all with a batch is refused"
  assert_contains "$ERR" "Usage:" "with the usage line"
  run_foreman "$repo" status --all
  assert_eq "$ST" 1 "--all without --json is refused"
fi

if case_is "status --json --all: outside a repository"; then
  mkdir -p "$WORK/not-a-repo"
  OUT="$(cd "$WORK/not-a-repo" && GIT_CEILING_DIRECTORIES="$WORK" "$FOREMAN" status --json --all 2>"$WORK/stderr")"
  ST=$?
  assert_eq "$ST" 1 "exits 1"
  assert_eq "$OUT" "" "prints no JSON"
  assert_contains "$(cat "$WORK/stderr")" "not inside a git repository" "and says why, as every command does"
fi

# ---------------------------------------------------------------------------
# Flags that are not status's
# ---------------------------------------------------------------------------

if case_is "--json is for status only, for now: the others still refuse it as they did"; then
  repo="$WORK/json-others-repo"
  make_status_repo "$repo"
  for cmd in run dry-run; do
    run_foreman "$repo" "$cmd" batch --json
    assert_eq "$ST" 1 "$cmd --json is refused"
    assert_contains "$ERR" "Usage:" "$cmd --json says how it is used"
  done
  run_foreman "$repo" status batch --json --bogus
  assert_eq "$ST" 1 "an unknown flag is still refused beside --json"
fi

# ---------------------------------------------------------------------------
# The app's own logic (plain Node, no Electron)
# ---------------------------------------------------------------------------

if case_is "gui: node --test over gui/test/"; then
  if [ ! -d "$FOREMAN_HOME/gui/test" ]; then
    fail "gui/test/ is missing"
  elif command -v node >/dev/null 2>&1; then
    gui_out="$(cd "$FOREMAN_HOME/gui" && node --test 2>&1)"
    gui_st=$?
    assert_eq "$gui_st" 0 "the app's tests pass"
    [ "$gui_st" = 0 ] || printf '%s\n' "$gui_out" | tail -40 >&2
  else
    printf '  (node is not on PATH: skipped)\n'
  fi
fi

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
