#!/bin/bash
# RALPH_EXEC=local — `claude` in this working tree. No sandbox, no isolation, nothing to
# transport: the agent commits into the tree the loop is already watching.

# shellcheck source=_common.sh
source "$RALPH_EXEC_DIR/_common.sh"

exec_required_tool() { printf 'claude'; }

exec_preflight() { return 0; }
exec_prepare()   { return 0; }

exec_describe() { printf 'local'; }

exec_run() {
  claude \
    --model "$RALPH_MODEL" --effort "$RALPH_EFFORT" --permission-mode "$RALPH_PERMISSION_MODE" \
    ${RALPH_CLAUDE_ARGS+"${RALPH_CLAUDE_ARGS[@]}"} \
    --print --output-format json -p "$1"
}
