#!/bin/bash
# RALPH_EXEC=sandbox-mount — `sbx` bind-mounting this working tree. The agent is isolated
# but the workspace is not a copy, so commits land here directly and there is nothing to
# transport. Fine when the project has no native modules and no install step in the
# sandbox; otherwise use `sandbox`, which is the default for the reasons written there.

# shellcheck source=_common.sh
source "$RALPH_EXEC_DIR/_common.sh"
# shellcheck source=_sbx.sh
source "$RALPH_EXEC_DIR/_sbx.sh"

exec_describe() { printf 'sandbox-mount (sandbox %s)' "$RALPH_SANDBOX"; }

exec_prepare() {
  _sbx_create mount

  # A sandbox left over from the other arrangement is the single most expensive mistake
  # available here: it looks fine and fails every iteration *after* paying for the work.
  if _sbx_is_clone_mode; then
    warn "preflight: sandbox '$RALPH_SANDBOX' is a clone, but RALPH_EXEC=sandbox-mount expects"
    warn "           a bind mount — the agent's commits would never reach this tree."
    warn "           Recreate it:  sbx rm --force $RALPH_SANDBOX"
    return 1
  fi

  _sbx_probe
}
