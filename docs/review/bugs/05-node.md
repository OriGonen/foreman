# 05 - Node: stream, log and record handling

Scope: lib/foreman-stream.cjs, foreman-record.cjs, foreman-json.cjs, foreman-report.cjs, foreman-claude-reply.cjs, strip-ansi, auth-patterns. Repros were run from temp directories outside the repo (node v24.19.0, Git Bash). No tracked file was modified.

Checked and found fine: multi-byte UTF-8 split across chunks (`setEncoding('utf8')` uses a StringDecoder); a JSON line split across chunks (buffered to `\n`); several `result` objects (stream forwards each, record merges); EPIPE from `foreman report | head` (3000-row `--by-ticket | head -2` exited 0, no crash); float cost sums (0.1+0.2+0.1 printed 0.4).

## 1. A killed agent's last events land in the payload and are classified as failure text (high, confirmed-by-repro)
foreman-stream.cjs:271-278, 333-338; foreman-record.cjs:150-151, 168, 247.
With no `result` object (timeout/kill), the stream filter flushes its tail: the last 40 lines / 8 KB of ALL events (assistant `tool_use` inputs, tool results), not just non-JSON noise, because `remember()` runs on every line before the `{` test. record.cjs then sets `haystack = raw` for the whole payload (payload null, so `ranSuccessfully` is false), so the file bodies the agent was writing are scanned for "billing", "rate limit", "permission denied", `api_error` and so on.
Repro:
```
echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/billing.ts","new_string":"export function billing() {}"}}]}}' \
  | node lib/foreman-stream.cjs --live-file nonexist > p.txt
node lib/foreman-record.cjs ... --exit-status 124 --quiet < p.txt
# verdict: limit_hit=1 is_error=1 parse_ok=1
```
Effect: a ticket that touches billing/quota code, killed by a timeout, makes foreman PAUSE as "usage limit reached" (foreman-loop.sh:1854). The same path gives false `transient`, `permission_denied` and `auth_failed`. Also `parse_ok=1` when exactly one leftover assistant event remains, because record's fallback parses any lone JSON object, so the failure looks like a clean parse with zero usage. Privacy: the header says no raw stream is persisted, but Write/Edit bodies in that tail go into the payload and then into foreman-runs.log "RAW PAYLOAD" (up to 20 KB).
Fix: in stream.cjs keep only lines that do not start with `{` (or that fail to parse) in the tail. In record.cjs require `type === 'result'` for the fallback parse.

## 2. Agent reply is appended raw to foreman-runs.log, the file whose `# ` control lines status --json parses (med, confirmed-by-repro)
foreman-record.cjs:363 (and 367); parsed at foreman-json.cjs:238-266; the same file is `$RUN_LOG` for both (foreman-loop.sh:230, 1454, 1814).
Any reply line reading `# run X started`, `# ---- run X finished`, `# complete` or `# paused: ...` overrides the real last run. An agent quoting a run log is enough, so this is not only an attack.
Repro: log holds `# run REAL started`, `# ---- run REAL finished`, `# paused: usage limit`; record a reply of "Log excerpt:\n# run FAKE started 1\n# ---- run FAKE finished 2 ----\n# complete", then run `foreman-json.cjs status` with `runlog` pointing at it. Observed: `last_run = {"id":"FAKE","end":"complete","exit":0,"reason":null}`. The GUI then shows a finished run for a paused one.
Fix: indent every reply line (`reply.replace(/^/gm, '    ')`) when writing it to the log.

## 3. `permission_denied` is not gated on failure, so a healthy turn can stop the run (med, confirmed-by-repro)
foreman-record.cjs:245-248; effect at foreman-loop.sh:1904.
The flag is suppressed only when the iteration landed cleanly. A healthy checkpoint turn (committed, ticket not flipped, no error) whose reply says "permission denied" gets it, and the loop stops with NEEDS_HUMAN before the dirty-tree and progressed branches. The comment promises that a ticket implementing permission handling cannot false-trigger; that holds only once the ticket has landed.
Repro: `{"type":"result","is_error":false,"result":"Implemented the handler; tests for permission denied now pass. checkpointing.",...}` with `--status-flipped 0 --base-ref a --head-ref b --tree-dirty 0 --exit-status 0` gives verdict `is_error=0 permission_denied=1`. Ordinary shell text quoted in a reply ("bash: x: Permission denied") matches too.
Fix: on a turn that succeeded (exit 0, is_error false), trust only the structured `payload.permission_denials` array, not free text.

## 4. record.cjs does not guard its writes and writes the verdict last (med, confirmed-by-repro)
foreman-record.cjs:325, 371, 404; bash truncates the verdict first (foreman-loop.sh:1809 `: > "$VERDICT_FILE"`).
If the jsonl or log append throws (EBUSY from antivirus, ENOSPC, a locked file on Windows), the script dies before the verdict is written. Bash then reads an empty verdict: `limit_hit`, `auth_failed`, `context_exhausted` read as false, and `verdict_num` turns cost and tokens into 0, so budgets stop counting.
Repro: `echo 'Claude AI usage limit reached|1735689600' | node lib/foreman-record.cjs --jsonl <a directory> --log r.log --verdict v.txt ... --exit-status 1` exits 1 with a stack trace; v.txt is 0 bytes; the limit is not detected.
Fix: write the verdict first, or wrap the two appends in try/catch, still write the verdict, then exit non-zero.

## 5. A torn line in foreman-runs.jsonl poisons the NEXT record; status --json reads "no spend" (low-med, confirmed-by-repro)
foreman-record.cjs:325; readers foreman-json.cjs:184-186, foreman-report.cjs:241-248.
`appendFileSync(jsonl, line + '\n')` never checks that the file ends in a newline. After a crash, kill or full disk mid-write, the next record is glued onto the fragment, so BOTH lines fail JSON.parse and the good record is lost too.
Repro: `printf '{"run_id":"A","cost_usd":1,"ticket":"t.md","iter' > j.jsonl`, record one valid iteration (cost 2), then `foreman-json.cjs status` gives `spent_usd null, runs 0`; `foreman report --jsonl j.jsonl` says "has no readable records". json.cjs skips bad lines with no `unreadable` counter, so status under-reports spend silently.
Fix: before appending, if the last byte of the file is not `\n`, prepend `\n` (read one byte with fs.openSync/readSync).

## 6. foreman report crashes on a JSONL line that is valid JSON but not an object (low, confirmed-by-repro)
foreman-report.cjs:244 (push), 279, 330.
`records.push(JSON.parse(line))` accepts `null`, numbers and strings; `null` then throws in `add()`.
Repro: `printf 'null\n{"run_id":"A","cost_usd":1}\n' > j.jsonl; node lib/foreman-report.cjs --jsonl j.jsonl` gives `TypeError: Cannot read properties of null (reading 'tokens')`, exit 1. json.cjs:187 already guards this case.
Fix: `if (rec && typeof rec === 'object') records.push(rec); else malformed++;`.

## 7. Terminal escape sequences in the agent's tool arguments reach the terminal, the activity file and the feed (low-med, confirmed-by-repro)
foreman-stream.cjs:94-100, 160, 212, 218; activity at 129; feed at 171.
`stripAnsi` runs on the raw JSON line, where an ESC is the text `\u001b`, so it strips nothing. After `JSON.parse` the `Bash` command or `file_path` holds real ESC/BEL bytes; `describeTool` collapses whitespace only and passes them on. Prompt-injected content can make the agent run a command containing `\x1b]0;...\x07` or `\x1b[2J`; the live view prints it to stderr and foreman-keys.sh later draws it from the activity file.
Repro: pipe `{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo hi \u001b]0;PWNED\u0007\u001b[2J"}}]}}` into `node lib/foreman-stream.cjs --live --feed-file f.txt`: `od -c` shows raw 033 ] 0 ; PWNED \a 033 [ 2 J in both stderr and f.txt.
Fix: in describeTool, strip C0/C1 controls after JSON.parse: `stripAnsi(arg).replace(/[\x00-\x1f\x7f-\x9f]/g, ' ')`. (The reply also goes unstripped into foreman-runs.log, record.cjs:363.)

## 8. One oversize event erases the stream's diagnostic tail, and long lines are quadratic (low, confirmed-by-repro)
foreman-stream.cjs:271-278, 320-327.
`remember()` pushes then evicts oldest-first until under 8000, so a single line over 8 KB evicts everything before it, including the `ERROR: agent exited with code 1` banner the tail exists to preserve. Repro: that banner followed by a 9000-char JSON event, no result: payload is 0 bytes, the silent dead end the tail was added to prevent. Separately `buffer.indexOf('\n')` rescans the whole buffer on every chunk: one 40 MB line took 9 s.
Fix: do not remember JSON lines (finding 1 removes this too); search for `\n` only in the new chunk.
