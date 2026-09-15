# Idea (not implemented) — `ralph remove <batch>` to disconnect or reset a finished batch

Raised 2026-09-12 as a workflow request: once a batch is done, have a command that
"disconnects" it from ralph for future work — described as useful when settings feel
outdated and the user wants a refresh. Split out of
`PLAN-2026-09-12-resume-on-dirty-stop.md`, which it had nothing to do with.

## What there is to remove, given the toolkit holds no state

`bin/ralph:2-4` and `lib/ralph-config.sh:5-6` state the rule: *"THE TOOLKIT HOLDS NO STATE.
Everything that differs between batches ... lives in the batch directory."*

So a batch is just a directory with `ralph.conf`, plus the files `ralph-config.sh` points
at by convention — `progress.txt`, `prompt-extra.md`, `ralph-runs.jsonl`, `ralph-runs.log`,
`.ralph-iter.bundle` (`ralph-config.sh:228-235`) — and the tickets and `order.md` under
`RALPH_ISSUES_DIRS`. There is no registry anywhere that "knows about" a batch beyond
`ralph_find_batches` scanning the repo for directories containing a `ralph.conf`
(`ralph-config.sh:65-66`).

"Disconnect a batch from ralph" therefore means exactly one thing: stop it being
discoverable and runnable as a batch, which today is entirely a property of whether
`ralph.conf` still exists in that directory.

## One wrinkle worth flagging

The sandbox is per-**repository**, not per-batch —
`RALPH_SANDBOX="ralph-$(basename "$REPO_ROOT")"` (`ralph-config.sh:242`) — so several
batches in one repo share a single sandbox container and clone. A `ralph remove <batch>`
must not tear down or reset the shared sandbox as a side effect; that would affect every
other batch in the same repository. It should touch only the batch directory's own files.

## Possible shapes, to be decided rather than assumed

- **Minimal:** delete or rename `ralph.conf`, so `ralph_find_batches` stops seeing it,
  leaving tickets, `progress.txt` and the run logs in place as a historical record. The
  closest thing to "just disconnect it", and nothing destructive.
- **Fuller reset:** also clear or archive `progress.txt`, `ralph-runs.jsonl`/`.log` and any
  per-ticket state, so a later `ralph init` on the same directory starts clean rather than
  re-attaching old progress notes and telemetry. Closer to what "outdated settings, I want
  a refresh" suggests, but destructive — it would need a confirmation step, or should move
  files aside rather than delete them, consistent with the toolkit's general caution around
  destructive git operations.
- **`--archive` vs `--delete`** may be the right split: one moves the batch's
  ralph-specific files (conf, progress, logs, bundle) into a subfolder or renames them with
  a suffix; the other deletes them outright.

Either way, tickets and `order.md` are the user's own content and should never be touched
by this command — only the ralph-generated and ralph-consumed files.
