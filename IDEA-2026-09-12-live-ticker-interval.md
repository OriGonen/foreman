# Idea (not implemented) — make `--live`'s ticker interval configurable

Raised 2026-09-12 while watching a live run: the `--live` ticker redraws every second, and
it was asked whether that is excessive and wasteful of tokens/compute. Split out of
`PLAN-2026-09-12-resume-on-dirty-stop.md`, which it had nothing to do with.

## Correcting the premise first

The 1s redraw is **not** a token cost. `lib/ralph-stream.cjs:100-103`:

```js
if (tty) {
  ticker = setInterval(() => render(lastLabel), 1000);
  ...
}
```

`render()` (`:83-95`) only recomputes the elapsed-time clock and re-prints the *last tool
label already seen*, via `\r\x1b[2K` (clear line, rewrite in place). It is a local,
in-place terminal repaint: no network call, nothing sent to or from the model. Actual new
information appears only when a real `tool_use` event arrives from the stream (`:161-163`
calls `render(label)` again).

So a 2-iteration `--live` run costs the same in tokens whether the ticker fires once a
second or once a minute. The interval affects only local CPU and terminal writes, which
are already cheap — one string write to stderr.

## The real complaint

What the 1s interval *does* affect is visual flicker. On some terminals and multiplexers a
`\r\x1b[2K` rewrite every second reads as flashing, especially when nothing has changed —
an idle gap between tool calls, where the label is identical and only the clock digits
tick over. That is a legitimate complaint, and a separate one from the token question.

## If this gets picked up

A configurable ticker interval: `RALPH_LIVE_TICK_MS` (default `1000`), read where
`setInterval(() => render(lastLabel), 1000)` is called at `ralph-stream.cjs:102`, wired
through the same env-first pattern `ralph-config.sh` already uses for every other `RALPH_*`
knob. A larger default (2000-3000ms) would cut redraw frequency without losing the "is
this stalled?" purpose the comment at `:97-99` gives the ticker.

Worth deciding whether this is a batch-level `ralph.conf` setting or purely an environment
override, consistent with how other display-only knobs are handled.
