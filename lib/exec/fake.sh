#!/bin/bash
# RALPH_EXEC=fake — no agent, no sandbox, no money. Every other adapter needs either a
# model or a container to say anything at all, which is what used to make the loop
# untestable: budget arithmetic, attempt accounting, verdict handling and every stop
# condition could only be exercised by paying for a real run.
#
# This adapter answers the same interface out of thin air. It records each prompt it is
# given and then acts out one scripted outcome, so a test can drive the loop to any of
# its five endings.
#
#   RALPH_FAKE_BEHAVIOUR   what the "agent" does. Default: land.
#     land     flip the ticket's status line to the done word and commit it
#     noop     succeed, change nothing — the ticket does not land
#     dirty    write an uncommitted file and leave it there
#     error    exit non-zero with an error payload
#     transient  exit non-zero with an overloaded_error payload (the loop should retry)
#     limit    print a usage-limit string instead of JSON (the loop should pause)
#     crash    exit non-zero with output that is not JSON and carries no signal at all —
#              indistinguishable from a logic failure, so the loop should NOT retry it
#     context  exit non-zero with an unparseable context-overflow string: the CLI died
#              before it could emit JSON. The loop should retry anyway.
#     context-json  the same failure as the CLI actually reports it — valid JSON with
#              terminal_reason "prompt_too_long". Carries "api_error_status" too, which is
#              why classifying context exhaustion before transient matters.
#   RALPH_FAKE_PROMPT_LOG  file to append each prompt to, with a separator. Optional.
#   RALPH_FAKE_COST        reported cost per iteration in USD. Default 0.01.
#
# The behaviour may also be a `:`-separated list — `noop:land` lands on the second
# attempt — which is how retry accounting gets a test.

# shellcheck source=_common.sh
source "$RALPH_EXEC_DIR/_common.sh"

exec_required_tool() { printf ''; }

exec_preflight() { return 0; }
exec_prepare()   { return 0; }

exec_describe() { printf 'fake (no agent is run)'; }

# The loop calls exec_run inside a command substitution, so the call count cannot live in
# a variable — that subshell's increment would be thrown away. It lives in a file keyed on
# the loop's own PID, which command substitution does not change.
_FAKE_CALLS_FILE="${TMPDIR:-/tmp}/ralph-fake-$$.calls"

_fake_bump() {
  local n=0
  [ -f "$_FAKE_CALLS_FILE" ] && n=$(cat "$_FAKE_CALLS_FILE" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$((n + 1))
  printf '%s' "$n" > "$_FAKE_CALLS_FILE"
  printf '%s' "$n"
}

# The behaviour for call $1: the Nth entry of the `:`-separated list, or the last one once
# the list runs out.
_fake_behaviour() {
  local call="$1" list="${RALPH_FAKE_BEHAVIOUR:-land}" i=0 chosen=""
  local IFS=':'
  # shellcheck disable=SC2086
  set -- $list
  for chosen in "$@"; do
    i=$((i + 1))
    [ "$i" -eq "$call" ] && { printf '%s' "$chosen"; return; }
  done
  printf '%s' "$chosen"
}

# The `claude --output-format json` shape, as much of it as ralph-record.cjs reads.
_fake_payload() {
  local subtype="$1" is_error="$2" result="$3"
  printf '{"type":"result","subtype":"%s","is_error":%s,"session_id":"fake-session",' \
    "$subtype" "$is_error"
  printf '"num_turns":3,"duration_ms":1200,"duration_api_ms":900,"total_cost_usd":%s,' \
    "${RALPH_FAKE_COST:-0.01}"
  printf '"usage":{"input_tokens":1000,"output_tokens":200,'
  printf '"cache_read_input_tokens":5000,"cache_creation_input_tokens":300},'
  printf '"result":"%s"}\n' "$result"
}

# Flip the ticket's status line to the done word, or add one if it has none.
_fake_land() {
  local ticket="$1" tmp
  tmp="$(mktemp)"
  awk -v sl="$RALPH_STATUS_LINE" -v dw="$RALPH_DONE_WORD" '
    index($0, sl) == 1 { print sl " " dw; found = 1; next }
    { print }
    END { if (!found) { print ""; print sl " " dw } }
  ' "$ticket" > "$tmp" && mv "$tmp" "$ticket"
  git add -A >/dev/null 2>&1
  git -c user.name=ralph-fake -c user.email=fake@ralph.invalid \
    commit --quiet -m "fake: land $ticket" >/dev/null 2>&1
}

exec_run() {
  local prompt="$1" ticket="$2" call behaviour
  call="$(_fake_bump)"
  behaviour="$(_fake_behaviour "$call")"

  if [ -n "${RALPH_FAKE_PROMPT_LOG:-}" ]; then
    { printf '===== fake prompt %s (%s) =====\n' "$call" "$ticket"
      printf '%s\n' "$prompt"; } >> "$RALPH_FAKE_PROMPT_LOG"
  fi

  case "$behaviour" in
    land)
      _fake_land "$ticket"
      _fake_payload success false "landed $ticket"
      ;;
    noop)
      _fake_payload success false "did nothing"
      ;;
    dirty)
      printf 'left behind by the fake adapter\n' > .ralph-fake-leftover
      _fake_payload success false "left the tree dirty"
      ;;
    error)
      _fake_payload error_during_execution true "something went wrong"
      return 1
      ;;
    transient)
      printf '{"type":"result","is_error":true,"error":{"type":"overloaded_error"}}\n'
      return 1
      ;;
    limit)
      printf 'Claude AI usage limit reached|%s\n' "$(( $(date +%s) + 3600 ))"
      return 1
      ;;
    crash)
      printf 'claude: unexpected failure, no output\n'
      return 1
      ;;
    context)
      printf 'prompt is too long: 250000 tokens > 200000 maximum\n'
      return 1
      ;;
    context-json)
      # Trimmed from a real payload: `claude --print --output-format json` fed a prompt of
      # ~894k tokens. Note subtype "success" alongside is_error true — the subtype is no
      # help here, terminal_reason is.
      printf '{"type":"result","subtype":"success","is_error":true,'
      printf '"terminal_reason":"prompt_too_long","api_error_status":400,'
      printf '"session_id":"fake-session","num_turns":1,"duration_ms":900,'
      printf '"duration_api_ms":0,"total_cost_usd":0,'
      printf '"usage":{"input_tokens":0,"output_tokens":0,'
      printf '"cache_read_input_tokens":0,"cache_creation_input_tokens":0},'
      printf '"result":"Prompt is too long - the request is ~894261 tokens (limit 200000)."}\n'
      return 1
      ;;
    *)
      warn "fake: unknown RALPH_FAKE_BEHAVIOUR '$behaviour'"
      return 2
      ;;
  esac
}
