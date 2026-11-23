# 05: Install Antigravity and run the capture script

**Status:** ready-for-human
**Handoff:** .scratch/agents/handoff/05-install-antigravity-and-run-the-capture-script.md

**Blocked by:** 04

**What to do:**

Everything after this ticket is written against what the real `agy` prints, and only you
can install it, sign in and make a key.

1. Install the Antigravity CLI from Google's install page (antigravity.google/docs/install)
   and note its version (`agy --version`).
2. Sign in with your Google account (the Plus subscription): run `agy` once and follow the
   sign-in. Check `agy models` lists models.
3. Run the capture script from ticket 04 for the signed-in login. Commit what it saved.
4. Create an API key at Google AI Studio (aistudio.google.com) on the free tier. Store it
   somewhere outside every repository and note **where**, never its value.
5. Switch Antigravity to the key: add `"modelProvider": "gemini"` to
   `~/.gemini/antigravity-cli/settings.json` and export `GEMINI_API_KEY`. Check `agy models`
   again — the list should differ.
6. Run the capture script for the key login. Commit what it saved.
7. Follow the sandbox steps the script printed: try to create a throwaway Antigravity
   sandbox (a maintained kit if `sbx` offers one, otherwise a custom kit on Docker's shell
   image), get either login into it, and run one `agy -p` in it. Remove the sandbox after.
8. Switch Antigravity back to the login you want to keep using, and say which.
9. If at any point you hit a usage limit or quota message, paste it exactly.

Why this is a human ticket: it installs software, signs in to your Google account and
creates a key. Never write the key's value into the handoff file or a commit.

**Acceptance criteria:**

- [ ] The installed `agy` version and the `sbx` version are recorded
- [ ] The signed-in capture is committed, and the models `agy models` lists signed in are recorded
- [ ] Where the API key is stored is recorded (not its value), and the key capture is committed
- [ ] Whether the free-tier key works with `agy` at all is recorded
- [ ] What creating an Antigravity sandbox took — or exactly where it failed — is recorded, with the commands used
- [ ] How each login got into the sandbox, or that it could not, is recorded
- [ ] Any usage-limit or quota text seen is pasted exactly, or "none seen" is written
- [ ] Which login Antigravity is left on is recorded
