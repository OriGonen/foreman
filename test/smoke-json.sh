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

# The toolkit as a machine without the desktop app has it, and as one with it: a copy of bin/ and lib/
# (foreman finds everything from where its own script is), with and without `gui/node_modules/electron`,
# the one thing foreman_app_installed looks for. The cases about what the app being installed changes
# run foreman from the copy they mean, so none of them depends on whether this checkout has the app.
toolkit_copy() {    # toolkit_copy app|noapp : the copy's bin/foreman in $TOOLKIT_FOREMAN
  local dir="$WORK/toolkit-$1"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" && cp -R "$FOREMAN_HOME/bin" "$FOREMAN_HOME/lib" "$dir/"
    [ "$1" != app ] || mkdir -p "$dir/gui/node_modules/electron"
  fi
  TOOLKIT_FOREMAN="$dir/bin/foreman"
}
toolkit_copy noapp; FOREMAN_NOAPP="$TOOLKIT_FOREMAN"
toolkit_copy app;   FOREMAN_APP="$TOOLKIT_FOREMAN"

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
  (cd "$repo" && HOME="$WORK/doctor-home" FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN_NOAPP" doctor "$@" 2>&1; echo "exit $?") |
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
# foreman doctor --json
# ---------------------------------------------------------------------------

# Run `foreman doctor` with the arguments in $2.. in repo $1 and keep what it said (OUT, ERR, ST), in a
# home of its own so nothing of the operator's is read.
doctor_run() {
  local repo="$1" t; shift
  mkdir -p "$WORK/doctor-home" "$WORK/doctor-stubs"
  # The runners a batch may ask for are there on every machine, so what the cases below say about the
  # machine does not depend on which one this is.
  for t in sbx claude; do
    [ -e "$WORK/doctor-stubs/$t" ] || { printf '#!/bin/sh\nexit 0\n' > "$WORK/doctor-stubs/$t"; chmod +x "$WORK/doctor-stubs/$t"; }
  done
  OUT="$(cd "$repo" && PATH="$WORK/doctor-stubs:$PATH" HOME="$WORK/doctor-home" FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN" doctor "$@" 2>"$WORK/stderr")"
  ST=$?
  ERR="$(cat "$WORK/stderr")"
}

if case_is "doctor --json: a ready repo is one object with the terminal's sections, all ok, and a next command"; then
  repo="$WORK/dj-ready"
  doctor_golden_repo "$repo" ready
  doctor_run "$repo" --json
  assert_eq "$ST" 0 "exits 0"
  assert_eq "$ERR" "" "says nothing on stderr"
  assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1 "one line"
  assert_eq "$(jv "$OUT" 'j.foreman_json')" 1 "foreman_json is 1"
  assert_eq "$(jv "$OUT" 'j.command')" '"doctor"' "and says which command it answers"
  assert_eq "$(jv "$OUT" 'j.sections.map(s => s.id).join()')" '"machine,repository,batches"' "sections, in the terminal's order, only those with something in them"
  assert_eq "$(jv "$OUT" 'j.sections.map(s => s.title).join()')" '"Machine,Repository,Batches"' "each with its title"
  assert_eq "$(jv "$OUT" 'j.sections[0].rows.slice(0, 3).map(r => r.label).join()')" '"git,node,awk"' "the machine's tools"
  assert_eq "$(jv "$OUT" 'j.sections.every(s => s.rows.every(r => r.result === "ok"))')" true "every row is ok"
  assert_eq "$(jv "$OUT" 'j.sections[1].rows[0].label')" '".foreman-iter.bundle ignored"' "a repository row, worded as the box words it"
  assert_eq "$(jv "$OUT" 'j.sections[2].rows.map(r => [r.label, r.detail]).flat().join("|")')" '"batch|0 of 2 done"' "a batch is its name and how far it has got"
  assert_eq "$(jv "$OUT" 'JSON.stringify(j.counts)')" '"{\"ok\":10,\"warn\":0,\"fail\":0}"' "the counts of rows"
  assert_eq "$(jv "$OUT" 'JSON.stringify(j.verdict)')" '"{\"passed\":true,\"label\":\"PASSED\",\"detail\":\"ready to run\",\"fixable\":0,\"blockers\":0}"' "the verdict, in the sign's own words"
  assert_eq "$(jv "$OUT" 'JSON.stringify(j.next)')" '"{\"label\":\"next\",\"command\":\"foreman run batch\"}"' "the next command"
  assert_eq "$(jv "$OUT" 'j.plan.length')" 0 "nothing for --fix to write"
  assert_eq "$(jv "$OUT" '"fix" in j')" false "and no fix report, as --fix was not asked for"
  assert_eq "$(jv "$OUT" 'j.repo === j.repo.replace(/\\/g, "/") && /\/dj-ready$/.test(j.repo)')" true "the repository, in the mixed form with no backslash"
  assert_eq "$(jv "$OUT" 'typeof j.rev + typeof j.date')" '"stringstring"' "the build and the date, as the title has them"
  assert_eq "$(jv "$OUT" 'j.sections.every(s => s.rows.every(r => r.fix === null && r.auto === false))')" true "no row has a fix when nothing is wrong"
fi

if case_is "doctor --json: what --fix would write is listed, with a fix on each row it covers, and nothing is written"; then
  repo="$WORK/dj-fixable"
  doctor_golden_repo "$repo" fixable
  doctor_run "$repo" --json
  assert_eq "$ST" 0 "exits 0 even though the repo needs something: the verdict is in the object"
  assert_eq "$(jv "$OUT" 'j.sections[1].rows.map(r => r.result).join()')" '"fail,fail,ok,fail,fail"' "the three missing ignore lines and the attributes line fail; the present one is ok"
  assert_eq "$(jv "$OUT" 'j.sections[1].rows.filter(r => r.result === "fail").every(r => r.auto === true)')" true "each of them is something --fix writes"
  assert_eq "$(jv "$OUT" 'j.sections[1].rows[0].fix')" '"foreman doctor --fix appends it to .gitignore"' "and says where"
  assert_eq "$(jv "$OUT" 'j.sections[1].rows[4].fix')" '"foreman doctor --fix appends foreman.conf text eol=lf to .gitattributes"' "the attributes row, too"
  assert_eq "$(jv "$OUT" 'j.sections[1].rows[4].notes[0]')" '"this repo rewrites line endings, so a tracked foreman.conf would come back CRLF"' "and the terminal's own note, kept as a note"
  assert_eq "$(jv "$OUT" 'j.sections[1].rows[2].fix')" null "a row that passed has no fix"
  assert_eq "$(jv "$OUT" 'JSON.stringify(j.counts)')" '"{\"ok\":6,\"warn\":0,\"fail\":4}"' "four to fix"
  assert_eq "$(jv "$OUT" 'JSON.stringify(j.verdict)')" '"{\"passed\":false,\"label\":\"NOT PASSED\",\"detail\":\"4 to fix\",\"fixable\":4,\"blockers\":0}"' "the verdict, and its sign's words"
  assert_eq "$(jv "$OUT" 'JSON.stringify(j.next)')" '"{\"label\":\"fix\",\"command\":\"foreman doctor --fix\"}"' "the next command is the fix"
  assert_eq "$(jv "$OUT" 'j.plan.map(p => p.file).join()')" '".gitignore,.gitattributes"' "the plan names the files, in the order --fix writes them"
  assert_eq "$(jv "$OUT" 'j.plan[0].text.startsWith("# Foreman: per-batch run state.") && j.plan[0].text.endsWith("**/foreman-runs.log\n")')" true "the .gitignore text is the whole block, newlines and all"
  assert_eq "$(jv "$OUT" 'j.plan[1].text')" '"# Foreman: foreman.conf is sourced by bash, so a CRLF checkout would append a carriage return\n# to every value it sets — FOREMAN_EXEC would become \"sandbox<CR>\" and fail validation with\n# a message that looks like a lie.\nforeman.conf text eol=lf\n"' "the attributes text, exactly"
  assert_eq "$(jv "$OUT" 'j.plan.every(p => typeof p.why === "string" && p.why.length > 0)')" true "each says why"
  assert_eq "$(git -C "$repo" status --short | tr -d ' \n')" "" "nothing in the repository was written"
fi

if case_is "doctor --fix --json: writes what the plan said, reports it, and the sheet read again is clean"; then
  repo="$WORK/dj-fix"
  doctor_golden_repo "$repo" fixable
  doctor_run "$repo" --json
  plan="$OUT"
  cp "$repo/.gitignore" "$WORK/dj-gitignore.before"; cp "$repo/.gitattributes" "$WORK/dj-gitattributes.before"
  doctor_run "$repo" --fix --json
  assert_eq "$ST" 0 "exits 0"
  assert_eq "$ERR" "" "nothing on stderr"
  assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1 "still one line: the plain 'wrote' lines are not printed"
  assert_eq "$(jv "$OUT" 'JSON.stringify(j.fix.appended)')" "$(jv "$plan" 'JSON.stringify(j.plan.map(p => ({ file: p.file, text: p.text })))')" "what it reports appended is what the plan said"
  assert_eq "$(jv "$OUT" 'j.fix.remaining')" 0 "nothing is left to fix"
  assert_eq "$(jv "$OUT" 'j.verdict.passed')" false "the sheet is the one it found, as the terminal's box is"
  assert_eq "$(jv "$OUT" 'JSON.stringify(j.plan)')" "$(jv "$plan" 'JSON.stringify(j.plan)')" "and the plan is there too"
  { cat "$WORK/dj-gitignore.before"; node -e 'process.stdout.write(JSON.parse(process.argv[1]).plan[0].text)' "$plan"; } > "$WORK/dj-gitignore.expect"
  cmp -s "$WORK/dj-gitignore.expect" "$repo/.gitignore" && pass || fail ".gitignore is what it was plus exactly the text reported"
  { cat "$WORK/dj-gitattributes.before"; node -e 'process.stdout.write(JSON.parse(process.argv[1]).plan[1].text)' "$plan"; } > "$WORK/dj-gitattributes.expect"
  cmp -s "$WORK/dj-gitattributes.expect" "$repo/.gitattributes" && pass || fail ".gitattributes is what it was plus exactly the text reported"
  doctor_run "$repo" --json
  assert_eq "$(jv "$OUT" 'j.verdict.passed')" true "read again, it passes"
  assert_eq "$(jv "$OUT" 'j.plan.length')" 0 "with nothing to write"
  doctor_run "$repo" --fix --json
  assert_eq "$(jv "$OUT" 'JSON.stringify(j.fix)')" '"{\"appended\":[],\"remaining\":0}"' "--fix with nothing to fix appends nothing"
  doctor_run "$repo" --json --fix
  assert_eq "$ST" 0 "the flags go in either order"
  assert_eq "$(jv "$OUT" '"fix" in j')" true "and --fix is still understood"
fi

if case_is "doctor --json: what is wrong and cannot be written is a fail with its fix, a warning does not fail the verdict"; then
  repo="$WORK/dj-bad"
  doctor_golden_repo "$repo" ready
  printf 'FOREMAN_EXEC=bogus\n' > "$repo/batch/foreman.conf"
  mkdir -p "$repo/other"; printf 'FOREMAN_EXEC=local\n' > "$repo/other/foreman.conf"
  git -C "$repo" add -A >/dev/null; git -C "$repo" commit --quiet -m "two bad batches"
  doctor_run "$repo" --json
  assert_eq "$ST" 0 "exits 0"
  assert_eq "$(jv "$OUT" 'j.sections.find(s => s.id === "machine").rows.filter(r => r.result === "fail").some(r => /^FOREMAN_EXEC=bogus in /.test(r.label))')" true "a mode that does not exist is a fail on the machine"
  assert_eq "$(jv "$OUT" 'j.sections[0].rows.find(r => r.result === "fail" && /bogus/.test(r.label)).fix.startsWith("Set FOREMAN_EXEC in ")')" true "with what to do about it"
  assert_eq "$(jv "$OUT" 'j.sections[0].rows.find(r => r.result === "fail" && /bogus/.test(r.label)).notes[0].startsWith("valid modes: ")')" true "and the terminal's note of the valid modes"
  assert_eq "$(jv "$OUT" 'j.sections.find(s => s.id === "batches").rows.filter(r => r.result === "fail").map(r => r.label).join("|")')" '"other/foreman.conf — FOREMAN_EXEC=local with no way for the agent to commit"' "a local batch that could never commit is a fail under batches"
  assert_eq "$(jv "$OUT" 'j.sections.find(s => s.id === "batches").rows.find(r => r.result === "fail").fix')" '"Add to other/foreman.conf: FOREMAN_CLAUDE_ARGS=(--allowed-tools \"Bash(git add:*)\" \"Bash(git commit:*)\")"' "and the line to add"
  assert_eq "$(jv "$OUT" 'j.sections.every(s => s.rows.filter(r => r.result === "fail").every(r => r.auto === false))')" true "none of these is something --fix writes"
  assert_eq "$(jv "$OUT" 'j.verdict.passed')" false "not passed"
  assert_eq "$(jv "$OUT" 'j.verdict.label + "|" + j.verdict.detail + "|" + j.verdict.blockers + "|" + j.verdict.fixable')" '"NOT PASSED|2 blockers|2|0"' "two blockers, as the sign would say"
  assert_eq "$(jv "$OUT" 'j.next')" null "and no next command: nothing foreman can do for them"
  assert_eq "$(jv "$OUT" 'j.plan.length')" 0 "nothing to write"
  doctor_run "$repo" --fix --json
  assert_eq "$(jv "$OUT" 'j.fix.remaining')" 2 "--fix leaves both, and says so"

  # A skill copy that has drifted is a warning, and a warning is not a reason to fail.
  repo="$WORK/dj-skill"
  doctor_golden_repo "$repo" ready
  skill_home="$WORK/dj-skill-home"; skill_config="$WORK/dj-skill-config"
  mkdir -p "$skill_home" "$skill_config"
  HOME="$skill_home" CLAUDE_CONFIG_DIR="$skill_config" bash "$FOREMAN_HOME/install.sh" --no-gui --to "$WORK/dj-skill-bin" >/dev/null 2>&1
  skill_md="$(ls "$skill_config"/skills/*/SKILL.md | head -1)"
  OUT="$(cd "$repo" && HOME="$skill_home" CLAUDE_CONFIG_DIR="$skill_config" FOREMAN_SHOW=never "$FOREMAN" doctor --json 2>&1)"
  assert_eq "$(jv "$OUT" 'j.sections.find(s => s.id === "skill").rows.every(r => r.result === "ok")')" true "an installed copy that matches is ok"
  printf '\n<!-- drift -->\n' >> "$skill_md"
  OUT="$(cd "$repo" && HOME="$skill_home" CLAUDE_CONFIG_DIR="$skill_config" FOREMAN_SHOW=never "$FOREMAN" doctor --json 2>&1)"
  assert_eq "$(jv "$OUT" 'j.sections.find(s => s.id === "skill").rows.filter(r => r.result === "warn").length')" 1 "one that drifted is a warning"
  assert_eq "$(jv "$OUT" 'j.sections.find(s => s.id === "skill").rows.find(r => r.result === "warn").fix')" "\"run: bash $FOREMAN_HOME/install.sh\"" "with the command that brings it up to date"
  assert_eq "$(jv "$OUT" 'j.sections.find(s => s.id === "skill").rows.find(r => r.result === "warn").notes.length')" 0 "which is not repeated as a note"
  assert_eq "$(jv "$OUT" 'JSON.stringify([j.counts.warn, j.verdict.passed, j.verdict.detail])')" '"[1,true,\"ready to run\"]"' "the verdict still passes"
fi

if case_is "doctor --json: a repo with no batch says what to do, and the show cannot draw into the JSON"; then
  repo="$WORK/dj-nobatch"
  mkdir -p "$repo"; git -C "$repo" init --quiet
  doctor_run "$repo" --json
  assert_eq "$ST" 0 "exits 0"
  assert_eq "$(jv "$OUT" 'j.sections.find(s => s.id === "batches").rows.length')" 0 "no batch row"
  assert_eq "$(jv "$OUT" 'j.sections.find(s => s.id === "batches").info[0]')" '"none — no directory here has a foreman.conf."' "the sentence the terminal prints, as info"
  assert_eq "$(jv "$OUT" 'j.sections.find(s => s.id === "batches").info[1]')" '"Create one:  foreman init <batch-dir>"' "and how to create one"
  assert_eq "$(jv "$OUT" 'j.sections.every(s => s.rows.every(r => ["ok", "warn", "fail"].includes(r.result)))')" true "a row is only ever ok, warn or fail: those lines are not rows"
  assert_eq "$(jv "$OUT" 'j.verdict.passed === (j.counts.fail === 0)')" true "the verdict is its rows' verdict"

  # A terminal that would be drawn on: forced, wide, truecolour. A program still gets only the object.
  OUT="$(cd "$repo" && HOME="$WORK/doctor-home" FOREMAN_SHOW=always COLORTERM=truecolor COLUMNS=120 "$FOREMAN" doctor --json 2>"$WORK/stderr")"
  assert_eq "$(jv "$OUT" 'j.command')" '"doctor"' "forced show: still one JSON object"
  assert_missing "$OUT" $'\033' "with no escape in it"
  assert_eq "$(cat "$WORK/stderr")" "" "and nothing on stderr"

  # Outside a repository there is nothing to inspect: an error on stderr, no JSON.
  outside="$WORK/dj-outside"; mkdir -p "$outside"
  OUT="$(cd "$outside" && GIT_CEILING_DIRECTORIES="$WORK" HOME="$WORK/doctor-home" FOREMAN_SHOW=never "$FOREMAN" doctor --json 2>"$WORK/stderr")"; ST=$?
  assert_eq "$ST" 1 "outside a repository: exits 1"
  assert_eq "$OUT" "" "prints no JSON"
  assert_contains "$(cat "$WORK/stderr")" "not inside a git repository" "and says why"
fi

if case_is "doctor --json: a credential is set or unset, and no part of its value is in anything doctor prints"; then
  repo="$WORK/dj-secret"
  doctor_golden_repo "$repo" fixable
  token="dckr_pat_Zq7Xk9Rw2mVbN4tY8cLp"
  user="someone-Hn3Jd8Fs"
  printf 'FOREMAN_DOCKER_USERNAME=%s\nFOREMAN_DOCKER_PAT=%s\n' "$user" "$token" > "$WORK/dj-secret-cred"
  leaks() {    # leaks TEXT SECRET: 1 when any 4-character piece of SECRET is in TEXT
    node -e '
      const [text, secret] = process.argv.slice(1); let hit = 0;
      for (let n = 4; n <= secret.length && !hit; n++) for (let i = 0; i + n <= secret.length; i++) if (text.includes(secret.slice(i, i + n))) { hit = 1; break; }
      console.log(hit);' "$1" "$2"
  }
  for via in env file none; do
    case "$via" in
      env)  creds=(env FOREMAN_DOCKER_PAT="$token" FOREMAN_DOCKER_USERNAME="$user") ;;
      file) creds=(env FOREMAN_CREDENTIALS_FILE="$WORK/dj-secret-cred") ;;
      none) creds=(env) ;;
    esac
    for args in "--json" "--fix --json"; do
      rm -rf "$WORK/dj-secret-run"; cp -R "$repo" "$WORK/dj-secret-run"
      # shellcheck disable=SC2086
      OUT="$(cd "$WORK/dj-secret-run" && "${creds[@]}" HOME="$WORK/doctor-home" FOREMAN_SHOW=never "$FOREMAN" doctor $args 2>"$WORK/stderr")"
      want=set; [ "$via" = none ] && want=unset
      assert_eq "$(jv "$OUT" 'JSON.stringify(j.credentials)')" "\"[{\\\"name\\\":\\\"FOREMAN_DOCKER_USERNAME\\\",\\\"state\\\":\\\"$want\\\"},{\\\"name\\\":\\\"FOREMAN_DOCKER_PAT\\\",\\\"state\\\":\\\"$want\\\"}]\"" "$via, $args: each credential is $want, by name"
      assert_eq "$(leaks "$OUT$(cat "$WORK/stderr")" "$token")" 0 "$via, $args: no part of the token is in what doctor printed"
      assert_eq "$(leaks "$OUT$(cat "$WORK/stderr")" "$user")" 0 "$via, $args: nor of the user name"
    done
  done
  OUT="$(cd "$repo" && FOREMAN_DOCKER_PAT="$token" HOME="$WORK/doctor-home" FOREMAN_SHOW=never "$FOREMAN" doctor 2>&1)"
  assert_eq "$(leaks "$OUT" "$token")" 0 "the plain doctor never printed it either"
fi

# ---------------------------------------------------------------------------
# The control directory, `foreman keys`, `foreman stop` and `# reason:`
# ---------------------------------------------------------------------------

# A repository of $2 tickets whose .gitignore also ignores `**/.foreman-run/` (as `doctor --fix` does
# once the app is installed), so a run keeps its control directory in the batch. `plain` leaves the
# line out, and the run keeps a temporary directory, as it always did.
ctl_repo() {    # ctl_repo REPO TICKETS [ignored|plain]
  copy_fixture "$WORK/template" "$1" "$2"
  if [ "${3:-ignored}" = ignored ]; then
    printf '**/.foreman-run/\n' >> "$1/.gitignore"
    git -C "$1" add -A >/dev/null
    git -C "$1" commit --quiet -m "ignore the control directory"
  fi
}

# `foreman run` in the background in $1, with the words in BG_ENV as its environment. What it printed
# is in $WORK/bg.out and its exit status in $WORK/bg.st; bg_wait waits for it and sets BG_ST and BG_OUT.
BG_ENV=()
BG_PID=""
bg_run() {    # bg_run REPO RUN-ARGS...
  local repo="$1"; shift
  rm -f "$WORK/bg.st" "$WORK/bg.out"
  ( cd "$repo" && env FOREMAN_SHOW=never FOREMAN_COLOR=never ${BG_ENV[@]+"${BG_ENV[@]}"} "$FOREMAN" run "$@" > "$WORK/bg.out" 2>&1
    echo $? > "$WORK/bg.st" ) &
  BG_PID=$!
}
bg_wait() {
  wait "$BG_PID" 2>/dev/null
  BG_ST="$(cat "$WORK/bg.st" 2>/dev/null)"
  BG_OUT="$(cat "$WORK/bg.out" 2>/dev/null)"
  rm -f "$WORK"/foreman-fake-*.calls
}
# Polls every tenth of a second for up to $1 seconds until the rest, run as a command, succeeds.
wait_until() {    # wait_until SECONDS COMMAND...
  local n=$(($1 * 10)); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
file_is() { [ "$(cat "$1" 2>/dev/null)" = "$2" ]; }
# Whether a run is in flight in the batch that keeps its control directory at $1.
run_up() { [ -f "$1/pid" ]; }

# `foreman` in $1 with the words in $2 as its environment, as run_foreman does otherwise.
run_foreman_env() {    # run_foreman_env REPO "A=1 B=2" ARGS...
  local repo="$1" envs="$2"; shift 2
  # shellcheck disable=SC2086
  OUT="$(cd "$repo" && env FOREMAN_SHOW=never FOREMAN_COLOR=never $envs "$FOREMAN" "$@" 2>"$WORK/stderr")"
  ST=$?
  ERR="$(cat "$WORK/stderr")"
  rm -f "$WORK"/foreman-fake-*.calls
}

if case_is "control directory: in the batch when .foreman-run/ is ignored, with the files the keys use and pid and run"; then
  repo="$WORK/ctl-in"; ctl_repo "$repo" 3
  ctl="$repo/batch/.foreman-run"
  BG_ENV=(FOREMAN_FAKE_SLEEP=2); bg_run "$repo" batch 2
  wait_until 30 file_is "$ctl/iteration" 1 && pass || fail "the run is at iteration 1 in <batch>/.foreman-run/"
  assert_eq "$(cat "$ctl/budget" 2>/dev/null)" 2 "budget: the iteration budget"
  assert_eq "$(cat "$ctl/live" 2>/dev/null)" 0 "live: off, as the run was started"
  run_id="$(cut -d' ' -f1 "$ctl/run" 2>/dev/null)"
  started="$(cut -d' ' -f2 "$ctl/run" 2>/dev/null)"
  case "$run_id" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9]*) pass ;; *) fail "run: starts with the run id, not '$run_id'" ;; esac
  case "$started" in 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) pass ;; *) fail "run: ends with the start time, not '$started'" ;; esac
  assert_eq "$(wc -w < "$ctl/run" | tr -d ' ')" 2 "run: nothing else"
  # The loop's own pid, as the run id ends with it, and the pid Windows knows it by (the same number elsewhere).
  assert_eq "$(cut -d' ' -f1 "$ctl/pid" 2>/dev/null)" "${run_id##*-}" "pid: the loop's pid first"
  case "$(cut -d' ' -f2 "$ctl/pid" 2>/dev/null)" in ''|*[!0-9]*) fail "pid: the Windows pid second" ;; *) pass ;; esac
  assert_eq "$(wc -w < "$ctl/pid" | tr -d ' ')" 2 "pid: nothing else"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "the directory is ignored: the tree is clean while the run is going"
  [ -e "$ctl/feed" ] && fail "feed: not written when live was never on" || pass
  bg_wait
  assert_eq "$BG_ST" 10 "the run pauses at its budget"
  [ -e "$ctl" ] && fail "the directory is gone when the run ends" || pass
fi

if case_is "control directory: a repo that does not ignore .foreman-run/ keeps today's temporary directory, and nothing else changes"; then
  repo="$WORK/ctl-out"; ctl_repo "$repo" 2 plain
  rm -rf "$WORK"/tmp.*
  BG_ENV=(FOREMAN_FAKE_SLEEP=2); bg_run "$repo" batch 1
  wait_until 30 bash -c "ls '$WORK'/tmp.*/pid >/dev/null 2>&1" && pass || fail "the run keeps a mktemp directory"
  [ -e "$repo/batch/.foreman-run" ] && fail "nothing is made in the batch" || pass
  assert_eq "$(git -C "$repo" status --porcelain)" "" "and the tree is clean"
  bg_wait
  assert_eq "$BG_ST" 10 "the run ends as it always did"
  assert_eq "$(ls -d "$WORK"/tmp.* 2>/dev/null | wc -l | tr -d ' ')" 0 "and the temporary directory is removed"

  # Not steerable, and the answer says so in one line.
  run_foreman "$repo" keys batch +
  assert_eq "$ST" 1 "keys: a run whose directory is outside the batch cannot be reached"
fi

if case_is "control directory: a live run in the batch keeps its directory, and a run that was killed leaves nothing in the way"; then
  repo="$WORK/ctl-held"; ctl_repo "$repo" 2
  ctl="$repo/batch/.foreman-run"
  # Another run holds the directory: this one must not use it (nor take its keys).
  mkdir -p "$ctl"
  printf '7\n' > "$ctl/budget"; printf '%s %s\n' "$$" "$$" > "$ctl/pid"
  run_foreman "$repo" run batch 1
  assert_eq "$ST" 10 "a second run still runs"
  assert_eq "$(cat "$ctl/budget")" 7 "the first run's budget is not touched"
  assert_eq "$(cut -d' ' -f1 "$ctl/pid")" "$$" "nor its pid"
  rm -rf "$ctl"

  # A run killed too hard to clean up: its files are cleared by the next run, and `out` stays.
  repo="$WORK/ctl-stale"; ctl_repo "$repo" 2
  ctl="$repo/batch/.foreman-run"
  sleep 0 & dead=$!; wait "$dead"
  mkdir -p "$ctl"
  printf '99\n' > "$ctl/budget"; printf '%s %s\n' "$dead" "$dead" > "$ctl/pid"; printf '00:01 · Write old\n' > "$ctl/feed"
  printf 'what the app captured\n' > "$ctl/out"
  run_foreman "$repo" run batch 1
  assert_eq "$ST" 10 "a run over a stale directory runs"
  assert_eq "$(ls -A "$ctl")" "out" "only out is left"
  assert_eq "$(cat "$ctl/out")" "what the app captured" "and it is as it was"
fi

# What every way a run can end leaves behind: nothing in the control directory but `out`, and no
# directory at all when there is no `out`. Run with `out` there, as the app does.
ctl_exit_case() {    # ctl_exit_case LABEL EXPECTED-EXIT TICKETS "ENV" RUN-ARGS...
  local label="$1" want="$2" n="$3" envs="$4" repo; shift 4
  repo="$WORK/ctl-exit-$label"; ctl_repo "$repo" "$n"
  [ "$label" != waiting ] || { make_human_ticket_json "$repo" 2; }
  mkdir -p "$repo/batch/.foreman-run"
  printf 'what the app captured\n' > "$repo/batch/.foreman-run/out"
  run_foreman_env "$repo" "$envs" run batch "$@"
  assert_eq "$ST" "$want" "$label: exit $want"
  assert_eq "$(ls -A "$repo/batch/.foreman-run" 2>/dev/null)" "out" "$label: only out is left"
  assert_eq "$(cat "$repo/batch/.foreman-run/out" 2>/dev/null)" "what the app captured" "$label: out is as it was"
  # And with no out, no directory.
  repo="$repo-bare"; ctl_repo "$repo" "$n"
  [ "$label" != waiting ] || { make_human_ticket_json "$repo" 2; }
  run_foreman_env "$repo" "$envs" run batch "$@"
  assert_eq "$ST" "$want" "$label (no out): exit $want"
  [ -e "$repo/batch/.foreman-run" ] && fail "$label (no out): the directory is gone" || pass
}
make_human_ticket_json() {    # make_human_ticket_json REPO N
  local repo="$1" n="$2"
  sed -i 's/^\*\*Status:\*\* todo/**Status:** ready-for-human/' "$repo/batch/issues/0$n-ticket.md"
  git -C "$repo" add -A >/dev/null
  git -C "$repo" commit --quiet -m "ticket $n is a human ticket"
}

if case_is "control directory: removed on exit 10 (budget), 20 (needs a human), 30 (waiting on a human) and 1, out kept"; then
  ctl_exit_case budget 10 3 "" 1
  ctl_exit_case needs-human 20 2 "FOREMAN_FAKE_BEHAVIOUR=noop FOREMAN_TICKET_ATTEMPTS=1" --unlimited
  ctl_exit_case waiting 30 3 "" --unlimited
  ctl_exit_case prepare-fails 1 2 "FOREMAN_FAKE_PREPARE=fail" 1
  assert_contains "$ERR" "told not to prepare" "(exit 1 is the one the exec adapter's prepare gave)"
fi

if case_is "control directory: removed on exit 0 before the batch is renamed DONE_, and on Ctrl-C"; then
  repo="$WORK/ctl-done"; ctl_repo "$repo" 2
  mkdir -p "$repo/batch/.foreman-run"; printf 'what the app captured\n' > "$repo/batch/.foreman-run/out"
  run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "every ticket lands: exit 0"
  [ -e "$repo/batch" ] && fail "the batch is renamed" || pass
  # Had the directory been removed after the rename it would have been looked for under the old name,
  # and what the run kept would still be in the renamed batch.
  assert_eq "$(ls -A "$repo/DONE_batch/.foreman-run" 2>/dev/null)" "out" "only out went with the batch"
  repo="$WORK/ctl-done-bare"; ctl_repo "$repo" 2
  run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "(no out) exit 0"
  [ -e "$repo/DONE_batch/.foreman-run" ] && fail "with no out nothing went with the batch" || pass

  # Ctrl-C in the middle of an iteration: the loop's INT handling pauses it (exit 10), the stall marker
  # stays for the next run's review, and the directory goes like any other end.
  repo="$WORK/ctl-int"; ctl_repo "$repo" 2
  mkdir -p "$repo/batch/.foreman-run"; printf 'what the app captured\n' > "$repo/batch/.foreman-run/out"
  run_foreman_env "$repo" "FOREMAN_FAKE_BEHAVIOUR=interrupt-dirty" run batch --unlimited
  assert_eq "$ST" 10 "interrupted: paused, as Ctrl-C does"
  [ -f "$repo/batch/.foreman-stall-marker" ] && pass || fail "interrupted: the stall marker stays"
  assert_eq "$(ls -A "$repo/batch/.foreman-run")" "out" "interrupted: only out is left"
fi

if case_is "foreman keys: + raises the budget of a loop in flight, - and L do what the keys do, and the run follows"; then
  repo="$WORK/keys-run"; ctl_repo "$repo" 4
  ctl="$repo/batch/.foreman-run"
  BG_ENV=(FOREMAN_FAKE_SLEEP=3); bg_run "$repo" batch 1
  wait_until 30 file_is "$ctl/iteration" 1 && pass || fail "the run is at iteration 1"

  run_foreman "$repo" keys batch +
  assert_eq "$ST" 0 "+: exits 0"
  assert_eq "$(cat "$ctl/budget")" 2 "+: the budget is 2"
  assert_contains "$ERR" "iterations: 1 of 2" "+: says what it did"

  # status --json sees the run as it is now.
  run_foreman "$repo" status batch --json
  assert_eq "$(jv "$OUT" 'j.run.in_flight')" true "status --json: in flight"
  assert_eq "$(jv "$OUT" "j.run.id")" "\"$(cut -d' ' -f1 "$ctl/run")\"" "status --json: the run's id"
  assert_eq "$(jv "$OUT" 'j.run.started_at')" "\"$(cut -d' ' -f2 "$ctl/run")\"" "status --json: and its start"
  assert_eq "$(jv "$OUT" 'j.run.iteration')" 1 "status --json: the iteration"
  assert_eq "$(jv "$OUT" 'j.run.budget')" 2 "status --json: the budget as the key made it"
  assert_eq "$(jv "$OUT" 'j.run.live')" false "status --json: live"
  assert_eq "$(jv "$OUT" 'j.run.control_dir')" '"batch/.foreman-run"' "status --json: the control directory"
  assert_eq "$(jv "$OUT" 'j.run.pid.msys')" "$(cut -d' ' -f1 "$ctl/pid")" "status --json: the pid"

  run_foreman "$repo" keys batch + + -
  assert_eq "$ST" 0 "+ + - as three arguments: exits 0"
  assert_eq "$(cat "$ctl/budget")" 3 "the budget is 3"
  run_foreman "$repo" keys batch L
  assert_eq "$(cat "$ctl/live")" 1 "L: live view on"
  assert_contains "$ERR" "live view on" "L: says so"

  bg_wait
  assert_eq "$BG_ST" 10 "the run pauses at the budget the keys left it"
  assert_contains "$BG_OUT" "iterations run:        3" "and ran three iterations"
  assert_contains "$(cat "$repo/batch/foreman-runs.log")" "iteration budget changed: 1 → 3 (after iteration 1)" "the log says the budget changed, as it does for the keys"

  # With nothing in flight status says so, and the run was alone in its directory.
  run_foreman "$repo" status batch --json
  assert_eq "$(jv "$OUT" 'j.run.in_flight')" false "status --json: not in flight after"
  assert_eq "$(jv "$OUT" 'JSON.stringify([j.run.id, j.run.iteration, j.run.budget, j.run.live, j.run.control_dir, j.run.pid])')" '"[null,null,null,null,null,null]"' "and the rest is null"
fi

if case_is "foreman keys: no run in flight, a directory not in the batch, a dead run and a key that is not one are one line and exit 1"; then
  repo="$WORK/keys-none"; ctl_repo "$repo" 2
  run_foreman "$repo" keys batch +
  assert_eq "$ST" 1 "no run: exits 1"
  assert_contains "$ERR" "foreman keys: no run in flight in batch" "no run: says so"
  assert_eq "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" 1 "no run: in one line"
  assert_eq "$OUT" "" "no run: and prints nothing to stdout"

  # A run that died with its directory: the pid is not alive.
  sleep 0 & dead=$!; wait "$dead"
  mkdir -p "$repo/batch/.foreman-run"
  printf '3\n' > "$repo/batch/.foreman-run/budget"; printf '%s %s\n' "$dead" "$dead" > "$repo/batch/.foreman-run/pid"
  run_foreman "$repo" keys batch +
  assert_eq "$ST" 1 "a dead run: exits 1"
  assert_eq "$(cat "$repo/batch/.foreman-run/budget")" 3 "a dead run: its files are not touched"
  run_foreman "$repo" status batch --json
  assert_eq "$(jv "$OUT" 'j.run.in_flight')" false "status --json: a dead run is not in flight"
  assert_eq "$(jv "$OUT" 'j.run.control_dir')" null "status --json: and has no control directory to show"

  # A run that keeps its directory outside the batch: the repo does not ignore the name.
  repo="$WORK/keys-plain"; ctl_repo "$repo" 2 plain
  run_foreman "$repo" keys batch +
  assert_eq "$ST" 1 "a directory outside the batch: exits 1"
  assert_contains "$ERR" ".foreman-run/ in .gitignore" "it says what the batch lacks"

  run_foreman "$repo" keys batch x
  assert_eq "$ST" 1 "an unknown key: exits 1"
  assert_contains "$ERR" "not 'x'" "it names it"
  run_foreman "$repo" keys batch
  assert_eq "$ST" 1 "no key: exits 1"
  assert_contains "$ERR" "Usage: foreman keys <batch>" "with the usage"
  run_foreman "$repo" keys nowhere +
  assert_eq "$ST" 1 "no such batch: exits 1"
  assert_contains "$ERR" "no such directory: nowhere" "and says that"
fi

if case_is "foreman stop: the run finishes the iteration in flight and ends with exit 10, budget reached"; then
  repo="$WORK/stop-run"; ctl_repo "$repo" 3
  ctl="$repo/batch/.foreman-run"
  BG_ENV=(FOREMAN_FAKE_SLEEP=2); bg_run "$repo" batch 3
  wait_until 30 file_is "$ctl/iteration" 1 && pass || fail "the run is at iteration 1"
  # The one batch in the repository, so it need not be named.
  run_foreman "$repo" stop
  assert_eq "$ST" 0 "stop: exits 0"
  assert_eq "$(cat "$ctl/budget")" 1 "the budget is the iteration in flight"
  assert_contains "$ERR" "stops after this iteration (1 of 1)" "and it says so"
  bg_wait
  assert_eq "$BG_ST" 10 "the run ends paused"
  assert_contains "$BG_OUT" "PAUSED: iteration budget reached (1)" "with 'budget reached'"
  assert_contains "$BG_OUT" "iterations run:        1" "after the one iteration"
  assert_eq "$(grep -c . "$repo/batch/foreman-runs.jsonl")" 1 "and that one is in the record"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "nothing is left in the tree"

  # From an unlimited run, and named; and the budget is never lowered under the iteration running.
  repo="$WORK/stop-unlimited"; ctl_repo "$repo" 4
  ctl="$repo/batch/.foreman-run"
  BG_ENV=(FOREMAN_FAKE_SLEEP=2); bg_run "$repo" batch --unlimited
  wait_until 30 file_is "$ctl/iteration" 2 && pass || fail "the unlimited run reached iteration 2"
  run_foreman "$repo" stop batch
  assert_eq "$ST" 0 "stop <batch>: exits 0"
  assert_eq "$(cat "$ctl/budget")" 2 "the budget is the iteration in flight, 2"
  run_foreman "$repo" stop batch
  assert_eq "$(cat "$ctl/budget")" 2 "a second stop leaves it there"
  bg_wait
  assert_eq "$BG_ST" 10 "the unlimited run pauses too"
  assert_contains "$BG_OUT" "iterations run:        2" "after two iterations"

  # No run, and the part that is ticket 09's.
  run_foreman "$repo" stop batch
  assert_eq "$ST" 1 "no run in flight: exits 1"
  assert_contains "$ERR" "foreman stop: no run in flight in batch" "in one line, saying so"
  run_foreman "$repo" stop --now batch
  assert_eq "$ST" 1 "stop --now with no run in flight: exits 1"
  assert_contains "$ERR" "foreman stop: no run in flight in batch" "and says so, as stop does"
  run_foreman "$repo" stop --soon batch
  assert_eq "$ST" 1 "an unknown option: exits 1"
  assert_contains "$ERR" "Usage: foreman stop [<batch>] [--now]" "with the usage"
fi

# A run started the way the desktop app starts it: its own session (`detached`), no console
# (`windowsHide`), stdin ignored, output to a file. $WORK/det.st holds its exit status once it is over.
# The run's own SIGINT is the default one, as it is under the app (a `&` in a script would ignore it).
DET_ENV=()
det_run() {    # det_run REPO RUN-ARGS...
  local repo="$1"; shift
  rm -f "$WORK/det.st" "$WORK/det.out"
  env FOREMAN_SHOW=never FOREMAN_COLOR=never ${DET_ENV[@]+"${DET_ENV[@]}"} \
    node -e '
      const { spawn } = require("child_process"), fs = require("fs");
      const [repo, foreman, st, out, ...args] = process.argv.slice(1);
      const fd = fs.openSync(out, "w");
      const p = spawn(foreman, ["run", ...args], { cwd: repo, detached: true, windowsHide: true, stdio: ["ignore", fd, fd] });
      p.on("exit", (code, sig) => fs.writeFileSync(st, String(code === null ? 128 : code) + "\n"));
    ' "$repo" "$FOREMAN" "$WORK/det.st" "$WORK/det.out" "$@" &
  DET_PID=$!
}
det_wait() {
  wait_until 60 test -s "$WORK/det.st"
  DET_ST="$(cat "$WORK/det.st" 2>/dev/null)"
  DET_OUT="$(cat "$WORK/det.out" 2>/dev/null)"
  wait "$DET_PID" 2>/dev/null
  rm -f "$WORK"/foreman-fake-*.calls
}
# Whether anything is left of a hung agent: its `sleep`, tagged by the length of the wait.
agent_left() { pgrep -f "sleep $1\$" >/dev/null 2>&1; }
feed_left() { pgrep -f "foreman-stream.cjs.*$1" >/dev/null 2>&1; }

if case_is "foreman stop --now: a detached run in the middle of a turn ends as Ctrl-C ends it, and the next run reviews it"; then
  # What Ctrl-C leaves, for the footer to be compared against.
  repo="$WORK/now-int"; ctl_repo "$repo" 2
  run_foreman_env "$repo" "FOREMAN_FAKE_BEHAVIOUR=interrupt-dirty" run batch --unlimited
  assert_eq "$ST" 10 "Ctrl-C: paused"
  int_footer="$(printf '%s\n' "$OUT" | sed -n '/^PAUSED:/,$p')"
  int_warn="$(printf '%s\n' "$ERR" | grep -c 'Interrupt received')"

  repo="$WORK/now-run"; ctl_repo "$repo" 2
  ctl="$repo/batch/.foreman-run"
  DET_ENV=(FOREMAN_FAKE_BEHAVIOUR=hang-dirty FOREMAN_FAKE_HANG=731 FOREMAN_STOP_GRACE=3)
  det_run "$repo" batch --unlimited
  wait_until 30 test -f "$repo/.foreman-fake-leftover" && pass || fail "the agent is mid-turn, with work in the tree"
  agent_left 731 && pass || fail "the agent's process is running"
  base="$(git -C "$repo" rev-parse HEAD)"

  run_foreman "$repo" stop --now
  assert_eq "$ST" 0 "stop --now: exits 0 once the run is over"
  assert_contains "$OUT$ERR" "foreman stop: stopped the run in batch" "and says so"
  det_wait
  assert_eq "$DET_ST" 10 "the run's exit code is Ctrl-C's: paused, 10"
  assert_contains "$DET_OUT" "PAUSED: interrupted (Ctrl-C)" "the footer says it was interrupted"
  assert_contains "$DET_OUT" "Interrupt received" "the loop's own INT handling ran"
  assert_eq "$(printf '%s\n' "$DET_OUT" | grep -c 'Interrupt received')" "$int_warn" "once, as Ctrl-C prints it"
  assert_contains "$DET_OUT" "the rerun has an agent review it and commits it as wip" "the footer promises the review"
  stop_footer="$(printf '%s\n' "$DET_OUT" | sed -n '/^PAUSED:/,$p')"
  assert_eq "${stop_footer//batch\/foreman-runs/X}" "${int_footer//batch\/foreman-runs/X}" "from PAUSED on, the footer is Ctrl-C's word for word"
  [ -f "$repo/batch/.foreman-stall-marker" ] && pass || fail "the stall marker stays"
  assert_contains "$(cat "$repo/batch/.foreman-stall-marker")" "$base" "and it names the base the turn began from"
  assert_contains "$(cat "$repo/.foreman-fake-leftover")" "half-written" "the work tree keeps the ticket's uncommitted work"
  assert_eq "$(ls -A "$ctl" 2>/dev/null)" "" "the control directory is gone"
  agent_left 731 && fail "no agent process is left" || pass
  feed_left "$WORK" && fail "no feed process is left" || pass
  assert_eq "$(grep -c . "$repo/batch/foreman-runs.jsonl")" 1 "the interrupted iteration is recorded"

  # The next run opens with a review turn, as after Ctrl-C.
  log="$WORK/now-prompts.txt"
  FOREMAN_FAKE_PROMPT_LOG="$log" FOREMAN_FAKE_BEHAVIOUR=land run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "the next run finishes the batch"
  assert_contains "$OUT" "reviewed and salvaged by a checkpoint turn" "after a review turn"
  first="$(awk '/^===== fake prompt checkpoint /{f=1;next} /^===== fake prompt /{f=0} f' "$log")"
  assert_contains "$first" "REVIEW CHECKPOINT TURN" "which was the review turn, not the stall's"
  assert_eq "$(git -C "$repo" status --porcelain)" "" "and the tree ends clean"
fi

if case_is "foreman stop --now: a run whose SIGINT is ignored is stopped by the stop file and by ending its agent"; then
  # A loop started by `&` from a script cannot trap INT at all, so the signal does nothing. The
  # stop file is what the loop checks when its agent is gone, and the agent is ended from outside.
  repo="$WORK/now-ign"; ctl_repo "$repo" 2
  ctl="$repo/batch/.foreman-run"
  BG_ENV=(FOREMAN_FAKE_BEHAVIOUR=hang-dirty FOREMAN_FAKE_HANG=732 FOREMAN_STOP_GRACE=2); bg_run "$repo" batch --unlimited
  wait_until 30 test -f "$repo/.foreman-fake-leftover" && pass || fail "the agent is mid-turn"
  run_foreman "$repo" stop --now batch
  assert_eq "$ST" 0 "exits 0"
  bg_wait
  assert_eq "$BG_ST" 10 "the run is paused, as by Ctrl-C"
  assert_contains "$BG_OUT" "PAUSED: interrupted (Ctrl-C)" "with the same footer"
  [ -f "$repo/batch/.foreman-stall-marker" ] && pass || fail "the stall marker stays"
  agent_left 732 && fail "no agent process is left" || pass
fi

if case_is "a stop file in the control directory pauses the run as Ctrl-C does, and nothing else sees it"; then
  repo="$WORK/now-file"; ctl_repo "$repo" 3
  run_foreman_env "$repo" "FOREMAN_FAKE_BEHAVIOUR=stop-file-dirty" run batch --unlimited
  assert_eq "$ST" 10 "paused"
  assert_contains "$OUT" "PAUSED: interrupted (Ctrl-C)" "as Ctrl-C"
  assert_contains "$ERR" "Interrupt received" "the same words"
  [ -f "$repo/batch/.foreman-stall-marker" ] && pass || fail "the stall marker stays"
  assert_eq "$(ls -A "$repo/batch/.foreman-run" 2>/dev/null)" "" "the control directory is cleared, the stop file with it"
  # During a checkpoint turn: what Ctrl-C does there is today's stall path (the loop does not read its
  # flag until the next iteration), and a stop file is read at the same place, so it ends the same
  # way, with the same warning. Not better than Ctrl-C, not worse.
  repo="$WORK/now-checkpoint"; ctl_repo "$repo" 2
  run_foreman_env "$repo" "FOREMAN_FAKE_BEHAVIOUR=dirty FOREMAN_FAKE_CHECKPOINT_BEHAVIOUR=fail" run batch --unlimited
  plain_st="$ST"; plain_err="$ERR"
  repo="$WORK/now-checkpoint-stop"; ctl_repo "$repo" 2
  run_foreman_env "$repo" "FOREMAN_FAKE_BEHAVIOUR=dirty FOREMAN_FAKE_CHECKPOINT_BEHAVIOUR=stop-file" run batch --unlimited
  assert_eq "$ST" "$plain_st" "stopped during the checkpoint turn: the exit code of an unsalvaged stall, as with Ctrl-C"
  assert_contains "$ERR" "Interrupt received" "with the interrupt noted, as Ctrl-C notes it"
  assert_missing "$plain_err" "Interrupt received" "(and not without a stop)"
  repo="$WORK/now-file"
  # Not the next run: a leftover stop file is cleared with the directory.
  mkdir -p "$repo/batch/.foreman-run"; : > "$repo/batch/.foreman-run/stop"
  run_foreman_env "$repo" "FOREMAN_FAKE_BEHAVIOUR=land" run batch --unlimited
  assert_eq "$ST" 0 "a stop file left by a dead run does not stop the next"
fi

if case_is "# reason: a stop for a human gives its one-line reason in the log, for a red flag and for a login that expired"; then
  # A red flag: the review turn of the next run refuses a stopped run's leftover work.
  repo="$WORK/reason-redflag"; ctl_repo "$repo" 2 plain
  run_foreman_env "$repo" "FOREMAN_FAKE_BEHAVIOUR=limit-dirty" run batch --unlimited
  run_foreman_env "$repo" "FOREMAN_FAKE_BEHAVIOUR=land FOREMAN_FAKE_CHECKPOINT_BEHAVIOUR=reject" run batch --unlimited
  assert_eq "$ST" 20 "a refusal stops for a human"
  log="$(cat "$repo/batch/foreman-runs.log")"
  tail_lines="$(printf '%s\n' "$log" | grep -n -A1 '^# stopped: needs a human$' | tail -2)"
  assert_contains "$tail_lines" "# stopped: needs a human" "the log says it stopped"
  reason="$(printf '%s\n' "$log" | sed -n 's/^# reason: //p' | tail -1)"
  assert_contains "$reason" "The review turn refused to commit batch/issues/01-ticket.md's leftover work:" "red flag: the reason is the line the terminal printed"
  assert_contains "$reason" "changes outside the ticket's scope" "red flag: with the reviewer's own words"
  assert_eq "$(printf '%s' "$reason" | wc -l | tr -d ' ')" 0 "red flag: on one line"
  assert_eq "$(printf '%s\n' "$log" | grep -A1 '^# stopped: needs a human$' | tail -1 | cut -c1-9)" "# reason:" "it follows `# stopped: needs a human` directly"
  run_foreman "$repo" status batch --json
  assert_eq "$(jv "$OUT" 'j.last_run.end')" '"needs_human"' "status --json: the run ended needing a human"
  assert_eq "$(jv "$OUT" 'j.last_run.reason')" "$(jv "$(printf '{"r":%s}' "$(printf '%s' "$reason" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(s)))')")" 'j.r')" "status --json: and the reason is what the log holds"

  # A login that expired.
  repo="$WORK/reason-auth"; ctl_repo "$repo" 2 plain
  run_foreman_env "$repo" "FOREMAN_FAKE_BEHAVIOUR=auth FOREMAN_TICKET_ATTEMPTS=3" run batch --unlimited
  assert_eq "$ST" 20 "an expired login stops for a human"
  log="$(cat "$repo/batch/foreman-runs.log")"
  assert_eq "$(printf '%s\n' "$log" | grep -A1 '^# stopped: needs a human$' | tail -1)" \
    "# reason: batch/issues/01-ticket.md was not attempted: the agent could not authenticate (its login has expired or was revoked). Retrying cannot help, so the run stops here." \
    "auth_failed: the reason is the sentence the terminal printed, on one line"
  run_foreman "$repo" status batch --json
  assert_contains "$(jv "$OUT" 'j.last_run.reason')" "the agent could not authenticate" "status --json: last_run.reason"

  # The other ends have no reason line.
  repo="$WORK/reason-none"; ctl_repo "$repo" 2 plain
  run_foreman "$repo" run batch --unlimited
  assert_eq "$ST" 0 "a finished batch"
  assert_missing "$(cat "$repo/DONE_batch/foreman-runs.log")" "# reason:" "complete: no reason line"
fi

if case_is "feed: foreman-stream.cjs keeps the calls the live view shows, only while the view is on"; then
  dir="$WORK/feed-unit"; mkdir -p "$dir"
  call() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":%s}]}}\n' "$1" "$2"; }
  {
    call Read '{"file_path":"src/quiet-read.js"}'
    call Write '{"file_path":"src/foo.js","content":"SECRET-BODY-CONTENT"}'
    call Bash '{"command":"npm test -- --run"}'
    printf '{"type":"result","subtype":"success","result":"done"}\n'
  } > "$dir/events"
  stream() { node "$FOREMAN_HOME/lib/foreman-stream.cjs" "$@" < "$dir/events" > "$dir/payload" 2> "$dir/stderr"; }

  printf '1\n' > "$dir/live"
  stream --live-file "$dir/live" --feed-file "$dir/feed"
  assert_eq "$(wc -l < "$dir/feed" | tr -d ' ')" 2 "live on: a line for each call the view shows (a read is not one)"
  assert_eq "$(sed -E 's/^[0-9]{2}:[0-9]{2}/@T@/' "$dir/feed")" $'@T@ · Write src/foo.js\n@T@ · Bash npm test -- --run' "each is the clock, a dot and the label"
  assert_missing "$(cat "$dir/feed")" "SECRET-BODY-CONTENT" "and never what was written"

  printf '0\n' > "$dir/live"; rm -f "$dir/feed"
  stream --live-file "$dir/live" --feed-file "$dir/feed"
  [ -e "$dir/feed" ] && fail "live off: nothing is written" || pass

  rm -f "$dir/feed"
  stream --live --feed-file "$dir/feed"
  assert_eq "$(wc -l < "$dir/feed" | tr -d ' ')" 2 "--live alone: always on"

  # What it draws and what it passes on are what they were without a feed.
  stream --live; cp "$dir/stderr" "$dir/stderr.plain"; cp "$dir/payload" "$dir/payload.plain"
  stream --live --feed-file "$dir/feed2"
  cmp -s "$dir/stderr" "$dir/stderr.plain" && pass || fail "the feed adds nothing to what is drawn"
  cmp -s "$dir/payload" "$dir/payload.plain" && pass || fail "nor to the payload"

  # A feed that cannot be written to is no reason to stop the run.
  stream --live --feed-file "$dir/no-such-dir/feed"
  cmp -s "$dir/payload" "$dir/payload.plain" && pass || fail "an unwritable feed leaves the payload alone"
fi

if case_is "feed: a --live run writes each iteration's calls to <batch>/.foreman-run/feed, and the next iteration starts it again"; then
  repo="$WORK/feed-run"; ctl_repo "$repo" 2
  ctl="$repo/batch/.foreman-run"
  BG_ENV=(FOREMAN_FAKE_BEHAVIOUR=stream FOREMAN_FAKE_STREAM_PAUSE=3); bg_run "$repo" batch 2 --live
  wait_until 30 bash -c "[ -s '$ctl/feed' ]" && pass || fail "the first iteration's calls are in the feed"
  assert_eq "$(sed -E -e 's/^[0-9]{2}:[0-9]{2}/@T@/' -e 's/y+.*$/Y/' "$ctl/feed")" $'@T@ · Write src/foo.js\n@T@ · Bash npm test -- Y' "the feed holds the calls the live view shows"
  assert_missing "$(cat "$ctl/feed")" "quiet-read" "a read is not one"
  assert_missing "$(cat "$ctl/feed")" "SECRET-BODY" "nor is any of what was written"
  assert_eq "$(cat "$ctl/live")" 1 "live is on, as the run was started"
  # The second iteration starts the file again rather than adding to the first's.
  wait_until 30 file_is "$ctl/iteration" 2 && pass || fail "the run reached iteration 2"
  sleep 1.5
  assert_eq "$(wc -l < "$ctl/feed" | tr -d ' ')" 2 "iteration 2: its own two calls, not four"
  run_foreman "$repo" keys batch L
  assert_eq "$(cat "$ctl/live")" 0 "foreman keys L turns the view off for a run that has no terminal"
  bg_wait
  assert_eq "$BG_ST" 0 "the run lands both tickets"
  [ -e "$repo/DONE_batch/.foreman-run" ] && fail "the feed is gone with the directory" || pass
fi

if case_is "app installed: doctor warns about .foreman-run/, --fix appends it and nothing else, init writes it"; then
  # A repo that is ready as the terminal's doctor sees it: every line but the app's.
  repo="$WORK/app-doctor"; doctor_golden_repo "$repo" ready
  mkdir -p "$WORK/doctor-home"
  OUT="$(cd "$repo" && HOME="$WORK/doctor-home" FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN_NOAPP" doctor 2>&1)"
  assert_missing "$OUT" ".foreman-run" "without the app: doctor does not mention it"
  doctor_with_app() { OUT="$(cd "$1" && HOME="$WORK/doctor-home" FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN_APP" doctor "${@:2}" 2>"$WORK/stderr")"; ST=$?; }
  doctor_with_app "$repo"
  assert_contains "$OUT" ".foreman-run/ not ignored" "with the app: doctor warns when the line is missing"
  doctor_with_app "$repo" --json
  # The row is the same kind as the four other ignore lines are when missing: a thing `--fix` writes.
  assert_eq "$(jv "$OUT" 'JSON.stringify(j.sections.find(s => s.id === "repository").rows.filter(r => r.label === ".foreman-run/ not ignored").map(r => [r.result, r.auto]))')" '"[[\"fail\",true]]"' "--json: a row, fixable by --fix"
  assert_contains "$(jv "$OUT" 'j.plan[0].why')" "1 of 5 lines missing" "--json: the plan counts five lines"
  assert_eq "$(jv "$OUT" 'j.plan[0].text')" "$(jv "$(printf '{"t":%s}' "$(printf '%s\n' '' "# Foreman desktop app: the control directory of a run (its keys, its pid, the live feed), in its batch." '# Disposable, and ignored so that steering a run from the app never shows up as a change.' '**/.foreman-run/' | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(s)))')")" 'j.t')" "--json: the plan is the app's lines alone, not the four it already has"

  before="$(cat "$repo/.gitignore")"
  doctor_with_app "$repo" --fix
  assert_contains "$OUT" "wrote  .gitignore  (+1 pattern(s))" "--fix: says what it wrote"
  assert_eq "$(grep -cxF '**/.foreman-run/' "$repo/.gitignore")" 1 "--fix: the line is in .gitignore"
  assert_eq "$(grep -c 'foreman-runs.log' "$repo/.gitignore")" 1 "--fix: the four lines it already had are not repeated"
  assert_eq "$(head -n "$(printf '%s\n' "$before" | wc -l)" "$repo/.gitignore")" "$before" "--fix: it appended, nothing above changed"
  doctor_with_app "$repo"
  assert_contains "$OUT" ".foreman-run/ ignored" "and doctor is content"
  git -C "$repo" check-ignore -q batch/.foreman-run/pid && pass || fail "git agrees that it is ignored"

  # A repo missing all five: the base block and then the app's, one blank line between.
  repo="$WORK/app-doctor-all"; doctor_golden_repo "$repo" ready; : > "$repo/.gitignore"
  doctor_with_app "$repo" --fix --json
  assert_eq "$(jv "$OUT" 'j.fix.remaining')" 0 "--fix --json: nothing remains"
  assert_eq "$(grep -c '^\*\*/' "$repo/.gitignore")" 5 "all five lines are written"
  assert_contains "$(jv "$OUT" 'j.fix.appended[0].text')" '**/foreman-runs.log\n\n# Foreman desktop app' "the app's comment is set apart from the base block"

  # init: written, said, and not again.
  repo="$WORK/app-init"; copy_fixture "$WORK/template" "$repo" 2
  mkdir -p "$repo/other/issues"; printf '# One\n\n**Status:** todo\n' > "$repo/other/issues/01-one.md"
  git -C "$repo" add -A >/dev/null; git -C "$repo" commit --quiet -m other
  printf 'no-newline-at-the-end' >> "$repo/.gitignore"
  OUT="$(cd "$repo" && FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN_APP" init other --no-order --no-commands 2>&1)"
  assert_contains "$OUT" "updated  .gitignore (+ **/.foreman-run/, so the app can steer a run)" "init: says it"
  assert_eq "$(grep -cxF '**/.foreman-run/' "$repo/.gitignore")" 1 "init: the line is there"
  assert_eq "$(grep -cxF 'no-newline-at-the-end' "$repo/.gitignore")" 1 "init: a file with no final newline keeps its last line whole"
  git -C "$repo" check-ignore -q other/.foreman-run/pid && pass || fail "init: and git ignores it"
  OUT="$(cd "$repo" && FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN_APP" init other --no-order --no-commands 2>&1)"
  assert_missing "$OUT" ".gitignore" "init, again: nothing to say about it"
  assert_eq "$(grep -cxF '**/.foreman-run/' "$repo/.gitignore")" 1 "init, again: and the line is not repeated"
fi

if case_is "golden: without the app, doctor --fix and init print and write exactly what they did"; then
  # doctor and doctor --fix are held by the doctor-*.txt captures above, which run on the copy with
  # no app. This is init, whose capture (test/golden/init-plain.txt) was taken on the tree before
  # the app's line existed, and the proof that no .gitignore is touched.
  repo="$WORK/golden-init"; copy_fixture "$WORK/template" "$repo" 2
  mkdir -p "$repo/other/issues"; printf '# One\n\n**Status:** todo\n' > "$repo/other/issues/01-one.md"
  printf '# Two\n\n**Status:** todo\n' > "$repo/other/issues/02-two.md"
  git -C "$repo" add -A >/dev/null; git -C "$repo" commit --quiet -m other
  ignore_before="$(cat "$repo/.gitignore")"
  (cd "$repo" && FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN_NOAPP" init other --no-order --no-commands > "$WORK/init.out" 2>&1; echo "exit $?" >> "$WORK/init.out")
  if [ "${FOREMAN_JSON_GOLDEN:-}" = write ]; then
    cp "$WORK/init.out" "$TEST_DIR/golden/init-plain.txt"
    printf '  retook test/golden/init-plain.txt\n'
  fi
  cmp -s "$WORK/init.out" "$TEST_DIR/golden/init-plain.txt" && pass || fail "init (no app) differs from test/golden/init-plain.txt"
  assert_eq "$(cat "$repo/.gitignore")" "$ignore_before" "init (no app): .gitignore is untouched"
  # And a machine without the app does not look at it: doctor says nothing of .foreman-run/ however the line stands.
  printf '**/.foreman-run/\n' >> "$repo/.gitignore"
  (cd "$repo" && HOME="$WORK/doctor-home" FOREMAN_SHOW=never FOREMAN_COLOR=never "$FOREMAN_NOAPP" doctor 2>&1) > "$WORK/doctor.noapp"
  assert_missing "$(cat "$WORK/doctor.noapp")" ".foreman-run" "doctor (no app): does not check for the line"
fi

if case_is "golden: foreman help is unchanged by keys and stop, which are commands without a line in it"; then
  (cd "$WORK" && "$FOREMAN" help > "$WORK/help.raw2" 2>&1 < /dev/null)
  sed "s|$FOREMAN_HOME|@FOREMAN_HOME@|g" "$WORK/help.raw2" > "$WORK/help.out2"
  cmp -s "$WORK/help.out2" "$TEST_DIR/golden/help.txt" && pass || fail "foreman help differs from test/golden/help.txt"
  assert_missing "$(cat "$WORK/help.out2")" "foreman keys" "it does not list keys"
fi

# ---------------------------------------------------------------------------
# foreman gui, and doctor's desktop-app line
# ---------------------------------------------------------------------------

# A toolkit with a stub desktop app, or without one: a copy of bin/ and lib/ (the app is looked for
# beside them, as foreman_app_installed does), an install.sh that only logs, and for `app` a stub
# electron.exe that records how it was started — its arguments, directory, whether it was handed a
# terminal, and its session — and then stays a while, as the real one does.
gui_toolkit() {    # gui_toolkit NAME app|noapp : the copy's foreman in $GUI_FOREMAN, its directory in $GUI_TK
  GUI_TK="$WORK/gui-$1"
  mkdir -p "$GUI_TK/gui" && cp -R "$FOREMAN_HOME/bin" "$FOREMAN_HOME/lib" "$GUI_TK/"
  cat > "$GUI_TK/gui/stub-electron.sh" <<'STUB'
#!/bin/bash
{
  echo "ARGS=$*"; echo "CWD=$PWD"
  for fd in 0 1 2; do if [ -t "$fd" ]; then echo "TTY$fd=yes"; else echo "TTY$fd=no"; fi; done
  echo "SID=$(ps -o sid= -p $$ | tr -d ' ')"; echo "AS_NODE=${ELECTRON_RUN_AS_NODE:-unset}"; echo "END"
} > "$FAKE_LOG.tmp" && mv "$FAKE_LOG.tmp" "$FAKE_LOG"
sleep "${FAKE_SLEEP:-0}"
STUB
  cat > "$GUI_TK/install.sh" <<'STUB'
#!/bin/bash
echo "INSTALL $*" >> "$FAKE_LOG.install"
[ "${FAKE_INSTALL_STATUS:-0}" -eq 0 ] || exit "$FAKE_INSTALL_STATUS"
d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gui/node_modules/electron/dist"
mkdir -p "$d" && cp "$(dirname "${BASH_SOURCE[0]}")/gui/stub-electron.sh" "$d/electron.exe" && chmod +x "$d/electron.exe"
STUB
  if [ "$2" = app ]; then
    mkdir -p "$GUI_TK/gui/node_modules/electron/dist"
    cp "$GUI_TK/gui/stub-electron.sh" "$GUI_TK/gui/node_modules/electron/dist/electron.exe"
    chmod +x "$GUI_TK/gui/node_modules/electron/dist/electron.exe"
  fi
  GUI_FOREMAN="$GUI_TK/bin/foreman"
}
# The stub's record, once it has written it (it is started detached, so there is no waiting on it).
gui_stub_started() { grep -qx END "$FAKE_LOG" 2>/dev/null; }
gui_log() { sed -n "s/^$1=//p" "$FAKE_LOG"; }
now_ms() { date +%s%3N; }

if case_is "foreman gui: starts electron.exe on the gui directory and the repo, detached, and returns at once"; then
  gui_toolkit app app
  repo="$WORK/gui-repo"; copy_fixture "$WORK/template" "$repo" 2
  mkdir -p "$repo/batch/deeper"
  repo_top="$(git -C "$repo" rev-parse --show-toplevel)"
  export FAKE_LOG="$WORK/gui-stub.log"; rm -f "$FAKE_LOG"
  t0="$(now_ms)"
  # Its output is captured: a process that kept the terminal's stdout open would hold this until it exits.
  OUT="$(cd "$repo/batch/deeper" && FAKE_SLEEP=6 ELECTRON_RUN_AS_NODE=1 "$GUI_FOREMAN" gui 2>&1 < /dev/null)"; ST=$?
  t1="$(now_ms)"
  assert_eq "$ST" 0 "exit 0"
  assert_eq "$OUT" "" "it prints nothing when it works"
  [ $((t1 - t0)) -lt 2500 ] && pass || fail "foreman gui returned after $((t1 - t0)) ms while the app was still running"
  wait_until 5 gui_stub_started && pass || fail "the stub electron.exe never started"
  assert_eq "$(gui_log ARGS)" "$GUI_TK/gui $repo_top" "electron.exe gets the gui directory and the repo root, not the directory it was run from"
  assert_eq "$(gui_log TTY0)$(gui_log TTY1)$(gui_log TTY2)" "nonono" "the app is handed no terminal"
  assert_eq "$(gui_log AS_NODE)" "unset" "a ELECTRON_RUN_AS_NODE left by another tool does not turn electron into node"
  caller_sid="$(ps -o sid= -p $$ | tr -d ' ')"
  [ -n "$(gui_log SID)" ] && [ "$(gui_log SID)" != "$caller_sid" ] && pass || fail "the app is in its own session (it was in $(gui_log SID), the caller's is $caller_sid)"

  # An explicit directory: the repo that holds it, wherever the shell is.
  rm -f "$FAKE_LOG"
  OUT="$(cd "$WORK" && "$GUI_FOREMAN" gui "$repo/batch" 2>&1 < /dev/null)"; ST=$?
  assert_eq "$ST" 0 "gui <dir>: exit 0"
  wait_until 5 gui_stub_started && pass || fail "gui <dir>: the stub never started"
  assert_eq "$(gui_log ARGS)" "$GUI_TK/gui $repo_top" "gui <dir>: the repo that holds the directory"

  # Outside any repo it opens anyway, on the directory, for the app to say what is wrong with it.
  outside="$WORK/gui-outside"; mkdir -p "$outside"
  rm -f "$FAKE_LOG"
  OUT="$(cd "$outside" && GIT_CEILING_DIRECTORIES="$WORK" "$GUI_FOREMAN" gui 2>&1 < /dev/null)"; ST=$?
  assert_eq "$ST" 0 "outside a repo: exit 0"
  wait_until 5 gui_stub_started && pass || fail "outside a repo: the stub never started"
  assert_eq "$(gui_log ARGS)" "$GUI_TK/gui $outside" "outside a repo: the app gets the directory, so it can show 'not a git repo'"

  # A directory that is not there is refused, and nothing is started.
  rm -f "$FAKE_LOG"
  OUT="$(cd "$repo" && "$GUI_FOREMAN" gui "$WORK/no-such-dir" 2>&1 < /dev/null)"; ST=$?
  assert_eq "$ST" 1 "a missing directory: exit 1"
  assert_contains "$OUT" "no-such-dir" "a missing directory: names it"
  sleep 0.3; [ ! -e "$FAKE_LOG" ] && pass || fail "a missing directory: nothing is started"
  # Too many arguments, or an option nobody knows.
  OUT="$(cd "$repo" && "$GUI_FOREMAN" gui a b 2>&1 < /dev/null)"; assert_eq "$?" 1 "two directories: exit 1"
  assert_contains "$OUT" "Usage: foreman gui [<dir>]" "two directories: the usage"
  OUT="$(cd "$repo" && "$GUI_FOREMAN" gui --nope 2>&1 < /dev/null)"; assert_eq "$?" 1 "an unknown option: exit 1"
  unset FAKE_LOG
fi

if case_is "foreman gui: with no app it says so and exits 1 without a terminal, and at one it offers to install it"; then
  gui_toolkit noapp noapp
  repo="$WORK/gui-noapp-repo"; copy_fixture "$WORK/template" "$repo" 2
  repo_top="$(git -C "$repo" rev-parse --show-toplevel)"
  export FAKE_LOG="$WORK/gui-noapp.log"; rm -f "$FAKE_LOG" "$FAKE_LOG.install"
  OUT="$(cd "$repo" && "$GUI_FOREMAN" gui 2>&1 < /dev/null)"; ST=$?
  assert_eq "$ST" 1 "no terminal: exit 1"
  assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1 "no terminal: one line"
  assert_contains "$OUT" "desktop app is not installed" "no terminal: says so"
  assert_contains "$OUT" "install.sh --gui" "no terminal: and how to install it"
  assert_missing "$OUT" "[y/N]" "no terminal: asks nothing"
  # A terminal on only one side is not a conversation either.
  OUT="$(cd "$repo" && "$GUI_FOREMAN" gui 2>&1 < /dev/null | cat)"
  assert_missing "$OUT" "[y/N]" "stdout piped: asks nothing"
  [ ! -e "$FAKE_LOG.install" ] && pass || fail "nothing is installed without a yes"

  have_script=0; command -v script >/dev/null 2>&1 && have_script=1
  # (The pty stays open half a second after foreman returns: script ends the session the moment its
  # command does, and kills an app that has only just been forked — a terminal does not.)
  at_tty() {    # at_tty ANSWER DIR : foreman gui under a pty, ANSWER typed at the prompt; output in $OUT, status in $ST
    (cd "$2" && printf '%s' "$1" | script -qec "'$GUI_FOREMAN' gui; st=\$?; sleep 0.5; exit \$st" /dev/null > "$WORK/tty.out" 2>&1; exit "${PIPESTATUS[1]}"); ST=$?
    OUT="$(tr -d '\r' < "$WORK/tty.out")"
  }
  if [ "$have_script" -eq 1 ]; then
    # The default is no.
    at_tty $'\n' "$repo"
    assert_contains "$OUT" "[y/N]" "terminal: asks"
    assert_eq "$ST" 1 "terminal, Enter: exit 1"
    assert_contains "$OUT" "desktop app is not installed" "terminal: the same line first"
    [ ! -e "$FAKE_LOG.install" ] && pass || fail "terminal, Enter: nothing is installed"
    at_tty $'n\n' "$repo"
    [ ! -e "$FAKE_LOG.install" ] && pass || fail "terminal, n: nothing is installed"
    sleep 0.3; [ ! -e "$FAKE_LOG" ] && pass || fail "terminal, n: nothing is started"

    # A failed install is a failure, and the app is not started.
    FAKE_INSTALL_STATUS=3 at_tty $'y\n' "$repo"
    assert_eq "$(cat "$FAKE_LOG.install")" "INSTALL --gui" "terminal, y: runs install.sh --gui"
    assert_eq "$ST" 3 "a failed install: the installer's own exit code"
    sleep 0.3; [ ! -e "$FAKE_LOG" ] && pass || fail "a failed install starts nothing"
    rm -f "$FAKE_LOG.install"

    # Yes installs, and then opens the app, as the person asked.
    FAKE_SLEEP=0 at_tty $'y\n' "$repo"
    assert_eq "$(cat "$FAKE_LOG.install")" "INSTALL --gui" "terminal, y: install.sh --gui, once"
    assert_eq "$ST" 0 "terminal, y: exit 0"
    wait_until 5 gui_stub_started && pass || fail "terminal, y: the app opens once it is installed"
    assert_eq "$(gui_log ARGS)" "$GUI_TK/gui $repo_top" "terminal, y: on the repo"
  else
    printf '  (script is not on PATH: the terminal cases are skipped)\n'
  fi
  # A half install — electron's directory without its executable — is the same as none.
  gui_toolkit half noapp; mkdir -p "$GUI_TK/gui/node_modules/electron"
  OUT="$(cd "$repo" && "$GUI_FOREMAN" gui 2>&1 < /dev/null)"; ST=$?
  assert_eq "$ST" 1 "an electron with no executable: exit 1"
  assert_contains "$OUT" "install.sh --gui" "an electron with no executable: says how to repair it"
  unset FAKE_LOG
fi

if case_is "doctor: the desktop app's line is in MACHINE only when the app is installed, in sync or out of date"; then
  mkdir -p "$WORK/doctor-home"
  repo="$WORK/gui-doctor"; doctor_golden_repo "$repo" ready
  gui_doctor() {    # gui_doctor TOOLKIT_FOREMAN [args] : doctor in $repo, in $OUT
    OUT="$(cd "$repo" && HOME="$WORK/doctor-home" FOREMAN_SHOW=never FOREMAN_COLOR=never "$1" doctor "${@:2}" 2>"$WORK/stderr")"; ST=$?
  }
  json_row() { jv "$OUT" "JSON.stringify(j.sections.find(s => s.id === 'machine').rows.filter(r => /desktop app/.test(r.label)).map(r => [r.result, r.label, r.fix, r.auto]))"; }

  # No app: not a word, in either form.
  gui_toolkit none noapp
  gui_doctor "$GUI_FOREMAN"
  assert_missing "$OUT" "desktop app" "no app: plain doctor says nothing of it"
  gui_doctor "$GUI_FOREMAN" --json
  assert_eq "$(json_row)" '"[]"' "no app: doctor --json has no such row"

  # In sync: a lockfile that is not newer than node_modules (or no lockfile at all).
  gui_toolkit sync app
  gui_doctor "$GUI_FOREMAN"
  assert_contains "$OUT" "desktop app installed · in sync" "installed, no lockfile: in sync"
  : > "$GUI_TK/gui/package-lock.json"
  touch -d '2 days ago' "$GUI_TK/gui/package-lock.json"; touch -d '1 day ago' "$GUI_TK/gui/node_modules"
  gui_doctor "$GUI_FOREMAN"
  assert_contains "$OUT" "desktop app installed · in sync" "lockfile older than node_modules: in sync"
  # MACHINE is where the line is: in the left column, beside REPOSITORY's rows.
  assert_contains "$(printf '%s\n' "$OUT" | grep 'desktop app' | head -1)" "│" "the row sits in the MACHINE column, beside REPOSITORY's"
  gui_doctor "$GUI_FOREMAN" --json
  assert_eq "$(json_row)" '"[[\"ok\",\"desktop app installed · in sync\",null,false]]"' "--json: an ok row in machine"

  # Out of date: the lockfile changed after node_modules was made. A warning, never a failure.
  gui_doctor "$FOREMAN_APP" --json; verdict_before="$(jv "$OUT" 'j.verdict.passed')"
  touch "$GUI_TK/gui/package-lock.json"
  touch -d '3 days ago' "$GUI_TK/gui/node_modules"
  gui_doctor "$GUI_FOREMAN"
  # (The box wraps a long row at its column, so the words are looked for as the box breaks them.)
  assert_contains "$OUT" "desktop app installed · out of" "lockfile newer than node_modules: out of date"
  assert_contains "$OUT" "date: rerun install.sh" "...and says what to rerun"
  gui_doctor "$GUI_FOREMAN" --json
  assert_contains "$(json_row)" 'warn' "--json: a warn row"
  assert_contains "$(json_row)" 'out of date: rerun install.sh' "--json: the row's words"
  assert_contains "$(json_row)" 'install.sh --gui' "--json: its fix reruns the installer with --gui"
  assert_eq "$(jv "$OUT" 'j.verdict.passed')" "$verdict_before" "a stale app does not change the verdict"
  assert_eq "$(jv "$OUT" 'j.counts.warn')" 1 "it is one warning"
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

# The recorder, the stream filter and the report, driven as child processes (test/node/).
# A glob, not the directory: `node --test <dir>` reads a directory as a module path.
if case_is "node: node --test over test/node/"; then
  if [ ! -d "$FOREMAN_HOME/test/node" ]; then
    fail "test/node/ is missing"
  elif command -v node >/dev/null 2>&1; then
    node_out="$(cd "$FOREMAN_HOME" && node --test "test/node/*.test.cjs" 2>&1)"
    node_st=$?
    assert_eq "$node_st" 0 "the node scripts' tests pass"
    [ "$node_st" = 0 ] || printf '%s\n' "$node_out" | tail -40 >&2
  else
    printf '  (node is not on PATH: skipped)\n'
  fi
fi

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
