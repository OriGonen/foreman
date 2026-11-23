# 17: Try a real Antigravity batch and a real fallback

**Status:** ready-for-human
**Handoff:** .scratch/agents/handoff/17-try-a-real-antigravity-batch-and-fallback.md

**Blocked by:** 15, 16

**What to do:**

The automated tests never call a real agent. This is the one time the whole feature runs
for real, on your machine and accounts, before it is called done.

1. Run `foreman agents` and `foreman doctor` on a small throwaway batch (two or three tiny
   tickets in a scratch repository) with `FOREMAN_AGENT=antigravity`. Note what they say.
2. Run it with `foreman run` in the default sandbox mode, on the free key's default model.
   Watch a turn with `--live`. Note how each ticket ended and the "≈" costs.
3. Do the same from the app's run settings, choosing Antigravity there.
4. Run a Claude batch with `FOREMAN_FALLBACK_AGENT=antigravity`. If no real usage limit
   comes, say so; you may instead use the fake limit the smoke tests use, and note that you did.
5. Note anything that was confusing, wrong or slow.

Why this is a human ticket: it spends real quota on your accounts and needs your judgment
about whether the result is good enough.

**Acceptance criteria:**

- [ ] What `foreman agents` and `foreman doctor` reported for the Antigravity batch is recorded
- [ ] How each ticket of the Antigravity batch ended, and its estimated costs, are recorded
- [ ] Whether starting the run from the app worked is recorded
- [ ] Whether the fallback took over — from a real limit or a faked one, and which — is recorded, with what the terminal said
- [ ] Every problem seen is listed, or "none" is written
