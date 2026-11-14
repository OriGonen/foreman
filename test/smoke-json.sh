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
# fixture before the change they guard: status-plain.txt, help.txt, dry-run-plain.txt and doctor-*.txt. To retake one on purpose:
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

if case_is "golden: plain dry-run is byte for byte what it was"; then
  repo="$WORK/golden-dry-repo"
  make_status_repo "$repo"
  (cd "$repo" && FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN" dry-run batch > "$WORK/dry.raw" 2>&1)
  assert_eq "$?" 0 "dry-run exits 0"
  # What differs from one fixture to the next: the commit the prompt names as its base, and where
  # the temporary repository is. The capture keeps both as placeholders.
  sed -e "s|$WORK|@WORK@|g" -e 's/[0-9a-f]\{40\}/@SHA@/g' "$WORK/dry.raw" > "$WORK/dry.out"
  if [ "${FOREMAN_JSON_GOLDEN:-}" = write ]; then
    cp "$WORK/dry.out" "$TEST_DIR/golden/dry-run-plain.txt"
    printf '  retook test/golden/dry-run-plain.txt\n'
  fi
  cmp -s "$WORK/dry.out" "$TEST_DIR/golden/dry-run-plain.txt" && pass || fail "plain dry-run differs from test/golden/dry-run-plain.txt"
fi

# `foreman doctor`, plain, in the three states a person meets it in: ready; with things it can write
# (three ignore lines missing, and a repo that rewrites line endings with no .gitattributes line);
# and `--fix`, which draws the same box, writes, and says so. The captures in test/golden/doctor-*.txt
# were taken on the tree before `--json` was added. What a machine or a day decides is a placeholder:
# the title line (the place, the date, the build) and the bash version's own padding.
doctor_golden_repo() {    # doctor_golden_repo REPO ready|fixable
  local repo="$1" state="$2"
  copy_fixture "$WORK/template" "$repo" 2
  if [ "$state" = fixable ]; then
    printf '**/foreman-runs.jsonl\n' > "$repo/.gitignore"
    printf '* text=auto\n' > "$repo/.gitattributes"
    git -C "$repo" add -A >/dev/null
    git -C "$repo" commit --quiet -m "a repo that needs doctor --fix"
  fi
}
doctor_golden_run() {    # doctor_golden_run REPO [args] -> the output, normalised, in $WORK/doctor.out
  local repo="$1"; shift
  mkdir -p "$WORK/doctor-home"
  (cd "$repo" && HOME="$WORK/doctor-home" FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN" doctor "$@" 2>&1; echo "exit $?") |
    sed -e "s|$WORK|@WORK@|g" -e 's/^\(║  SITE INSPECTION\).*/\1 @TITLE@/' \
        -e 's/bash [0-9][0-9.]* (4+ required) *│/bash @V@ (4+ required)│/' > "$WORK/doctor.out"
}

if case_is "golden: plain doctor and doctor --fix are byte for byte what they were"; then
  doctor_golden_repo "$WORK/golden-doctor-ready" ready
  doctor_golden_run "$WORK/golden-doctor-ready"
  cp "$WORK/doctor.out" "$WORK/doctor-ready.out"
  doctor_golden_repo "$WORK/golden-doctor-fixable" fixable
  doctor_golden_run "$WORK/golden-doctor-fixable"
  cp "$WORK/doctor.out" "$WORK/doctor-fixable.out"
  doctor_golden_repo "$WORK/golden-doctor-fix" fixable
  doctor_golden_run "$WORK/golden-doctor-fix" --fix
  { cat "$WORK/doctor.out"; echo '--- .gitignore'; cat "$WORK/golden-doctor-fix/.gitignore"
    echo '--- .gitattributes'; cat "$WORK/golden-doctor-fix/.gitattributes"; } > "$WORK/doctor-fix.out"
  if [ "${FOREMAN_JSON_GOLDEN:-}" = write ]; then
    cp "$WORK/doctor-ready.out" "$TEST_DIR/golden/doctor-ready.txt"
    cp "$WORK/doctor-fixable.out" "$TEST_DIR/golden/doctor-fixable.txt"
    cp "$WORK/doctor-fix.out" "$TEST_DIR/golden/doctor-fix.txt"
    printf '  retook test/golden/doctor-ready.txt, doctor-fixable.txt and doctor-fix.txt\n'
  fi
  cmp -s "$WORK/doctor-ready.out" "$TEST_DIR/golden/doctor-ready.txt" && pass || fail "plain doctor (ready) differs from test/golden/doctor-ready.txt"
  cmp -s "$WORK/doctor-fixable.out" "$TEST_DIR/golden/doctor-fixable.txt" && pass || fail "plain doctor (fixable) differs from test/golden/doctor-fixable.txt"
  cmp -s "$WORK/doctor-fix.out" "$TEST_DIR/golden/doctor-fix.txt" && pass || fail "doctor --fix differs from test/golden/doctor-fix.txt"
fi

# A run on the fake exec, in two shapes (a ticket that took two iterations and then another ticket;
# a stalled one that a checkpoint turn salvages), is what it was: what it printed, and the lines it
# recorded, whose only change is `model`. The captures in test/golden/run-fake-*.txt were taken on the
# tree before the model was recorded; `model` is taken off the lines before they are compared.
fake_run_capture() {    # fake_run_capture BEHAVIOURS PREFIX : the run's output and its record, normalised, in $WORK/PREFIX.{out,jsonl}
  local beh="$1" prefix="$2" repo="$WORK/$2-repo"
  copy_fixture "$WORK/template" "$repo" 3
  (cd "$repo" && FOREMAN_FAKE_BEHAVIOUR="$beh" FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN" run batch 3 > "$WORK/$prefix.raw" 2>&1)
  # The fake exec leaves a call counter in $TMPDIR; a later case counts those to see that a dry run
  # never called it, so a case that runs for real takes its own away.
  rm -f "$WORK"/foreman-fake-*.calls
  # What differs from one run to the next: the run's id and clock, the commits' ids, where the
  # temporary repository is.
  sed -E -e "s|$WORK|@WORK@|g" -e 's/[0-9]{8}T[0-9]{6}Z-[0-9]+/@RUN@/g' -e 's/[0-9]+\.[0-9]s/@S@/g' \
    -e 's/(·  )[0-9a-f]{7,40}$/\1@SHA@/' "$WORK/$prefix.raw" > "$WORK/$prefix.out"
  sed -E -e 's/"model":"[^"]*",//' -e 's/[0-9]{8}T[0-9]{6}Z-[0-9]+/@RUN@/g' \
    -e 's/20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z/@T@/g' -e 's/[0-9a-f]{40}/@SHA@/g' \
    -e 's/"duration_ms":[0-9]+/"duration_ms":N/' -e 's/"duration_api_ms":[0-9]+/"duration_api_ms":N/' \
    "$repo/batch/foreman-runs.jsonl" > "$WORK/$prefix.jsonl"
}

if case_is "golden: a run on the fake exec prints and records what it did, plus model"; then
  fake_run_capture "partial-turn:land" run-partial
  fake_run_capture "dirty:land" run-dirty
  if [ "${FOREMAN_JSON_GOLDEN:-}" = write ]; then
    cp "$WORK/run-partial.out" "$TEST_DIR/golden/run-fake-partial.txt"
    cp "$WORK/run-partial.jsonl" "$TEST_DIR/golden/run-fake-partial.jsonl"
    cp "$WORK/run-dirty.out" "$TEST_DIR/golden/run-fake-dirty.txt"
    cp "$WORK/run-dirty.jsonl" "$TEST_DIR/golden/run-fake-dirty.jsonl"
    printf '  retook test/golden/run-fake-*\n'
  fi
  for shape in partial dirty; do
    cmp -s "$WORK/run-$shape.out" "$TEST_DIR/golden/run-fake-$shape.txt" && pass || fail "run ($shape) output differs from test/golden/run-fake-$shape.txt"
    cmp -s "$WORK/run-$shape.jsonl" "$TEST_DIR/golden/run-fake-$shape.jsonl" && pass || fail "run ($shape) record, without model, differs from test/golden/run-fake-$shape.jsonl"
  done
  # And with model, the record has it on every line (the checkpoint turn's included).
  assert_eq "$(grep -c '"model":"claude-sonnet-5-5"' "$WORK/run-dirty-repo/batch/foreman-runs.jsonl")" 4 "every line of the stalled run has the model, the checkpoint's too"
  assert_contains "$(cat "$WORK/run-dirty-repo/batch/foreman-runs.jsonl")" '"kind":"checkpoint"' "(and it has a checkpoint row)"
fi

if case_is "plain status and dry-run start no node; --json starts it once"; then
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
  # The same for a dry run: nothing new on the plain path, one node on the JSON path.
  : > "$WORK/node-calls"
  (cd "$repo" && PATH="$WORK/shim:$PATH" FOREMAN_SHOW=never "$FOREMAN" dry-run batch >/dev/null 2>&1)
  assert_eq "$(grep -c . "$WORK/node-calls")" 0 "plain dry-run started no node"
  (cd "$repo" && PATH="$WORK/shim:$PATH" FOREMAN_SHOW=never "$FOREMAN" dry-run batch --json >/dev/null 2>&1)
  assert_eq "$(grep -c . "$WORK/node-calls")" 1 "dry-run --json started node once"
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
# foreman dry-run --json
# ---------------------------------------------------------------------------

# The lines the plain dry-run prints between its two marker lines: the prompt, exactly.
plain_prompt() {    # plain_prompt PLAIN_OUTPUT
  printf '%s\n' "$1" | awk '/^=== end prompt/ { on = 0 } on { print } /^=== prompt that would be sent/ { on = 1 }'
}

if case_is "dry-run --json: one object, versioned, naming its command"; then
  repo="$WORK/dry-shape-repo"
  make_status_repo "$repo"
  run_foreman "$repo" dry-run batch --json
  assert_eq "$ST" 0 "exits 0"
  assert_eq "$ERR" "" "says nothing on stderr"
  assert_eq "$(jv "$OUT" 'typeof j')" '"object"' "it parses, and is one object"
  assert_eq "$(jv "$OUT" 'j.foreman_json')" 1 "foreman_json is 1"
  assert_eq "$(jv "$OUT" 'j.command')" '"dry-run"' "it names its command"
  assert_eq "$(printf '%s\n' "$OUT" | grep -c .)" 1 "on one line, so a reader can take it whole"
  assert_eq "$(jv "$OUT" 'j.batch')" '{"path":"batch","name":"batch"}' "the batch"
  assert_eq "$(jv "$OUT" 'j.counts')" '{"done":1,"total":5}' "the counts"
  assert_eq "$(jv "$OUT" 'j.repo_root.length > 0')" true "the repo root is given"
  assert_eq "$(jv "$OUT" 'Object.keys(j).join()')" \
    '"foreman_json,command,repo_root,batch,counts,would_run,settings,warnings,prompt"' "the keys, in this order"
fi

if case_is "dry-run --json: its facts are the plain dry-run's"; then
  repo="$WORK/dry-facts-repo"
  make_status_repo "$repo"
  run_foreman "$repo" dry-run batch
  plain="$OUT"
  run_foreman "$repo" dry-run batch --json
  json="$OUT"
  # What would run: the one ticket the default budget of one iteration reaches. The plain output
  # marks the human ticket after it, and the json says the budget does not get that far.
  assert_contains "$plain" "  1  02-ticket.md" "plain: the first ticket to run, to compare with"
  assert_eq "$(jv "$json" 'j.would_run.tickets.map(t => t.file)')" '["batch/issues/02-ticket.md"]' "the one ticket the budget reaches"
  assert_eq "$(jv "$json" 'j.would_run.tickets[0].title')" '"Second thing"' "with its title"
  assert_eq "$(jv "$json" 'j.would_run.remaining.map(t => t.name + ":" + t.state)')" \
    '["02-ticket:run","03-ticket:stop","04-ticket:later","05-ticket:later"]' "the four still to do, in the order the plain output lists them, with what a run does with each"
  assert_contains "$plain" "  2  03-ticket.md   [HUMAN]" "plain marks 03 human"
  assert_eq "$(jv "$json" 'j.would_run.stops_at.file')" '"batch/issues/03-ticket.md"' "JSON names the human ticket"
  assert_eq "$(jv "$json" 'j.would_run.stops_at.handoff')" '"batch/handoff/03-handoff.md"' "and its handoff"
  assert_eq "$(jv "$json" 'j.would_run.stops_at.reached')" false "one iteration does not get that far"
  # The settings, line by line as the plain output prints them.
  assert_contains "$plain" "Exec:    fake (no agent is run)" "plain: exec"
  assert_eq "$(jv "$json" 'j.settings.exec')" '"fake (no agent is run)"' "exec matches"
  assert_contains "$plain" "Model:   claude-sonnet-5-5   Effort: high" "plain: model and effort"
  assert_eq "$(jv "$json" '[j.settings.model, j.settings.effort]')" '["claude-sonnet-5-5","high"]' "model and effort match"
  assert_contains "$plain" "Perms:   acceptEdits" "plain: perms"
  assert_eq "$(jv "$json" 'j.settings.perms')" '"acceptEdits"' "perms match"
  assert_contains "$plain" "Live:    off" "plain: live"
  assert_eq "$(jv "$json" 'j.settings.live')" false "live matches"
  assert_contains "$plain" "Budgets: cost=unlimited  time=unlimited  iterations=1" "plain: budgets"
  assert_eq "$(jv "$json" 'j.settings.budgets')" '{"cost_usd":null,"minutes":null,"iterations":1,"text":"cost=unlimited  time=unlimited  iterations=1"}' \
    "budgets match: no limit is null, and the plain words are carried"
  assert_contains "$plain" "Logs:    batch/foreman-runs.jsonl" "plain: the run record"
  assert_eq "$(jv "$json" 'j.settings.logs')" '{"jsonl":"batch/foreman-runs.jsonl","log":"batch/foreman-runs.log"}' "logs match"
  assert_contains "$plain" "warning: batch/issues/05-ticket.md Checks: ghost.md, which is not a ticket in this batch" "plain warns about 05"
  assert_eq "$(jv "$json" 'j.warnings')" '["batch/issues/05-ticket.md Checks: ghost.md, which is not a ticket in this batch"]' "JSON carries the warning"
  assert_contains "$plain" "=== prompt that would be sent for batch/issues/02-ticket.md ===" "plain: which ticket the prompt is for"
  assert_eq "$(jv "$json" 'j.prompt.for')" '"batch/issues/02-ticket.md"' "the prompt is for the same ticket"
fi

if case_is "dry-run --json: the prompt is exactly the plain output's"; then
  repo="$WORK/dry-prompt-repo"
  make_status_repo "$repo"
  run_foreman "$repo" dry-run batch
  plain="$OUT"
  run_foreman "$repo" dry-run batch --json
  # Compared as files: a command substitution would drop trailing newlines, and what is held here is
  # that nothing is lost, blank lines included.
  plain_prompt "$plain" > "$WORK/prompt.plain"
  printf '%s' "$OUT" | node -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
      const p = JSON.parse(s).prompt; process.stdout.write(p.text + "\n");
      require("fs").writeFileSync(process.argv[1], String(p.lines));
    });' "$WORK/prompt.lines" > "$WORK/prompt.json"
  cmp -s "$WORK/prompt.plain" "$WORK/prompt.json" && pass || fail "the JSON prompt differs from the plain output between its markers"
  assert_eq "$(cat "$WORK/prompt.lines")" "$(grep -c '' "$WORK/prompt.plain")" "lines is how many lines the plain output shows"
  assert_contains "$(head -1 "$WORK/prompt.json")" "@batch/issues/02-ticket.md" "it starts with the attached ticket"
  assert_contains "$(cat "$WORK/prompt.json")" "Commit everything to the current branch" "and has the adapter's commit note"
fi

if case_is "dry-run --json: the prompt survives backslashes, tabs, carriage returns and blank lines"; then
  # The loop writes the prompt as one line; the module puts it back. Both ends, at the seam: the
  # module on facts written by hand, then the whole CLI on a progress file full of awkward text
  # (the progress excerpt is the one part of the prompt that is the user's own).
  # `a`, a backslash and an n, `b`, a newline, `c`, a tab, `z`, a backslash: written as the loop writes it.
  out="$(cd "$WORK" && printf 'batch\tb\nticket\trun\tb/issues/x.md\t0\t0\t\t\npromptfor\tb/issues/x.md\nprompt\t%s\n' \
    'a\\nb\nc\tz\\' | node "$FOREMAN_HOME/lib/foreman-json.cjs" dry-run)"
  assert_eq "$(jv "$out" 'j.prompt.text')" '"a\\nb\nc\tz\\"' "the escapes are undone in one pass, so a backslash then n stays two characters"
  assert_eq "$(jv "$out" 'j.prompt.lines')" 2 "and the lines are counted as the plain output prints them"


  repo="$WORK/dry-awkward-repo"
  make_status_repo "$repo"
  printf 'one\ttab\r\n\\n is not a newline\n\n\nlast\n' > "$repo/batch/progress.txt"
  git -C "$repo" add -A >/dev/null && git -C "$repo" commit --quiet -m "a progress file with awkward text"
  run_foreman "$repo" dry-run batch
  plain="$OUT"
  run_foreman "$repo" dry-run batch --json
  plain_prompt "$plain" > "$WORK/awkward.plain"
  printf '%s' "$OUT" | node -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => process.stdout.write(JSON.parse(s).prompt.text + "\n"));' > "$WORK/awkward.json"
  assert_contains "$(cat "$WORK/awkward.plain")" "is not a newline" "the awkward text is in the plain prompt"
  cmp -s "$WORK/awkward.plain" "$WORK/awkward.json" && pass || fail "the awkward prompt is not what the plain output prints"
fi

if case_is "dry-run --json: the iteration budget decides how far it reaches, and a human ticket ends it"; then
  repo="$WORK/dry-reach-repo"
  make_status_repo "$repo"
  # Unlimited: 02 runs, then the loop stops at 03, the human ticket, and 04 and 05 wait behind it.
  run_foreman "$repo" dry-run batch --unlimited --json
  assert_eq "$ST" 0 "exits 0"
  assert_eq "$(jv "$OUT" 'j.would_run.tickets.map(t => t.name)')" '["02-ticket"]' "only 02 comes before the human ticket"
  assert_eq "$(jv "$OUT" 'j.would_run.stops_at.name')" '"03-ticket"' "and the run stops at 03"
  assert_eq "$(jv "$OUT" 'j.would_run.stops_at.reached')" true "which it reaches"
  assert_eq "$(jv "$OUT" 'j.settings.budgets.iterations')" null "unlimited is null"
  assert_contains "$(jv "$OUT" 'j.settings.budgets.text')" "iterations=unlimited" "in the plain words"
  # Two iterations: still one ticket before the human one, and now there is a spare to reach it.
  run_foreman "$repo" dry-run batch 2 --json
  assert_eq "$(jv "$OUT" 'j.would_run.stops_at.reached')" true "two iterations reach the human ticket"
  assert_eq "$(jv "$OUT" 'j.settings.budgets.iterations')" 2 "and say two"
  # With the human ticket landed, the budget is what ends the run.
  sed -i 's/^\*\*Status:\*\* ready-for-human/**Status:** done/' "$repo/batch/issues/03-ticket.md"
  git -C "$repo" commit --quiet -am "03 landed"
  run_foreman "$repo" dry-run batch 2 --json
  assert_eq "$(jv "$OUT" 'j.would_run.tickets.map(t => t.name)')" '["02-ticket","04-ticket"]' "two iterations take two tickets"
  assert_eq "$(jv "$OUT" 'j.would_run.remaining.map(t => t.name + ":" + t.state)')" '["02-ticket:run","04-ticket:run","05-ticket:later"]' "of the three still to do (03 has landed), the third waits"
  assert_eq "$(jv "$OUT" 'j.would_run.stops_at')" null "no human ticket is left to stop at"
  run_foreman "$repo" dry-run batch --unlimited --json
  assert_eq "$(jv "$OUT" 'j.would_run.tickets.map(t => t.name)')" '["02-ticket","04-ticket","05-ticket"]' "unlimited takes them all"
  assert_eq "$(jv "$OUT" 'j.would_run.tickets.find(t => t.number === "04").checks')" '"03-ticket.md"' "a followup says what it checks"
fi

if case_is "dry-run --json: the cost and time budgets, live and a setting from foreman.conf"; then
  repo="$WORK/dry-settings-repo"
  make_status_repo "$repo"
  printf 'FOREMAN_MAX_COST_USD=25\nFOREMAN_MAX_MINUTES=90\nFOREMAN_EFFORT=low\nFOREMAN_BATCH_NAME="Pretty name"\n' >> "$repo/batch/foreman.conf"
  git -C "$repo" commit --quiet -am "budgets"
  run_foreman "$repo" dry-run batch --live
  plain="$OUT"
  run_foreman "$repo" dry-run batch --live --json
  assert_contains "$plain" "Budgets: cost=\$25  time=90m  iterations=1" "plain: the budgets"
  assert_eq "$(jv "$OUT" 'j.settings.budgets')" '{"cost_usd":25,"minutes":90,"iterations":1,"text":"cost=$25  time=90m  iterations=1"}' "the budgets as numbers"
  assert_contains "$plain" "Live:    on" "plain: live is on"
  assert_eq "$(jv "$OUT" 'j.settings.live')" true "live matches"
  assert_eq "$(jv "$OUT" 'j.settings.effort')" '"low"' "the effort foreman.conf gives"
  assert_eq "$(jv "$OUT" 'j.batch.name')" '"Pretty name"' "and the batch name"
fi

if case_is "dry-run --json: a human ticket next sends no prompt, and nothing left is still an object"; then
  repo="$WORK/dry-human-repo"
  make_status_repo "$repo"
  sed -i 's/^\*\*Status:\*\* ready-for-agent/**Status:** done/' "$repo/batch/issues/02-ticket.md"
  git -C "$repo" commit --quiet -am "02 landed"
  run_foreman "$repo" dry-run batch
  assert_contains "$OUT" "Would stop before batch/issues/03-ticket.md: it is a human ticket. No prompt would be sent." "plain says it would stop"
  run_foreman "$repo" dry-run batch --json
  assert_eq "$ST" 0 "exits 0, as the plain dry-run does"
  assert_eq "$(jv "$OUT" 'j.prompt')" null "no prompt would be sent"
  assert_eq "$(jv "$OUT" 'j.would_run.tickets')" '[]' "nothing would run"
  assert_eq "$(jv "$OUT" 'j.would_run.stops_at.file')" '"batch/issues/03-ticket.md"' "it would stop at the human ticket"
  assert_eq "$(jv "$OUT" 'j.would_run.stops_at.reached')" true "straight away"
  assert_eq "$(jv "$OUT" 'j.would_run.stops_at.handoff')" '"batch/handoff/03-handoff.md"' "and says where its handoff is"

  # Everything landed: the plain dry-run says so and exits 0; the JSON is an answer all the same.
  sed -i 's/^\*\*Status:\*\* ready-for-[a-z]*/**Status:** done/' "$repo"/batch/issues/0[345]-ticket.md
  git -C "$repo" commit --quiet -am "everything landed"
  run_foreman "$repo" dry-run batch
  assert_contains "$OUT" "Nothing to do" "plain says there is nothing to do"
  assert_eq "$ST" 0 "and exits 0"
  run_foreman "$repo" dry-run batch --json
  assert_eq "$ST" 0 "the JSON exits 0 as well"
  assert_eq "$(jv "$OUT" 'j.command')" '"dry-run"' "it is still an answer to dry-run"
  assert_eq "$(jv "$OUT" 'j.would_run')" '{"tickets":[],"remaining":[],"stops_at":null}' "nothing would run"
  assert_eq "$(jv "$OUT" 'j.prompt')" null "and there is no prompt"
  assert_eq "$(jv "$OUT" 'j.counts')" '{"done":5,"total":5}' "5 of 5"
fi

if case_is "dry-run --json: sends nothing and starts no sandbox"; then
  # The fake adapter is the one that records what it is asked: it appends every prompt to
  # FOREMAN_FAKE_PROMPT_LOG and counts its calls in a file keyed on the loop's pid. Neither may
  # exist after a dry run, with --json or without it.
  repo="$WORK/dry-nothing-repo"
  make_status_repo "$repo"
  export FOREMAN_FAKE_PROMPT_LOG="$WORK/fake-prompts.log"
  run_foreman "$repo" dry-run batch --json
  assert_eq "$ST" 0 "exits 0"
  assert_eq "$(jv "$OUT" 'j.prompt === null')" false "a prompt was built"
  [ ! -e "$FOREMAN_FAKE_PROMPT_LOG" ] && pass || fail "the fake exec was handed a prompt"
  assert_eq "$(ls "$WORK" | grep -c '^foreman-fake-.*\.calls$')" 0 "and was never called"
  assert_eq "$(git -C "$repo" log --oneline | wc -l)" "2" "nothing was committed"
  assert_eq "$(git -C "$repo" status --porcelain | wc -l)" "0" "and nothing was written to the tree"
  # The control: a real run on the same repository does reach the adapter, so the checks above can fail.
  run_foreman "$repo" run batch
  [ -e "$FOREMAN_FAKE_PROMPT_LOG" ] && pass || fail "the control: a run did not call the fake exec, so this test proves nothing"
  unset FOREMAN_FAKE_PROMPT_LOG
fi

if case_is "dry-run --json: a batch that cannot be read, a dirty tree: the plain dry-run's own message, no JSON"; then
  repo="$WORK/dry-error-repo"
  make_status_repo "$repo"
  printf 'x\n' > "$repo/stray.txt"
  run_foreman "$repo" dry-run batch
  plain_st="$ST"; plain_err="$ERR"
  run_foreman "$repo" dry-run batch --json
  assert_eq "$ST" "$plain_st" "the same exit status"
  assert_eq "$OUT" "" "no JSON is printed"
  assert_eq "$ERR" "$plain_err" "and the same words on stderr"
  assert_contains "$ERR" "working tree is dirty" "which say why"
fi

# ---------------------------------------------------------------------------
# foreman report --json
# ---------------------------------------------------------------------------

# A batch holding the report's own fixture log (test/golden/report-runs.jsonl, which test/smoke.sh
# checks the plain report against): three runs, seven iterations and a checkpoint turn, one line that
# is not JSON, and every outcome there is.
make_report_repo() {
  local repo="$1"
  make_status_repo "$repo"
  cp "$TEST_DIR/golden/report-runs.jsonl" "$repo/batch/foreman-runs.jsonl"
}

# What follows a label on the plain report's text: plain_line PLAIN 'label' (the line that starts with it).
plain_line() { printf '%s\n' "$1" | sed -n "s/^  $2 *//p" | head -1; }

if case_is "report --json: one object, versioned, naming its command"; then
  repo="$WORK/report-shape-repo"
  make_report_repo "$repo"
  run_foreman "$repo" report batch --json
  assert_eq "$ST" 0 "exits 0"
  assert_eq "$ERR" "" "says nothing on stderr"
  assert_eq "$(jv "$OUT" 'typeof j')" '"object"' "it parses, and is one object"
  assert_eq "$(jv "$OUT" 'j.foreman_json')" 1 "foreman_json is 1"
  assert_eq "$(jv "$OUT" 'j.command')" '"report"' "it names its command"
  assert_eq "$(printf '%s\n' "$OUT" | grep -c .)" 1 "on one line, so a reader can take it whole"
  assert_eq "$(jv "$OUT" 'j.batch')" '{"path":"batch","name":"batch"}' "the batch, repo-relative"
  assert_eq "$(jv "$OUT" 'j.log')" '"batch/foreman-runs.jsonl"' "the run log it read"
  assert_eq "$(jv "$OUT" 'j.by')" '"run"' "the rows are by run"
  assert_eq "$(jv "$OUT" 'Object.keys(j).join()')" '"foreman_json,command,batch,log,by,totals,rows"' "the keys, in this order"
  assert_eq "$(jv "$OUT" 'Object.keys(j.totals).join()')" \
    '"runs,iterations,landed,progressed,stalled,unproductive,checkpoints,limit_hits,unreadable,tokens,cost_usd,minutes,turns,per_iteration"' \
    "the totals' keys"
fi

if case_is "report --json: its totals are the plain report's"; then
  repo="$WORK/report-totals-repo"
  make_report_repo "$repo"
  run_foreman "$repo" report batch
  plain="$OUT"
  run_foreman "$repo" report batch --json
  assert_eq "$ST" 0 "exits 0"
  head="$(plain_line "$plain" iterations)"
  assert_eq "$head" "7  ·  landed 3  ·  progressed 1  ·  stalled 1  ·  unproductive 2  ·  checkpoint turns 1  ·  limit hits 1" "(the plain line this is checked against)"
  assert_eq "$(jv "$OUT" '`${j.totals.iterations}  ·  landed ${j.totals.landed}  ·  progressed ${j.totals.progressed}  ·  stalled ${j.totals.stalled}  ·  unproductive ${j.totals.unproductive}  ·  checkpoint turns ${j.totals.checkpoints}  ·  limit hits ${j.totals.limit_hits}`')" \
    "\"$head\"" "the outcome counts are the plain line's"
  assert_eq "$(plain_line "$plain" tokens)" "in 21,200  out 146,300  cache-read 5,820,000  cache-write 432,000" "(the plain tokens line)"
  assert_eq "$(jv "$OUT" 'const t = j.totals.tokens, f = (v) => v.toLocaleString("en-US"); `in ${f(t.input)}  out ${f(t.output)}  cache-read ${f(t.cache_read)}  cache-write ${f(t.cache_write)}`')" \
    '"in 21,200  out 146,300  cache-read 5,820,000  cache-write 432,000"' "the tokens are the plain line's"
  assert_eq "$(plain_line "$plain" billed)" "167,500 tokens  ·  \$6.9500  ·  48.2 model-minutes  ·  220 turns" "(the plain billed line)"
  assert_eq "$(jv "$OUT" 'const t = j.totals; `${t.tokens.billed.toLocaleString("en-US")} tokens  ·  $${t.cost_usd.toFixed(4)}  ·  ${t.minutes.toFixed(1)} model-minutes  ·  ${t.turns.toLocaleString("en-US")} turns`')" \
    '"167,500 tokens  ·  $6.9500  ·  48.2 model-minutes  ·  220 turns"' "the bill is the plain line's"
  assert_eq "$(plain_line "$plain" average)" "\$0.9929 and 23,929 billed tokens per iteration" "(the plain average line)"
  assert_eq "$(jv "$OUT" 'const p = j.totals.per_iteration; `$${p.cost_usd.toFixed(4)} and ${p.billed_tokens.toLocaleString("en-US")} billed tokens per iteration`')" \
    '"$0.9929 and 23,929 billed tokens per iteration"' "the average is the plain line's"
  assert_eq "$(jv "$OUT" 'j.totals.runs')" 3 "three runs"
  assert_eq "$(jv "$OUT" 'j.totals.unreadable')" 1 "the line that is not JSON is counted, as the plain report counts it"
fi

if case_is "report --json: one row per run, in the order they appear, and their counts add up to the totals"; then
  repo="$WORK/report-rows-repo"
  make_report_repo "$repo"
  run_foreman "$repo" report batch --json
  assert_eq "$(jv "$OUT" 'j.rows.map((r) => r.id).join()')" '"20261021T091200Z-4411,20261022T140533Z-9020,20261023T081014Z-1207"' "the runs"
  assert_eq "$(jv "$OUT" 'j.rows.map((r) => r.started_at).join()')" '"2026-10-21T09:12:00Z,2026-10-22T14:05:33Z,2026-10-23T08:10:14Z"' "each run's first start"
  assert_eq "$(jv "$OUT" 'JSON.stringify(j.rows[1])')" \
    '"{\"id\":\"20261022T140533Z-9020\",\"started_at\":\"2026-10-22T14:05:33Z\",\"iterations\":3,\"landed\":1,\"progressed\":1,\"stalled\":0,\"unproductive\":1,\"checkpoints\":1,\"limit_hits\":1,\"tokens\":{\"input\":12500,\"output\":93000,\"cache_read\":3650000,\"cache_write\":265000,\"billed\":105500},\"cost_usd\":4.25,\"minutes\":28.5,\"turns\":137}"' \
    "a run's whole row"
  for key in iterations landed progressed stalled unproductive checkpoints limit_hits turns; do
    assert_eq "$(jv "$OUT" "j.rows.reduce((n, r) => n + r.$key, 0) === j.totals.$key")" true "the rows' $key add up to the total"
  done
  assert_eq "$(jv "$OUT" 'Math.abs(j.rows.reduce((n, r) => n + r.cost_usd, 0) - j.totals.cost_usd) < 1e-9')" true "and so does the cost"
fi

if case_is "report --json --by-ticket: the rows are tickets, in the order they were first attempted"; then
  repo="$WORK/report-ticket-repo"
  make_report_repo "$repo"
  run_foreman "$repo" report batch --by-ticket
  plain="$OUT"
  run_foreman "$repo" report batch --by-ticket --json
  assert_eq "$ST" 0 "exits 0"
  assert_eq "$(jv "$OUT" 'j.by')" '"ticket"' "the rows are by ticket"
  assert_eq "$(jv "$OUT" 'j.rows.map((r) => r.id).join()')" \
    '"batch/issues/01-first.md,batch/issues/02-second.md,batch/issues/03-third.md,batch/issues/04-fourth.md,batch/issues/05-fifth.md"' "the tickets"
  assert_eq "$(jv "$OUT" 'j.rows.map((r) => r.started_at === undefined).join()')" '"true,true,true,true,true"' "a ticket has no start of its own"
  assert_contains "$plain" "batch/issues/03-third.md" "(the plain report lists it)"
  assert_eq "$(jv "$OUT" 'const r = j.rows[2]; `${r.iterations} ${r.landed} ${r.progressed} ${r.cost_usd}`')" '"2 1 1 3.5"' "03's counts"
  assert_eq "$(jv "$OUT" 'const r = j.rows[3]; `${r.iterations} ${r.unproductive} ${r.checkpoints} ${r.limit_hits} ${r.cost_usd}`')" '"1 1 1 1 0.75"' "04's counts, its checkpoint turn apart"
  assert_eq "$(jv "$OUT" 'j.rows.reduce((n, r) => n + r.iterations, 0) === j.totals.iterations')" true "the rows add up to the totals"
  assert_eq "$(jv "$OUT" 'j.run === undefined')" true "and it has no run's iterations unless asked"
fi

if case_is "report --json --run: that run's iterations, each with the outcome word the report counts it under"; then
  repo="$WORK/report-run-repo"
  make_report_repo "$repo"
  run_foreman "$repo" report batch --json --run 20261022T140533Z-9020
  assert_eq "$ST" 0 "exits 0"
  assert_eq "$ERR" "" "says nothing on stderr"
  assert_eq "$(jv "$OUT" 'Object.keys(j).join()')" '"foreman_json,command,batch,log,by,totals,rows,run"' "everything it printed without --run, then the run"
  assert_eq "$(jv "$OUT" 'j.run.id')" '"20261022T140533Z-9020"' "the run"
  assert_eq "$(jv "$OUT" 'j.run.started_at')" '"2026-10-22T14:05:33Z"' "its start"
  assert_eq "$(jv "$OUT" 'j.run.iterations.map((i) => i.iteration + ":" + i.outcome).join()')" \
    '"1:progressed,2:landed,3:unproductive,3:checkpoint"' "each iteration and its word (the checkpoint turn keeps its own)"
  assert_eq "$(jv "$OUT" 'JSON.stringify(j.run.iterations[2])')" \
    '"{\"iteration\":3,\"kind\":\"iteration\",\"ticket\":\"batch/issues/04-fourth.md\",\"outcome\":\"unproductive\",\"flags\":[\"error\",\"limit\"],\"limit_hit\":true,\"cost_usd\":0.5,\"duration_ms\":60000,\"turns\":8,\"exit_status\":1,\"started_at\":\"2026-10-22T15:00:00Z\"}"' \
    "an unproductive iteration, whole: what went wrong is in its flags"
  assert_eq "$(jv "$OUT" 'j.run.iterations[3].kind')" '"checkpoint"' "a checkpoint turn says what it is"
  assert_eq "$(jv "$OUT" 'const row = j.rows.find((r) => r.id === j.run.id), n = (w) => j.run.iterations.filter((i) => i.outcome === w).length; [n("landed") === row.landed, n("progressed") === row.progressed, n("stalled") === row.stalled, n("unproductive") === row.unproductive, n("checkpoint") === row.checkpoints, j.run.iterations.length - n("checkpoint") === row.iterations].join()')" \
    '"true,true,true,true,true,true"' "its words add up to the run's row"
  run_foreman "$repo" report batch --json --run 20261023T081014Z-1207
  assert_eq "$(jv "$OUT" 'j.run.iterations.map((i) => i.outcome).join()')" '"stalled,unproductive"' "a stalled iteration is stalled, not unproductive"
  assert_eq "$(jv "$OUT" 'j.run.iterations[1].flags.join()')" '""' "an unproductive iteration with nothing wrong beyond not landing has no flags"
  run_foreman "$repo" report batch --json --run 20261021T091200Z-4411
  assert_eq "$(jv "$OUT" 'j.run.iterations.map((i) => i.outcome).join()')" '"landed,landed"' "a landed iteration is landed"
  assert_eq "$(jv "$OUT" 'j.run.iterations[0].flags.length')" 0 "and has no flags"
  run_foreman "$repo" report batch --json --by-ticket --run 20261021T091200Z-4411
  assert_eq "$(jv "$OUT" '[j.by, j.run.id].join()')" '"ticket,20261021T091200Z-4411"' "--by-ticket and --run can be asked at once"
fi

if case_is "report --json --run: a run that is not in the log, and flags that do not go together"; then
  repo="$WORK/report-norun-repo"
  make_report_repo "$repo"
  run_foreman "$repo" report batch --json --run no-such-run
  assert_eq "$ST" 1 "an unknown run exits 1"
  assert_eq "$OUT" "" "and prints no JSON"
  assert_contains "$ERR" "no-such-run" "its stderr names the run"
  run_foreman "$repo" report batch --json --run
  assert_eq "$ST" 1 "--run with no id exits 1"
  assert_contains "$ERR" "--run" "and says what was missing"
  run_foreman "$repo" report batch --run 20261021T091200Z-4411
  assert_eq "$ST" 1 "--run without --json exits 1"
  assert_contains "$ERR" "--json" "and says it needs --json"
  run_foreman "$repo" report batch --json --failures
  assert_eq "$ST" 1 "--failures is the text's; --json refuses it"
  assert_contains "$ERR" "--failures" "and names it"
fi

if case_is "report --json: no log, or no readable record, is the plain report's answer"; then
  repo="$WORK/report-empty-repo"
  make_status_repo "$repo"
  rm -f "$repo/batch/foreman-runs.jsonl"
  run_foreman "$repo" report batch
  plain_err="$ERR"; plain_st="$ST"
  run_foreman "$repo" report batch --json
  assert_eq "$ST" "$plain_st" "no log: the same exit status"
  assert_eq "$OUT" "" "no log: nothing on stdout"
  assert_eq "$ERR" "$plain_err" "no log: the same words"
  printf 'nothing readable here\n' > "$repo/batch/foreman-runs.jsonl"
  run_foreman "$repo" report batch
  plain_err="$ERR"; plain_st="$ST"
  run_foreman "$repo" report batch --json
  assert_eq "$ST" "$plain_st" "no record: the same exit status"
  assert_eq "$OUT" "" "no record: nothing on stdout"
  assert_eq "$ERR" "$plain_err" "no record: the same words"
fi

if case_is "report --json: it is never drawn, wherever the terminal could show a picture"; then
  repo="$WORK/report-nodraw-repo"
  make_report_repo "$repo"
  # The dispatcher says the picture is wanted in these two variables; a window reading JSON must not
  # get escape codes for it, however they got set.
  OUT="$(cd "$repo" && FOREMAN_DRAW_TIER=24 FOREMAN_DRAW_COLS=140 node "$FOREMAN_HOME/lib/foreman-report.cjs" batch --json)"
  assert_eq "$(jv "$OUT" 'j.command')" '"report"' "node on its own, with the picture asked for"
  OUT="$(cd "$repo" && FOREMAN_DRAW_TIER=24 FOREMAN_DRAW_COLS=140 FOREMAN_SHOW=always "$FOREMAN" report batch --json)"
  assert_eq "$(jv "$OUT" 'j.command')" '"report"' "through the dispatcher with the show forced on"
fi

if case_is "report --json: the batch can be named from anywhere in the repository, and --jsonl still points at a moved log"; then
  repo="$WORK/report-where-repo"
  make_report_repo "$repo"
  mkdir -p "$repo/sub"
  OUT="$(cd "$repo/sub" && FOREMAN_SHOW=never "$FOREMAN" report ../batch --json)"
  assert_eq "$(jv "$OUT" 'j.batch.path')" '"batch"' "the batch is repo-relative, not relative to where it was run"
  assert_eq "$(jv "$OUT" 'j.log')" '"batch/foreman-runs.jsonl"' "and so is the log"
  run_foreman "$repo" report --json
  assert_eq "$(jv "$OUT" 'j.batch.name')" '"batch"' "the repository's only batch is inferred, as the plain report infers it"
  mv "$repo/batch/foreman-runs.jsonl" "$repo/batch/moved.jsonl"
  run_foreman "$repo" report --jsonl batch/moved.jsonl --json
  assert_eq "$ST" 0 "--jsonl with --json exits 0"
  assert_eq "$(jv "$OUT" 'j.totals.iterations')" 7 "and reads that log"
fi

if case_is "report: plain output is byte for byte what it was"; then
  repo="$WORK/report-golden-repo"
  make_report_repo "$repo"
  for view in by-run by-ticket failures; do
    flag=""; [ "$view" = by-run ] || flag="--$view"
    (cd "$repo" && FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN" report batch $flag > "$WORK/report.out" 2>&1)
    sed "s|batch/foreman-runs.jsonl|@LOG@|" "$WORK/report.out" > "$WORK/report.cmp"
    sed "s|@LOG@|@LOG@|" "$TEST_DIR/golden/report-$view.txt" > "$WORK/report.gold"
    cmp -s "$WORK/report.cmp" "$WORK/report.gold" && pass || fail "plain report ($view) differs from test/golden/report-$view.txt"
  done
fi

# ---------------------------------------------------------------------------
# The model in the run record, and per-ticket stats in status --json
# ---------------------------------------------------------------------------

# A batch whose run record has what a finished ticket's page needs, over make_status_repo's tickets:
#   01 (landed, renamed DONE_ since)  three iterations: progressed, stalled (with a checkpoint turn
#      of its own), landed — and a model change (none recorded, then sonnet, then opus). The first
#      line has no `model` at all, as every line written before this change.
#   02  one line whose model is the empty string
#   04  a model that changes and comes back: sonnet, opus, sonnet
#   03 and 05  never ran: no stats
M_SONNET=claude-sonnet-5-5
M_OPUS=claude-opus-5-5
make_stats_repo() {
  local repo="$1" t1="batch/issues/01-ticket.md" t1d="batch/issues/DONE_01-ticket.md" m
  make_status_repo "$repo"
  {
    printf '%s\n' '{"run_id":"RA","iteration":1,"kind":"iteration","ticket":"'$t1'","started_at":"2026-10-21T09:12:00Z","finished_at":"2026-10-21T09:22:00Z","committed":true,"status_flipped":false,"tree_dirty":false,"is_error":false,"progressed":true,"stalled":false,"cost_usd":1.25,"duration_ms":600000,"num_turns":10,"tokens":{"input":1000,"output":2000,"cache_read":3000,"cache_creation":400}}'
    printf '%s\n' '{"run_id":"RA","iteration":2,"kind":"iteration","ticket":"'$t1'","model":"'$M_SONNET'","started_at":"2026-10-21T09:23:00Z","finished_at":"2026-10-21T09:28:00Z","committed":false,"status_flipped":false,"tree_dirty":true,"is_error":false,"progressed":false,"stalled":true,"cost_usd":0.5,"duration_ms":300000,"num_turns":6,"tokens":{"input":100,"output":200,"cache_read":300,"cache_creation":40}}'
    printf '%s\n' '{"run_id":"RA","iteration":2,"kind":"checkpoint","ticket":"'$t1'","model":"'$M_SONNET'","started_at":"2026-10-21T09:28:10Z","finished_at":"2026-10-21T09:29:10Z","committed":true,"status_flipped":false,"tree_dirty":false,"is_error":false,"cost_usd":0.1,"duration_ms":60000,"num_turns":2,"tokens":{"input":10,"output":20,"cache_read":30,"cache_creation":4}}'
    printf '%s\n' '{"run_id":"RB","iteration":1,"kind":"iteration","ticket":"'$t1d'","model":"'$M_OPUS'","started_at":"2026-10-22T10:10:00Z","finished_at":"2026-10-22T10:12:00Z","committed":true,"status_flipped":true,"tree_dirty":false,"is_error":false,"progressed":false,"stalled":false,"cost_usd":0.75,"duration_ms":120000,"num_turns":5,"tokens":{"input":1,"output":2,"cache_read":3,"cache_creation":4}}'
    printf '%s\n' '{"run_id":"RC","iteration":1,"kind":"iteration","ticket":"batch/issues/02-ticket.md","model":"","started_at":"2026-10-23T08:00:00Z","finished_at":"2026-10-23T08:01:00Z","committed":true,"status_flipped":false,"tree_dirty":false,"is_error":false,"cost_usd":0.25,"duration_ms":60000,"num_turns":1,"tokens":{"input":5,"output":6,"cache_read":7,"cache_creation":8}}'
    printf 'this line is not a record\n'
    for m in $M_SONNET $M_OPUS $M_SONNET; do
      # An iteration that committed nothing and changed nothing: unproductive.
      printf '%s\n' '{"run_id":"RD","iteration":1,"kind":"iteration","ticket":"batch/issues/04-ticket.md","model":"'$m'","started_at":"2026-10-24T08:00:00Z","finished_at":"2026-10-24T08:01:00Z","committed":false,"status_flipped":false,"tree_dirty":false,"is_error":false,"cost_usd":0.5,"duration_ms":1000,"num_turns":1,"tokens":{"input":1,"output":1,"cache_read":1,"cache_creation":1}}'
    done
  } > "$repo/batch/foreman-runs.jsonl"
}

if case_is "stats: a ticket that ran has stats, the sums are the record's, and a ticket that never ran has none"; then
  repo="$WORK/stats-repo"
  make_stats_repo "$repo"
  run_foreman "$repo" status batch --json
  assert_eq "$ST" 0 "exits 0"
  assert_eq "$ERR" "" "says nothing on stderr"
  assert_eq "$(jv "$OUT" 'j.tickets.map(t => t.name + ":" + ("stats" in t))')" \
    '["01-ticket:true","02-ticket:true","03-ticket:false","04-ticket:true","05-ticket:false"]' \
    "stats on the tickets that ran, no key at all on the two that did not"
  assert_eq "$(jv "$OUT" 'Object.keys(j.tickets[0].stats).join()')" \
    '"iterations,cost_usd,duration_ms,turns,tokens,models,runs"' "the stats' keys, in this order"
  # Three iterations; the checkpoint turn is a fourth row of its own, counted in the sums (it spent
  # real money) and not in the iterations, as `foreman report` counts it.
  assert_eq "$(jv "$OUT" 'j.tickets[0].stats.iterations')" 3 "01: three iterations (a checkpoint turn is not one)"
  assert_eq "$(jv "$OUT" 'j.tickets[0].stats.cost_usd')" 2.6 "01: cost is the sum of all four rows"
  assert_eq "$(jv "$OUT" 'j.tickets[0].stats.duration_ms')" 1080000 "01: duration_ms is the sum"
  assert_eq "$(jv "$OUT" 'j.tickets[0].stats.turns')" 23 "01: turns (num_turns) is the sum"
  assert_eq "$(jv "$OUT" 'j.tickets[0].stats.tokens')" '{"input":1111,"output":2222,"cache_read":3333,"cache_creation":448}' "01: tokens are the sums"
  assert_eq "$(jv "$OUT" 'j.tickets[0].stats.cost_usd === j.tickets[0].spent_usd')" true "stats.cost_usd is what spent_usd already says"
  assert_eq "$(jv "$OUT" 'j.tickets[0].stats.runs')" \
    '[{"run":"RA","kind":"iteration","outcome":"progressed","cost_usd":1.25,"duration_ms":600000,"started_at":"2026-10-21T09:12:00Z","finished_at":"2026-10-21T09:22:00Z"},{"run":"RA","kind":"iteration","outcome":"stalled","cost_usd":0.5,"duration_ms":300000,"started_at":"2026-10-21T09:23:00Z","finished_at":"2026-10-21T09:28:00Z"},{"run":"RA","kind":"checkpoint","outcome":"checkpoint","cost_usd":0.1,"duration_ms":60000,"started_at":"2026-10-21T09:28:10Z","finished_at":"2026-10-21T09:29:10Z"},{"run":"RB","kind":"iteration","outcome":"landed","cost_usd":0.75,"duration_ms":120000,"started_at":"2026-10-22T10:10:00Z","finished_at":"2026-10-22T10:12:00Z"}]' \
    "01: one entry per row, in order, with the report's outcome word, across the DONE_ rename"
  assert_eq "$(jv "$OUT" 'j.tickets[1].stats.iterations + ":" + j.tickets[1].stats.turns')" '"1:1"' "02: its one iteration"
fi

if case_is "stats: models are the distinct ones, in order; a line with no model counts and adds none"; then
  repo="$WORK/stats-models-repo"
  make_stats_repo "$repo"
  run_foreman "$repo" status batch --json
  # 01's first line has no `model`: it is in every sum above, and the list starts at the second.
  assert_eq "$(jv "$OUT" 'j.tickets[0].stats.models')" '["'$M_SONNET'","'$M_OPUS'"]' "01: a model change reads sonnet then opus, the unrecorded line adds nothing"
  assert_eq "$(jv "$OUT" 'j.tickets[0].stats.runs[0].cost_usd')" 1.25 "01: the line without a model is still in runs"
  assert_eq "$(jv "$OUT" 'j.tickets[1].stats.models')" '[]' "02: the empty string is not a model"
  assert_eq "$(jv "$OUT" 'j.tickets[3].stats.models')" '["'$M_SONNET'","'$M_OPUS'"]' "04: sonnet, opus, sonnet is two models, in first-seen order"
  assert_eq "$(jv "$OUT" 'j.tickets[3].stats.iterations')" 3 "04: three iterations"
fi

if case_is "stats: each outcome is the word foreman report --json --run gives the same iteration"; then
  repo="$WORK/stats-outcome-repo"
  make_stats_repo "$repo"
  run_foreman "$repo" status batch --json
  stats="$OUT"
  all_words=""
  for id in RA RB RC RD; do
    run_foreman "$repo" report batch --json --run "$id"
    assert_eq "$ST" 0 "report --run $id exits 0"
    report_words="$(jv "$OUT" 'j.run.iterations.map(i => i.outcome)')"
    stats_words="$(jv "$stats" 'j.tickets.flatMap(t => (t.stats ? t.stats.runs : []).filter(r => r.run === "'$id'")).map(r => r.outcome)')"
    assert_eq "$stats_words" "$report_words" "run $id: the words are the same, in the same order"
    all_words="$all_words$report_words"
  done
  for w in landed progressed stalled checkpoint unproductive; do
    assert_contains "$all_words" "\"$w\"" "(the fixture has a $w iteration, so the words are not all alike)"
  done
fi

if case_is "stats: a batch with no run record has no stats, and a ticket's keys gain only stats"; then
  repo="$WORK/stats-none-repo"
  make_status_repo "$repo"
  rm -f "$repo/batch/foreman-runs.jsonl"
  run_foreman "$repo" status batch --json
  assert_eq "$ST" 0 "exits 0"
  assert_eq "$(jv "$OUT" 'j.tickets.some(t => "stats" in t)')" false "no ticket has stats"
  assert_eq "$(jv "$OUT" 'Object.keys(j.tickets[0]).join()')" \
    '"file,name,number,slug,title,status,state,done,human,blocked_by,checks,handoff,spent_usd"' "the ticket's keys are what they were"
  make_status_repo "$WORK/stats-plain-repo"
  run_foreman "$WORK/stats-plain-repo" status batch --json
  assert_eq "$(jv "$OUT" 'Object.keys(j.tickets[0]).join()')" \
    '"file,name,number,slug,title,status,state,done,human,blocked_by,checks,handoff,spent_usd,stats"' "a ticket that ran gains stats at the end, nothing else"
fi

if case_is "record: --model is written on the line, and is empty when it is not given"; then
  rec="$WORK/record-model"
  mkdir -p "$rec"
  payload='{"type":"result","subtype":"success","is_error":false,"num_turns":2,"duration_ms":1000,"total_cost_usd":0.5,"usage":{"input_tokens":1,"output_tokens":2}}'
  common=(--log "$rec/log" --verdict "$rec/verdict" --run-id R --iteration 1 --ticket t.md --batch b --base-ref a --head-ref b --started-at 2026-01-01T00:00:00Z --exit-status 0 --tree-dirty 0 --status-flipped 0 --quiet)
  printf '%s' "$payload" | node "$FOREMAN_HOME/lib/foreman-record.cjs" --jsonl "$rec/with.jsonl" "${common[@]}" --model claude-opus-5-5
  cp "$rec/verdict" "$rec/verdict-with"
  printf '%s' "$payload" | node "$FOREMAN_HOME/lib/foreman-record.cjs" --jsonl "$rec/without.jsonl" "${common[@]}"
  assert_eq "$(jv "$(cat "$rec/with.jsonl")" 'j.model')" '"claude-opus-5-5"' "--model is on the line"
  assert_eq "$(jv "$(cat "$rec/without.jsonl")" 'j.model')" '""' "no --model is the empty string"
  assert_eq "$(jv "$(cat "$rec/without.jsonl")" 'Object.keys(j).filter(k => k !== "model").join()')" \
    '"run_id,iteration,kind,ticket,batch,started_at,finished_at,base_ref,head_ref,committed,status_flipped,tree_dirty,exit_status,parse_ok,result_count,is_error,limit_hit,limit_reset,transient_error,context_exhausted,auth_failed,permission_denied,progressed,stalled,subtype,session_id,num_turns,duration_ms,duration_api_ms,cost_usd,tokens,reply"' \
    "every key the line had is still there"
  strip() { printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);delete j.model;delete j.finished_at;console.log(JSON.stringify(j))})'; }
  assert_eq "$(strip "$(cat "$rec/with.jsonl")")" "$(strip "$(cat "$rec/without.jsonl")")" "the two lines differ in nothing but model (and the clock)"
  # The verdict file is the loop's input: it must not change at all.
  assert_eq "$(cat "$rec/verdict-with")" "$(cat "$rec/verdict")" "the verdict file is the same with and without --model"
fi

if case_is "run on the fake exec: the line carries the model the run started with, however it was set"; then
  repo="$WORK/stats-run-repo"
  copy_fixture "$WORK/template" "$repo" 4
  # The default, then foreman.conf, then the environment (which wins over the file).
  (cd "$repo" && FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN" run batch 1 >/dev/null 2>&1)
  assert_eq "$(jv "$(sed -n 1p "$repo/batch/foreman-runs.jsonl")" 'j.model')" '"claude-sonnet-5-5"' "the default model"
  printf 'FOREMAN_MODEL=claude-haiku-5-5\n' >> "$repo/batch/foreman.conf"
  git -C "$repo" commit --quiet -am "conf" >/dev/null
  (cd "$repo" && FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN" run batch 1 >/dev/null 2>&1)
  assert_eq "$(jv "$(sed -n 2p "$repo/batch/foreman-runs.jsonl")" 'j.model')" '"claude-haiku-5-5"' "the model foreman.conf sets"
  (cd "$repo" && FOREMAN_MODEL=claude-opus-5-5 FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN" run batch 1 >/dev/null 2>&1)
  assert_eq "$(jv "$(sed -n 3p "$repo/batch/foreman-runs.jsonl")" 'j.model')" '"claude-opus-5-5"' "the model the environment sets"
  assert_eq "$(grep -c . "$repo/batch/foreman-runs.jsonl")" 3 "three lines were written (one per run)"
  rm -f "$WORK"/foreman-fake-*.calls
fi

# ---------------------------------------------------------------------------
# Flags that are not status's
# ---------------------------------------------------------------------------

if case_is "--json is for status, dry-run and report, for now: the others still refuse it as they did"; then
  repo="$WORK/json-others-repo"
  make_status_repo "$repo"
  run_foreman "$repo" run batch --json
  assert_eq "$ST" 1 "run --json is refused"
  assert_contains "$ERR" "Usage:" "run --json says how it is used"
  run_foreman "$repo" status batch --json --bogus
  assert_eq "$ST" 1 "an unknown flag is still refused beside --json"
  run_foreman "$repo" dry-run batch --json --bogus
  assert_eq "$ST" 1 "and beside dry-run --json"
  # --all is status's: a dry run is of one batch.
  run_foreman "$repo" dry-run --json --all
  assert_eq "$ST" 1 "dry-run --json --all is refused"
  assert_contains "$ERR" "Usage:" "and says how it is used"
  run_foreman "$repo" dry-run batch --all
  assert_eq "$ST" 1 "--all without status --json is refused"
fi

# ---------------------------------------------------------------------------
# install.sh (ticket 12): the wizard, the app, the shortcut
# ---------------------------------------------------------------------------

# A throwaway copy of the checkout's installer (so the installed-or-not check reads a gui/ of its
# own), with HOME, CLAUDE_CONFIG_DIR and the shim directory fresh. $1 names the setup under $WORK;
# it sets IN_CHECKOUT, IN_HOME, IN_CONFIG, IN_BIN and IN_APPDATA.
install_setup() {
  IN_ROOT="$WORK/install-$1"
  IN_CHECKOUT="$IN_ROOT/checkout"
  IN_HOME="$IN_ROOT/home"
  IN_CONFIG="$IN_ROOT/claude"
  IN_BIN="$IN_ROOT/bin"
  IN_APPDATA="$IN_ROOT/appdata"
  IN_STUBS="$IN_ROOT/stubs"
  rm -rf "$IN_ROOT"
  mkdir -p "$IN_CHECKOUT/gui" "$IN_HOME" "$IN_CONFIG" "$IN_APPDATA/Microsoft/Windows/Start Menu/Programs" "$IN_STUBS"
  cp -r "$FOREMAN_HOME/bin" "$FOREMAN_HOME/lib" "$FOREMAN_HOME/skills" "$FOREMAN_HOME/install.sh" "$IN_CHECKOUT/"
  cp "$FOREMAN_HOME/gui/package.json" "$FOREMAN_HOME/gui/package-lock.json" "$FOREMAN_HOME/gui/icon.ico" "$IN_CHECKOUT/gui/"
  IN_LNK="$IN_APPDATA/Microsoft/Windows/Start Menu/Programs/Foreman.lnk"
}

# Runs the copy's install.sh with a plain stdin and a captured stdout, so it is not a terminal.
# The output keeps the paths it printed with the throwaway root swapped for ROOT.
install_plain() {
  OUT="$(cd "$IN_ROOT" && env -u WSL_DISTRO_NAME HOME="$IN_HOME" CLAUDE_CONFIG_DIR="$IN_CONFIG" \
    FOREMAN_PROC_VERSION=/dev/null PATH="$IN_STUBS:$PATH" APPDATA="$IN_APPDATA" \
    bash "$IN_CHECKOUT/install.sh" --to "$IN_BIN" "$@" 2>&1 </dev/null)"
  ST=$?
  OUT="${OUT//$IN_ROOT/ROOT}"
}

if case_is "golden: install.sh is byte for byte what it was when nothing asks"; then
  : > "$WORK/install-plain.out"
  golden_step() { printf '== %s (exit %s)\n%s\n' "$1" "$ST" "$OUT" >> "$WORK/install-plain.out"; }
  install_setup golden
  install_plain;              golden_step "install"
  install_plain;              golden_step "install again"
  install_plain --uninstall;  golden_step "--uninstall"
  install_plain --uninstall;  golden_step "--uninstall with nothing left"
  install_setup golden
  install_plain --no-skill;   golden_step "--no-skill"
  # A foreign `foreman` is refused, and nothing is written.
  install_setup golden
  mkdir -p "$IN_BIN"; printf 'not ours\n' > "$IN_BIN/foreman"
  install_plain
  golden_step "a foreign shim"
  if [ "${FOREMAN_JSON_GOLDEN:-}" = write ]; then
    cp "$WORK/install-plain.out" "$TEST_DIR/golden/install-plain.txt"
    printf '  retook test/golden/install-plain.txt\n'
  fi
  cmp -s "$WORK/install-plain.out" "$TEST_DIR/golden/install-plain.txt" && pass || {
    fail "install.sh's output differs from test/golden/install-plain.txt"
    diff "$TEST_DIR/golden/install-plain.txt" "$WORK/install-plain.out" | head -20 >&2
  }
fi

# Stubs on PATH: an `npm` that logs its arguments and directory and makes gui/node_modules/electron
# (or fails, with FAKE_NPM_FAIL set), and a `powershell.exe` that logs its arguments and the
# variables the shortcut is made from, and makes the .lnk at $FOREMAN_LNK.
install_stubs() {
  cat > "$IN_STUBS/npm" <<'STUB'
#!/bin/bash
printf 'npm %s | %s\n' "$*" "$PWD" >> "$FAKE_LOG"
[ -z "${FAKE_NPM_FAIL:-}" ] || exit 1
mkdir -p node_modules/electron/dist && : > node_modules/electron/dist/electron.exe
STUB
  cat > "$IN_STUBS/powershell.exe" <<'STUB'
#!/bin/bash
printf 'powershell %s\n' "$*" >> "$FAKE_LOG"
printf 'LNK=%s\nTARGET=%s\nARGS=%s\nWORKDIR=%s\nICON=%s\n' "$FOREMAN_LNK" "$FOREMAN_TARGET" "$FOREMAN_ARGS" "$FOREMAN_WORKDIR" "$FOREMAN_ICON" >> "$FAKE_LOG"
: > "$FOREMAN_LNK"
STUB
  chmod +x "$IN_STUBS/npm" "$IN_STUBS/powershell.exe"
  FAKE_LOG="$IN_ROOT/fake.log"; : > "$FAKE_LOG"
  export FAKE_LOG
}

# A PATH with the tools install.sh uses and no npm, for "npm is not installed".
install_no_npm_path() {
  local t
  mkdir -p "$IN_ROOT/nonpm"
  for t in bash grep cp rm mkdir cat chmod sed dirname awk git uname tr; do
    ln -sf "$(command -v "$t")" "$IN_ROOT/nonpm/$t"
  done
}

# install_plain's twin on a terminal: stdin and stdout are the pseudo-terminal `script` makes,
# and $1 is typed at it. $2 is extra VAR=value settings; IN_TTY_SUFFIX is added to the command
# line inside it (` </dev/null` makes stdin not a terminal, ` | cat` makes stdout not one).
install_tty() {
  local input="$1" envs="$2" cmd; shift 2
  printf -v cmd '%q ' env -u COLORTERM -u WT_SESSION -u NO_COLOR -u CI -u COLUMNS -u FOREMAN_SHOW -u FOREMAN_COLOR \
    -u WSL_DISTRO_NAME HOME="$IN_HOME" CLAUDE_CONFIG_DIR="$IN_CONFIG" FOREMAN_PROC_VERSION=/dev/null \
    PATH="${IN_PATH:-$IN_STUBS:$PATH}" APPDATA="$IN_APPDATA" FAKE_LOG="$FAKE_LOG" TERM=xterm $envs \
    bash "$IN_CHECKOUT/install.sh" --to "$IN_BIN" "$@"
  OUT="$(printf '%b' "$input" | script -qec "bash -c $(printf '%q' "$cmd${IN_TTY_SUFFIX:-}")" /dev/null 2>/dev/null)"
  ST=$?
  OUT="${OUT//$'\r'/}"
  OUT="${OUT//$IN_ROOT/ROOT}"
  PLAIN="$(printf '%s' "$OUT" | sed $'s/\033\\[[0-9;]*[mK]//g')"    # the words, with no colour in them
}

install_calls() { grep -c '^npm ' "$FAKE_LOG" 2>/dev/null || true; }

if case_is "install --gui: npm ci in gui/, then the shortcut through powershell.exe, without asking"; then
  install_setup gui; install_stubs
  install_plain --gui
  assert_eq "$ST" 0 "--gui exits 0"
  assert_eq "$(grep '^npm ' "$FAKE_LOG")" "npm ci | $IN_CHECKOUT/gui" "npm ci ran once, in the checkout's gui/"
  assert_contains "$OUT" "installed the desktop app" "it says the app is installed"
  assert_contains "$OUT" "installed shortcut" "and that the shortcut is"
  assert_missing "$OUT" "What should this install" "it did not ask"
  [ -e "$IN_LNK" ] && pass || fail "the shortcut is at %APPDATA%/Microsoft/Windows/Start Menu/Programs/Foreman.lnk"
  assert_contains "$(grep '^powershell ' "$FAKE_LOG")" "-NoProfile" "powershell.exe -NoProfile"
  assert_contains "$(grep '^powershell ' "$FAKE_LOG")" "WScript.Shell" "through WScript.Shell"
  assert_eq "$(grep '^LNK=' "$FAKE_LOG")" "LNK=$IN_LNK" "the shortcut file"
  assert_eq "$(grep '^TARGET=' "$FAKE_LOG")" "TARGET=$IN_CHECKOUT/gui/node_modules/electron/dist/electron.exe" "its target is the checkout's electron.exe"
  assert_eq "$(grep '^ARGS=' "$FAKE_LOG")" "ARGS=\"$IN_CHECKOUT/gui\"" "its argument is the gui directory, quoted"
  assert_eq "$(grep '^ICON=' "$FAKE_LOG")" "ICON=$IN_CHECKOUT/gui/icon.ico" "its icon is gui/icon.ico"
  assert_eq "$(grep '^WORKDIR=' "$FAKE_LOG")" "WORKDIR=$IN_CHECKOUT" "and it starts in the checkout"
  [ -e "$IN_BIN/foreman" ] && pass || fail "the CLI was installed too"
  # The shortcut's values are not spliced into the PowerShell text.
  assert_missing "$(grep '^powershell ' "$FAKE_LOG")" "$IN_CHECKOUT" "no path is in the PowerShell command"
fi

if case_is "install --gui: no npm says so and installs the CLI only; a failing npm is reported"; then
  install_setup nonpm; install_stubs; install_no_npm_path
  # install_plain puts the stubs first and the system PATH after, and the system PATH has npm: here
  # PATH is only the tools install.sh uses.
  OUT="$(cd "$IN_ROOT" && env -u WSL_DISTRO_NAME HOME="$IN_HOME" CLAUDE_CONFIG_DIR="$IN_CONFIG" FOREMAN_PROC_VERSION=/dev/null \
    PATH="$IN_ROOT/nonpm" APPDATA="$IN_APPDATA" "$(command -v bash)" "$IN_CHECKOUT/install.sh" --to "$IN_BIN" --gui 2>&1 </dev/null)"
  ST=$?
  assert_eq "$ST" 0 "no npm is not a failure"
  assert_contains "$OUT" "needs Node's npm" "it says the app needs Node's npm"
  assert_contains "$OUT" "Installed the CLI only" "and that it installed the CLI only"
  [ -e "$IN_BIN/foreman" ] && pass || fail "the CLI is installed"
  [ ! -e "$IN_CHECKOUT/gui/node_modules" ] && pass || fail "no gui/node_modules"
  [ ! -e "$IN_LNK" ] && pass || fail "no shortcut"

  install_setup npmfail; install_stubs
  FAKE_NPM_FAIL=1 install_plain --gui
  assert_eq "$ST" 1 "a failing npm ci makes the installer exit 1"
  assert_contains "$OUT" "npm ci failed" "and says so"
  [ -e "$IN_BIN/foreman" ] && pass || fail "the CLI is installed all the same"
  [ ! -e "$IN_LNK" ] && pass || fail "and no shortcut is written for an app that is not there"
fi

if case_is "install: --gui and --no-gui together are refused, and nothing is written"; then
  install_setup both; install_stubs
  install_plain --gui --no-gui
  assert_eq "$ST" 1 "exits 1"
  assert_contains "$OUT" "contradict" "says why"
  [ ! -e "$IN_BIN" ] && pass || fail "nothing was written"
  install_plain --gui --gui
  assert_eq "$ST" 0 "the same flag twice is fine"
fi

if case_is "install: without a flag and off a terminal it asks nothing and installs no app"; then
  install_setup noask; install_stubs
  install_plain
  assert_eq "$(install_calls)" 0 "npm did not run"
  assert_missing "$OUT" "desktop" "the output does not mention the app"
  [ ! -e "$IN_LNK" ] && pass || fail "no shortcut"
fi

if case_is "install --no-gui and --uninstall: the app and its shortcut go, and nothing else"; then
  install_setup remove; install_stubs
  install_plain --gui
  # Things --uninstall must not touch: a batch, the env file, a credential.
  mkdir -p "$IN_HOME/.config/foreman" "$IN_ROOT/repo/batch"
  printf 'GH_TOKEN=secret\n' > "$IN_HOME/.config/foreman/env"
  printf 'cred\n' > "$IN_HOME/.claude-credentials"
  printf 'a ticket\n' > "$IN_ROOT/repo/batch/01-a.md"
  printf '{"x":1}\n' > "$IN_ROOT/repo/batch/foreman-runs.jsonl"
  install_plain --no-gui
  assert_eq "$ST" 0 "--no-gui exits 0"
  assert_contains "$OUT" "removed  ROOT/checkout/gui/node_modules" "--no-gui removes gui/node_modules"
  assert_contains "$OUT" "removed  ROOT/appdata/Microsoft/Windows/Start Menu/Programs/Foreman.lnk" "and the shortcut"
  [ ! -e "$IN_CHECKOUT/gui/node_modules" ] && pass || fail "gui/node_modules is gone"
  [ ! -e "$IN_LNK" ] && pass || fail "the shortcut is gone"
  [ -e "$IN_BIN/foreman" ] && pass || fail "the CLI is installed (--no-gui is 'CLI only')"
  install_plain --no-gui
  assert_missing "$OUT" "removed  ROOT/checkout/gui" "--no-gui again has nothing to remove, and says nothing about it"

  install_plain --gui
  install_plain --uninstall
  assert_eq "$ST" 0 "--uninstall exits 0"
  assert_contains "$OUT" "removed  ROOT/checkout/gui/node_modules" "--uninstall removes gui/node_modules"
  assert_contains "$OUT" "Foreman.lnk" "and the shortcut"
  [ ! -e "$IN_CHECKOUT/gui/node_modules" ] && [ ! -e "$IN_LNK" ] && [ ! -e "$IN_BIN/foreman" ] && pass || fail "everything is gone"
  assert_eq "$(cat "$IN_HOME/.config/foreman/env")" "GH_TOKEN=secret" "the env file is untouched"
  assert_eq "$(cat "$IN_HOME/.claude-credentials")" "cred" "a credential is untouched"
  [ -e "$IN_ROOT/repo/batch/01-a.md" ] && [ -e "$IN_ROOT/repo/batch/foreman-runs.jsonl" ] && pass || fail "a batch is untouched"
  [ -e "$IN_CHECKOUT/gui/package.json" ] && [ -e "$IN_CHECKOUT/gui/icon.ico" ] && pass || fail "the rest of gui/ is still there"
fi

if case_is "install --no-gui: an app that cannot be removed is said so, and exits 1"; then
  install_setup locked; install_stubs
  install_plain --gui
  chmod a-w "$IN_CHECKOUT/gui"
  if [ -w "$IN_CHECKOUT/gui" ]; then
    printf '  (this machine ignores a read-only directory: not run)\n'
  else
    install_plain --no-gui
    assert_eq "$ST" 1 "exits 1"
    assert_contains "$OUT" "could not remove" "says what it could not remove"
    assert_contains "$OUT" "is the app open" "and what to try"
    assert_missing "$OUT" "removed  ROOT/checkout/gui/node_modules" "and does not claim it removed it"
    [ -e "$IN_BIN/foreman" ] && pass || fail "the CLI is installed all the same"
  fi
  chmod u+w "$IN_CHECKOUT/gui"
fi

if case_is "install: --help lists --gui and --no-gui, and a bad flag's usage does"; then
  install_setup help
  assert_contains "$(bash "$IN_CHECKOUT/install.sh" --help)" "--gui" "--help names --gui"
  assert_contains "$(bash "$IN_CHECKOUT/install.sh" --help)" "--no-gui" "and --no-gui"
  assert_contains "$(bash "$IN_CHECKOUT/install.sh" --bogus 2>&1)" "[--gui | --no-gui]" "and so does the usage line"
fi

# The wizard needs a terminal, which is made with `script`; not every machine has it.
install_tty_ok() {
  command -v script >/dev/null 2>&1 || return 1
  install_setup probe; install_stubs
  install_tty "\n" "" --no-skill
  case "$OUT" in *Ready.*|*"Open a new shell"*) return 0 ;; *) return 1 ;; esac
}

if case_is "install wizard: asks only when stdin and stdout are both terminals"; then
  if install_tty_ok; then
    install_setup ask; install_stubs
    install_tty "2\n" ""
    assert_contains "$PLAIN" "What should this install?" "on a terminal it asks"
    assert_contains "$PLAIN" "1  CLI only" "the first answer is CLI only"
    assert_contains "$PLAIN" "2  CLI + desktop app" "the second is the app"
    assert_contains "$PLAIN" "Choice [1/2]:" "with the default shown"
    assert_eq "$(install_calls)" 1 "2 installs the app (npm ci once)"
    assert_contains "$PLAIN" "installed shortcut" "and writes the shortcut"

    install_setup ask1; install_stubs
    install_tty "\n" ""
    assert_contains "$PLAIN" "What should this install?" "it asks again in a fresh checkout"
    assert_eq "$(install_calls)" 0 "Enter picks 1, CLI only"
    [ -e "$IN_BIN/foreman" ] && pass || fail "and the CLI is installed"

    install_setup ask1b; install_stubs
    install_tty "1\n" ""
    assert_eq "$(install_calls)" 0 "typing 1 is CLI only"

    install_setup askjunk; install_stubs
    install_tty "3\nx\n2\n" ""
    assert_contains "$PLAIN" "Type 1 or 2" "anything else asks again"
    assert_eq "$(install_calls)" 1 "and the answer that follows counts"

    install_setup askeof; install_stubs
    install_tty "" ""
    assert_eq "$(install_calls)" 0 "no answer at all (end of input) is CLI only"
    [ -e "$IN_BIN/foreman" ] && pass || fail "and the CLI is installed"

    install_setup noin; install_stubs
    IN_TTY_SUFFIX=" </dev/null" install_tty "" ""
    assert_missing "$PLAIN" "What should this install" "stdin not a terminal: no question"
    install_setup noout; install_stubs
    IN_TTY_SUFFIX=" | cat" install_tty "2\n" ""
    assert_missing "$PLAIN" "What should this install" "stdout not a terminal: no question"
    assert_eq "$(install_calls)" 0 "and no app"
    unset IN_TTY_SUFFIX

    install_setup flagyes; install_stubs
    install_tty "" "" --gui
    assert_missing "$PLAIN" "What should this install" "--gui does not ask on a terminal"
    assert_eq "$(install_calls)" 1 "and installs the app"
    install_setup flagno; install_stubs
    install_tty "" "" --no-gui
    assert_missing "$PLAIN" "What should this install" "--no-gui does not ask on a terminal"
    assert_eq "$(install_calls)" 0 "and installs no app"
    install_setup refuse; install_stubs
    mkdir -p "$IN_BIN"; printf 'not ours\n' > "$IN_BIN/foreman"
    install_tty "" ""
    assert_missing "$PLAIN" "What should this install" "a refusal comes before the question"
  else
    printf '  (no usable script(1): the wizard on a terminal is not run)\n'
  fi
fi

if case_is "install wizard: a rerun offers only the piece that is missing"; then
  if install_tty_ok; then
    install_setup rerun; install_stubs
    install_tty "\n" "" --no-gui
    assert_missing "$PLAIN" "What should this install" "(setup) --no-gui asks nothing"
    install_tty "n\n" ""
    assert_contains "$PLAIN" "CLI installed" "a rerun with the CLI in place shows what is installed (take a2)"
    assert_contains "$PLAIN" "desktop app" "and the app line"
    assert_contains "$PLAIN" "not installed" "which is not installed"
    assert_contains "$PLAIN" "Add the desktop app too?" "and asks about the app alone"
    assert_missing "$PLAIN" "What should this install" "not the whole question"
    assert_eq "$(install_calls)" 0 "n is CLI only"
    install_tty "\n" ""
    assert_eq "$(install_calls)" 0 "Enter is n"
    install_tty "maybe\ny\n" ""
    assert_contains "$PLAIN" "Type y or n" "anything but y or n asks again"
    assert_eq "$(install_calls)" 1 "y installs the app"
    [ -e "$IN_LNK" ] && pass || fail "with its shortcut"

    install_tty "" ""
    assert_missing "$PLAIN" "install?" "with everything installed it asks nothing"
    assert_missing "$PLAIN" "Add the desktop app too" "not even the short question"
    assert_eq "$(install_calls)" 1 "and runs npm no more"

    # The shortcut is part of "installed", where one can be written: lose it and it is offered.
    rm -f "$IN_LNK"
    install_tty "n\n" ""
    assert_contains "$PLAIN" "Add the desktop app too?" "with the shortcut gone the app is offered again"
    # Without powershell.exe there is no shortcut to expect: electron alone is "installed".
    rm -f "$IN_STUBS/powershell.exe"
    install_tty "" ""
    assert_missing "$PLAIN" "Add the desktop app too" "no powershell.exe: electron alone counts as installed"
    # And with electron gone but a shortcut left, the app is offered.
    install_stubs; : > "$IN_LNK"; rm -rf "$IN_CHECKOUT/gui/node_modules"
    install_tty "n\n" ""
    assert_contains "$PLAIN" "Add the desktop app too?" "no electron: the app is offered"
  else
    printf '  (no usable script(1): the rerun is not run)\n'
  fi
fi

# The header: the picture, from the design's pixel map, drawn by lib/foreman-draw.cjs at each tier.
HEADER_PIXELS='....................................
...........ssseeesss................
..........seeeeeeeees...............
........sseerrrrrrreess.............
........serraaaaaaarres.............
.......serraaaaaaaaarres............
......seeraaaayyyaaaarees...........
......seraaayyyyyyyaaares...........
......seraaayyyy###aaares...........
......eeraayyyy#####aaree...........
......eeraayy#########ree...........
......eeraayyyyy###yaaree...........
......seraaayyyy###aaares...........
......seraaayy#######ares...........
......seeraaa##y###a##ees...........
.......serra##aa###ar##s............
........serra##a###r##s.............
........sseerrr#####ess.............
..........seeee##e##s...............
eeppprrrraaaaa##aaa##arrrrpppeesssss
sseeepppprrrr##rrrrr##ppppeeessnnnnn
nnssseeeepppp##ppppp##eeeesssnn.....
..nnnsssseeeeee##eee###sssnnn.......
.....nnnnsssssss##########..........'

if case_is "install wizard: the header is the design's picture at 24-bit and 256 colours, and words elsewhere"; then
  if install_tty_ok && command -v node >/dev/null 2>&1; then
    header_rows() {    # header_rows TIER — the 12 rows lib/foreman-draw.cjs draws from the pixel map
      HEADER_PIXELS="$HEADER_PIXELS" FOREMAN_HOME_UNDER_TEST="$FOREMAN_HOME" node -e '
        const draw = require(process.env.FOREMAN_HOME_UNDER_TEST + "/lib/foreman-draw.cjs");
        const key = { y: "sun", a: "amber", r: "rust", p: "post", e: "earth", s: "shade", n: "night", "#": "#0a0908", ".": null };
        const pixels = process.env.HEADER_PIXELS.split("\n").map((r) => Array.from(r).map((c) => key[c]));
        const tier = Number(process.argv[1]);
        process.stdout.write(draw.encode(draw.halfBlocks(pixels, tier), tier));
      ' "$1"
    }
    fresh_tty() { rm -rf "$IN_BIN"; install_tty "$@"; }    # the CLI not installed yet: the whole question
    spaces17="$(printf '%17s' '')"
    check_rows() {    # check_rows TIER LABEL — every row is a line of $OUT, rows 5 and 6 with the words after them
      local tier="$1" label="$2" i=0 row
      while IFS= read -r row; do
        case "$i" in
          4) case "$OUT" in *"$row$spaces17"*FOREMAN*) pass ;; *) fail "$label: row $i, with FOREMAN after it" ;; esac ;;
          5) case "$OUT" in *"$row$spaces17"*) pass ;; *) fail "$label: row $i, with the words after it" ;; esac ;;
          *) case "$OUT" in *$'\n'"$row"$'\n'*) pass ;; *) fail "$label: row $i" ;; esac ;;
        esac
        i=$((i + 1))
      done < <(header_rows "$tier")
      assert_eq "$i" 12 "$label: twelve rows"
    }
    install_setup art; install_stubs
    ( cd "$IN_CHECKOUT" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm c ) >/dev/null 2>&1
    hash="$(git -C "$IN_CHECKOUT" rev-parse --short HEAD)"

    fresh_tty "\n" "COLORTERM=truecolor COLUMNS=100"
    check_rows 24 "24-bit"
    fresh_tty "\n" "COLORTERM=truecolor COLUMNS=200"
    check_rows 24 "200 columns"
    assert_contains "$PLAIN" "from ROOT/checkout · $hash" "the words say where it is from and at which commit"
    assert_contains "$PLAIN" "install" "and the title"
    assert_contains "$PLAIN" "What should this install?" "and the question follows it"
    fresh_tty "\n" "TERM=xterm-256color COLUMNS=100"
    check_rows 256 "256-colour"
    fresh_tty "\n" "COLORTERM=truecolor COLUMNS=80"
    check_rows 24 "exactly 80 columns"

    for case_env in "COLORTERM=truecolor COLUMNS=79" "TERM=xterm-256color COLUMNS=60" "TERM=xterm COLUMNS=120" "NO_COLOR=1 COLORTERM=truecolor COLUMNS=120" "COLORTERM=truecolor COLUMNS=120 CI=1" "COLORTERM=truecolor COLUMNS=120 FOREMAN_SHOW=never" "COLORTERM=truecolor COLUMNS=120 FOREMAN_COLOR=never"; do
      fresh_tty "\n" "$case_env"
      case "$OUT" in *"▀"*|*"▄"*|*"█"*) fail "no art for: $case_env" ;; *) pass ;; esac
      assert_contains "$PLAIN" "FOREMAN  install" "the title is plain words for: $case_env"
      assert_contains "$PLAIN" "from ROOT/checkout · $hash" "and where from, for: $case_env"
      assert_contains "$PLAIN" "What should this install?" "and the question is still asked for: $case_env"
    done
    fresh_tty "\n" "NO_COLOR=1 COLORTERM=truecolor COLUMNS=120"
    case "$OUT" in *$'\033'*) fail "no colour at all with NO_COLOR" ;; *) pass ;; esac
    fresh_tty "\n" "TERM=xterm COLUMNS=120"
    case "$OUT" in *$'\033[38;2'*|*$'\033[38;5'*) fail "16 colours use no palette shade" ;; *) pass ;; esac

    # The long path is cut from the left to fit beside the picture, never wrapped.
    fresh_tty "\n" "COLORTERM=truecolor COLUMNS=80"
    case "$OUT" in *"…"*) pass ;; *) fail "a 80-column terminal cuts the long 'from' words" ;; esac
  else
    printf '  (no usable script(1) or no node: the header is not run)\n'
  fi
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
