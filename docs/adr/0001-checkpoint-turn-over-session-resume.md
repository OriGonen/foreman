---
status: accepted
---

# A stalled turn is salvaged by a fresh checkpoint turn, not by resuming its session

When a turn stalls — ends cleanly with its work uncommitted and HEAD unmoved — the loop
responds by running a short, single-purpose **checkpoint turn** that reads the diff and
commits it as `wip:`, converting the stall into a progression the loop already knows how
to continue. It does **not** reattach to the stalled turn's own conversation with
`claude --resume`, even though that would preserve the reasoning the stalled turn had
built up.

## Considered options

**Session resume** was the original proposal, written up at length before this decision
(that document is superseded by `PLAN-2026-09-14-stall-checkpoint-turn.md`). It is the
obvious idea and it is strictly better on one axis: a cold checkpoint turn reconstructs
the `Remaining:` list from the diff alone and never sees why the author did what it did,
where a resumed session keeps all of it.

It was rejected because its value rests entirely on a behaviour nobody can confirm:
whether auto-compaction runs in `--print` mode. The CLI documents auto-compaction for
interactive sessions and declines to state either way for `-p`, offers no non-interactive
`/compact`, and no flag to request compaction from the command line. If compaction does
not apply, a resumed turn re-reads the transcript that just overflowed and dies
immediately — a paid iteration that buys nothing, and a *worse* outcome than today's
stop, which at least tells a human to look. Session resume also needs a per-adapter
`--resume` path, session-id plumbing, and a way to skip `exec_sync_down` so the dirty
tree survives; the checkpoint turn needs none of those, because `exec_run` and
`exec_sync_down` are already separate calls in the seam, so "run the agent without
syncing first" is something every adapter can already do.

## Consequences

- The `Remaining:` list after a stall is a **reconstruction from the diff**, not the
  author's own account. The next iteration's prompt says so explicitly, so it treats the
  list as a summary of what is there rather than of what was intended.
- The loop still never auto-commits. An agent commits; the checkpoint turn is an agent.
  This was a constraint on the design, not a happy accident — a loop that commits
  unreviewed work under a ticket that may not have finished is the thing the stop exists
  to prevent.
- The checkpoint turn is constrained by a narrow prompt and a low `--max-turns`, not by
  `--allowed-tools`: both sbx adapters default to `--permission-mode bypassPermissions`,
  where an allowlist plausibly does not bite at all. A restriction that silently does
  nothing in the default mode is worse than no restriction, because it reads as
  protection.
- Session resume stays available as a later optimisation. Taking it up means running the
  compaction experiment first — resume a deliberately near-limit session under `--print`
  and see whether it compacts or returns `prompt_too_long`.
