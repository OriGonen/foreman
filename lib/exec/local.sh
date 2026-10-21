#!/bin/bash
# FOREMAN_EXEC=local — `claude` in this working tree. No sandbox, no isolation, nothing to
# transport: the agent commits into the tree the loop is already watching.

# shellcheck source=_common.sh
source "$FOREMAN_EXEC_DIR/_common.sh"

exec_required_tool() { printf 'claude'; }

# No isolation here, so the permission gate is the only check left standing. Keep it — and
# see foreman.conf.template's FOREMAN_CLAUDE_ARGS for why a git allowlist has to come with it.
exec_default_permission_mode() { printf 'acceptEdits'; }

exec_preflight() { return 0; }
exec_prepare()   { return 0; }

exec_describe() { printf 'local'; }

exec_run() {
  foreman_exec_format_args
  env "$(foreman_exec_agent_env)" claude \
    --model "$FOREMAN_MODEL" --effort "$FOREMAN_EFFORT" --permission-mode "$FOREMAN_PERMISSION_MODE" \
    ${FOREMAN_CLAUDE_ARGS+"${FOREMAN_CLAUDE_ARGS[@]}"} \
    --print "${FOREMAN_EXEC_FORMAT_ARGS[@]}" -p "$1"
}
