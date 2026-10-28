#!/bin/bash
# Has an agent fill in a batch's command slots in foreman.conf — FOREMAN_CHECK_CMD,
# FOREMAN_TEST_CMD, FOREMAN_FOCUSED_TEST_CMD, FOREMAN_SANDBOX_SETUP and FOREMAN_SANDBOX_PROBE —
# from what the repo itself shows: its CI, its task runners, its docs.
#
#   foreman commands <batch>
#
# Runs automatically in `foreman init`, right after it writes foreman.conf. Re-run it by hand
# after commenting a slot back out.
#
# The work is the foreman-conf-commands skill, which install.sh puts in
# ${CLAUDE_CONFIG_DIR:-~/.claude}/skills; this script only runs it headless, as
# `/foreman-conf-commands <batch>`. The skill is user-invoked only, so its description costs
# no context in any other chat — a slash command in the prompt is how this reaches it.
#
# Fills only slots that are still commented out: a set line, even an empty one, is a
# person's decision and is kept. The only file it writes is <batch>/foreman.conf, and it
# commits nothing. Runs locally, never in a sandbox, for the same reason `foreman order` does.
#
# Costs one model call, on FOREMAN_ORDERING_MODEL when set (else FOREMAN_MODEL) — the same
# small one-off job as ordering. If `claude` is not on PATH, or the skill is not installed,
# this prints a note and exits 0 rather than failing whatever called it — the slots just stay
# commented out for you to fill in.
set -uo pipefail

# This file's directory, from the shell and not `dirname` (see foreman-config.sh).
FOREMAN_TOOL_DIR="${BASH_SOURCE[0]%/*}"; [ "$FOREMAN_TOOL_DIR" != "${BASH_SOURCE[0]}" ] || FOREMAN_TOOL_DIR=.
FOREMAN_TOOL_DIR="$(cd "${FOREMAN_TOOL_DIR:-/}" && pwd)"

show_help() { awk 'NR==1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; }

BATCH_INPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) show_help; exit 0 ;;
    -*) echo "Usage: foreman commands <batch>" >&2; exit 1 ;;
    *) BATCH_INPUT="$1" ;;
  esac
  shift
done
[ -n "$BATCH_INPUT" ] || { echo "Usage: foreman commands <batch>" >&2; exit 1; }

# Same resolution as `foreman order`: BATCH_DIR, REPO_ROOT (now the working directory) and
# the model knobs, from env, then this batch's foreman.conf, then defaults.
export FOREMAN_BATCH="$BATCH_INPUT"
# shellcheck source=foreman-config.sh
source "$FOREMAN_TOOL_DIR/foreman-config.sh" || exit 1

TAG="foreman commands:"
INDENT="                  "
CONF="$BATCH_DIR/foreman.conf"
SKILL_NAME="foreman-conf-commands"
SLOTS=(FOREMAN_CHECK_CMD FOREMAN_TEST_CMD FOREMAN_FOCUSED_TEST_CMD FOREMAN_SANDBOX_SETUP FOREMAN_SANDBOX_PROBE)

# The skill fills in a conf, it never creates one — and a batch still on ralph.conf has to be
# renamed first, or the agent would be told to edit a file that is not there.
[ -f "$CONF" ] || {
  warn_tag error "$TAG" "$CONF does not exist — run: foreman init $BATCH_DIR"
  exit 1
}

# A slot is set when it has an uncommented assignment line. Read from the file, not from the
# environment: an exported FOREMAN_TEST_CMD is this shell's, not the batch's.
unset_slots() {
  local s
  for s in "${SLOTS[@]}"; do
    grep -qE "^[[:space:]]*(export[[:space:]]+)?$s=" "$CONF" || printf '%s\n' "$s"
  done
}

if [ -z "$(unset_slots)" ]; then
  say_tag accent "$TAG" "every command slot in $CONF is already set — nothing to fill in."
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  warn_tag error "$TAG" "'claude' is not on PATH — skipping."
  echo "${INDENT}fill in the command slots of $CONF by hand, or re-run \`foreman commands $BATCH_DIR\` once it is." >&2
  exit 0
fi

# Claude Code finds a skill in the user's config dir or in the repo's own .claude/skills —
# install.sh puts it in the first. Without it the slash command is just text, and the agent
# would improvise; better to say so and leave the slots alone.
if [ ! -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/$SKILL_NAME/SKILL.md" ] &&
   [ ! -f "$REPO_ROOT/.claude/skills/$SKILL_NAME/SKILL.md" ]; then
  warn_tag error "$TAG" "the $SKILL_NAME skill is not installed — skipping."
  echo "${INDENT}run: bash $FOREMAN_HOME/install.sh   then: foreman commands $BATCH_DIR" >&2
  exit 0
fi

# Effort stays high regardless of FOREMAN_EFFORT, as for ordering: a wrong test command makes
# every iteration of the run fail its own verification.
MODEL="${FOREMAN_ORDERING_MODEL:-$FOREMAN_MODEL}"
EFFORT=high

say_tag accent "$TAG" "looking for this repo's check and test commands ..."

# Git Bash rewrites an argument that starts with / into a Windows path before handing it to a
# native program: claude.exe would get `C:/Program Files/Git/foreman-conf-commands batch` and
# never see a slash command. These two turn that off (Git for Windows reads the first, MSYS2
# the second) and are inert everywhere else. stdin is closed because claude, finding it is not
# a terminal, otherwise waits for input that never comes.
RESPONSE=$(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
  claude --model "$MODEL" --effort "$EFFORT" --permission-mode acceptEdits \
  --print --output-format json -p "/$SKILL_NAME $BATCH_DIR" </dev/null)
status=$?

{ IFS= read -r is_error; IFS= read -r cost; IFS= read -r said; IFS= read -r auth_failed; } < <(
  node "$FOREMAN_TOOL_DIR/foreman-claude-reply.cjs" <<< "$RESPONSE")

if [ "$status" -ne 0 ] || [ "$is_error" = 1 ]; then
  warn_tag error "$TAG" "the agent call failed (exit $status) — fill in $CONF by hand."
  [ -n "$said" ] && echo "${INDENT}claude said: $said"
  [ "$auth_failed" = 1 ] && echo "${INDENT}your claude login has expired — run \`claude /login\`, then re-run \`foreman commands $BATCH_INPUT\`."
  exit 1
fi

# Every later foreman command sources this file, so an edit that broke it would surface
# far from its cause. Catch it here instead.
if ! bash -n "$CONF" 2>/dev/null; then
  warn_tag error "$TAG" "$CONF no longer parses after the agent's edit — fix it before running:"
  bash -n "$CONF" 2>&1 | sed "s/^/${INDENT}/" >&2
  exit 1
fi

# The conf is the record of what happened, not the agent's own summary of it.
say_tag accent "$TAG" "updated $CONF${cost:+ (cost \$$cost)}"
missing="$(unset_slots)"
for s in "${SLOTS[@]}"; do
  if printf '%s\n' "$missing" | grep -qx "$s"; then
    echo "${INDENT}left empty  $s"
  else
    echo "${INDENT}$(grep -E "^[[:space:]]*(export[[:space:]]+)?$s=" "$CONF" | tail -n 1)"
  fi
done
echo "${INDENT}review them — each comes with a comment naming the file it was read from."
exit 0
