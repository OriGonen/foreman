#!/bin/bash
# RALPH_EXEC=local — `claude` in this working tree. No sandbox, no isolation, nothing to
# transport: the agent commits into the tree the loop is already watching.

# shellcheck source=_common.sh
source "$RALPH_EXEC_DIR/_common.sh"

exec_required_tool() { printf 'claude'; }

# No isolation here, so the permission gate is the only check left standing. Keep it — and
# see ralph.conf.template's RALPH_CLAUDE_ARGS for why a git allowlist has to come with it.
exec_default_permission_mode() { printf 'acceptEdits'; }

exec_preflight() { return 0; }
exec_prepare()   { return 0; }

exec_describe() { printf 'local'; }

exec_run() {
  ralph_exec_format_args
  env "$(ralph_exec_agent_env)" claude \
    --model "$RALPH_MODEL" --effort "$RALPH_EFFORT" --permission-mode "$RALPH_PERMISSION_MODE" \
    ${RALPH_CLAUDE_ARGS+"${RALPH_CLAUDE_ARGS[@]}"} \
    --print "${RALPH_EXEC_FORMAT_ARGS[@]}" -p "$1"
}
