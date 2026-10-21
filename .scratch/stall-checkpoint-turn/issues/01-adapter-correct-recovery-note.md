# 01: Per-adapter recovery note for uncommitted work

**Status:** done

**Blocked by:** None (can start immediately)

**What to build:**

When a run stops with work left uncommitted in the agent's tree, the instructions it prints
must match the execution mode actually in force, and it must never print two sets of
instructions that contradict each other.

Today the stop prints an adapter-correct paragraph ("they are in the sandbox's clone…") and
then, unconditionally, a generic follow-up telling the operator to run `git add -A && git
commit` and rerun. Under the default clone-based sandbox mode that follow-up finds nothing
to commit — the host tree is clean, the changes are in the clone — so the commit silently
does nothing and the rerun destroys the work. Both blocks come from the same stop, in the
same voice, one after the other.

Move that recovery text into the exec seam as a question an adapter answers, the way the
existing stranded-work note already is. The working-tree modes keep today's
commit-and-rerun advice. Both sandbox modes instead describe committing inside the sandbox
and transporting the commit back out — the same transport the clone adapter already
performs internally when it collects an iteration's commits. Keep this distinct from the
existing note for work that was committed but could not be brought back: two different
failures, two messages.

The note must also be askable of a mode that is not currently running, joining the existing
family of single-question adapter helpers, so each mode's text can be asserted without that
mode's runtime.

**Acceptance criteria:**

- [x] The uncommitted-work recovery text is supplied by the exec adapter, not hardcoded in
      the loop, and the loop asks for it rather than choosing it
- [x] Working-tree modes print commit-and-rerun advice; the clone-based sandbox mode prints
      commit-inside-the-sandbox-and-transport-it-out advice (see comment below — only
      `sandbox` gets the transport text, not `sandbox-mount` too)
- [x] A stop never prints one mode's advice alongside another's
- [x] The existing note for committed-but-stranded work is unchanged and still distinct
- [x] Any adapter's recovery text can be obtained without running that adapter
- [x] Smoke covers each mode's text, and the existing dirty-tree case still passes unchanged
      apart from the corrected wording

## Comments

Implemented in `19f9076`. One deliberate deviation from this ticket's literal wording:
"both sandbox modes" (criterion 2) was read as `sandbox` and `sandbox-mount` sharing the
commit-inside-and-transport text. That turned out to be wrong for `sandbox-mount` — it
bind-mounts this working tree rather than cloning it, so an uncommitted change is already
sitting in this repo (same filesystem, not a copy; confirmed by `sandbox-mount.sh`'s own
header comment and by `exec_collect`'s dirty check, which for that mode runs `git status`
on the host directly, not inside the sandbox). Telling the operator to bundle, `sbx cp`,
fetch and merge something that never left would be actively misleading, not just verbose.
A background `/code-review` pass reproduced this by running
`foreman_exec_dirty_recovery_note sandbox-mount ...` directly and confirmed the wrong text
came out. Fixed so `sandbox-mount` gets the same plain advice as `local`/`fake` via
`_common.sh`, and only `sandbox` (the actual clone adapter) gets the transport text, now
shared with the pre-existing stranded-work note via a `_sbx_recover_bundle_lines` helper
so the two can't drift apart. Full smoke suite: 166 passed, 0 failed.
