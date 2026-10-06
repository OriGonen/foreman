// Stands between the agent and the recorder, so a long iteration can be watched.
//
// Once exec_run is invoked the terminal is silent until it returns — 7 minutes, 45 minutes,
// however long — with no way to tell whether the iteration is alive or what it is doing
// without tailing a log in a second shell.
//
// This filter is ALWAYS in the pipeline, in both modes, so there is one code path rather
// than two:
//
//   plain (default)  a pass-through. stdin is copied to stdout byte for byte and nothing
//                    is drawn. The default run is byte-identical to one with no filter.
//   --live           stdin is `--output-format stream-json` (one JSON object per line).
//                    The final result object goes to stdout, so the recorder's contract is
//                    unchanged; everything else is drawn to STDERR and never to stdout.
//
// WHAT IT DRAWS, AND WHAT IT DOES NOT
//
// Only file writes/edits and shell commands. Reads, greps and globs are the majority of the
// traffic and say nothing about progress; writes and commands are exactly the two signals
// that would have caught a partial turn or a denied commit while it was happening.
//
// PRIVACY. A `tool_use` event carries the WHOLE input — a `Write` carries the entire file
// body. Only the tool name and the first path or command argument are ever rendered,
// truncated. The input object is never printed, no transcript is dumped, and no raw stream
// is persisted to disk.
//
// THE L KEY. With --live-file PATH the input is stream-json as with --live, but the drawing
// follows PATH: on while it reads 1, off (and the line cleared) otherwise. ralph-keys.sh
// writes it; it is read again once a second on a terminal, and on every event otherwise.
// A run on a terminal always asks the agent for stream-json, so the view can be turned on
// in the middle of an iteration — the format cannot change once the agent has started.
//
// Usage:  exec_run … | node ralph-stream.cjs [--live | --live-file PATH] > payload

const fs = require('node:fs');
const stripAnsi = require('./ralph-strip-ansi.cjs');

const liveFileAt = process.argv.indexOf('--live-file');
const liveFile = liveFileAt !== -1 ? process.argv[liveFileAt + 1] : null;
const live = process.argv.includes('--live') || Boolean(liveFile);
// Whether the clock is drawn dim. Decided by ralph-loop.sh and passed in, not worked out here:
// RALPH_COLOR may live in a ralph.conf this process never sees. See ralph-ui.sh.
const color = process.argv.includes('--color');

// --- plain mode: a pipe with a node process in the middle -------------------
if (!live) {
  process.stdin.pipe(process.stdout);
  return;
}

const MAX_LABEL = 80;
const tty = Boolean(process.stderr.isTTY);
const started = Date.now();

// The tools worth a line, and where each one keeps the argument that identifies it. Any
// tool absent from this map is skipped — that is the filter, not an oversight.
const SIGNIFICANT = {
  Write: (i) => i.file_path,
  Edit: (i) => i.file_path,
  MultiEdit: (i) => i.file_path,
  NotebookEdit: (i) => i.notebook_path,
  Bash: (i) => i.command
};

const truncate = (s) => (s.length > MAX_LABEL ? `${s.slice(0, MAX_LABEL - 1)}…` : s);

// Tool name plus ONE argument, flattened to a single line and truncated. Everything else in
// the input — including a whole file body — is dropped here and never reaches the terminal.
function describeTool(name, input) {
  const pick = SIGNIFICANT[name];
  if (!pick) return null;
  const arg = input && typeof input === 'object' ? pick(input) : null;
  const text = typeof arg === 'string' ? arg.replace(/\s+/g, ' ').trim() : '';
  return text ? `${name} ${truncate(text)}` : name;
}

function clock() {
  const s = Math.floor((Date.now() - started) / 1000);
  const pad = (n) => String(n).padStart(2, '0');
  return `${pad(Math.floor(s / 60))}:${pad(s % 60)}`;
}

// The clock, dim when colour is on. Only the digits are wrapped, so the line's text and its
// column positions are the same either way.
const stamp = () => (color ? `\x1b[2m${clock()}\x1b[0m` : clock());

// --- drawing, stderr only ---------------------------------------------------
let onScreen = false; // an in-place line is currently on the terminal
let lastLabel = 'starting…';

// Clear before ANY other write and on exit, so a dying run leaves no stale text behind.
function clearLine() {
  if (tty && onScreen) {
    process.stderr.write('\r\x1b[2K');
    onScreen = false;
  }
}

function render(label) {
  lastLabel = label;
  const line = `   ${stamp()} · ${label}`;
  if (tty) {
    clearLine();
    process.stderr.write(line);
    onScreen = true;
  } else {
    // Not a terminal (a test, a CI log, a redirect): one plain line per event. A `\r`
    // rewrite would be noise in a file, and the wall clock is still on every line.
    process.stderr.write(`${line}\n`);
  }
}

// Whether the view is on: always with --live, else what the live file says. A missing or
// unreadable file reads as off.
let showing = !liveFile;
function readLiveFile() {
  if (!liveFile) return;
  try {
    showing = fs.readFileSync(liveFile, 'utf8').trim() === '1';
  } catch {
    showing = false;
  }
}
readLiveFile();

// The wall-clock counter has to advance while nothing is happening — a stalled iteration is
// precisely the one worth being able to see. Only on a TTY, where the line is rewritten in
// place; unref'd so it can never be the reason the process stays alive. It is also when the
// live file is looked at again: turned off, the line goes; turned on, it comes back.
let ticker = null;
if (tty) {
  ticker = setInterval(() => {
    readLiveFile();
    if (showing) render(lastLabel);
    else clearLine();
  }, 1000);
  if (typeof ticker.unref === 'function') ticker.unref();
}

process.on('exit', clearLine);

// --- the stream -------------------------------------------------------------
// A bounded copy of everything seen so far, kept only until a result object arrives.
//
// Verified against a real sandbox: when the agent fails to start, `sbx` prints its own
// banner and `ERROR: agent exited with code 1`, and claude's error text never appears at
// all. Every one of those lines is non-JSON, so they are all dropped and stdout ends up
// EMPTY — and the recorder's raw-payload dump is guarded on the payload being non-empty, so
// the human is left with "payload was not valid JSON" and nothing whatsoever to look at.
// Forwarding the tail in that case turns a silent dead end back into a diagnosable failure.
//
// This can only widen what stdout carries where it currently carries nothing: once a result
// object has been seen the tail is dropped and stdout is exactly that object, as before.
const TAIL_MAX_LINES = 40;
const TAIL_MAX_BYTES = 8000;
let tail = [];
let tailBytes = 0;
let sawResult = false;

function remember(line) {
  if (sawResult || !line) return;
  tail.push(line);
  tailBytes += line.length + 1;
  while (tail.length > TAIL_MAX_LINES || tailBytes > TAIL_MAX_BYTES) {
    tailBytes -= tail.shift().length + 1;
  }
}

function handle(line) {
  const clean = stripAnsi(line).trim();
  remember(clean);
  if (!clean.startsWith('{')) return; // sbx's banner, and anything else non-JSON

  let event;
  try {
    event = JSON.parse(clean);
  } catch {
    return;
  }

  // The one thing downstream needs. Written verbatim rather than re-serialised, so what the
  // recorder parses is exactly what the CLI emitted.
  if (event.type === 'result') {
    sawResult = true;
    tail = [];
    tailBytes = 0;
    clearLine();
    process.stdout.write(`${clean}\n`);
    return;
  }

  const content = event.message && event.message.content;
  if (event.type !== 'assistant' || !Array.isArray(content)) return;
  for (const block of content) {
    if (!block || block.type !== 'tool_use') continue;
    const label = describeTool(block.name, block.input);
    if (!label) continue;
    if (!tty) readLiveFile();
    if (showing) render(label);
    else lastLabel = label;
  }
}

let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let i;
  while ((i = buffer.indexOf('\n')) !== -1) {
    handle(buffer.slice(0, i));
    buffer = buffer.slice(i + 1);
  }
});
process.stdin.on('end', () => {
  if (buffer.trim()) handle(buffer);
  clearLine();
  if (ticker) clearInterval(ticker);
  if (!sawResult && tail.length) {
    process.stderr.write(
      `   ${stamp()} · the agent printed no result object; passing what it did print to the log\n`
    );
    process.stdout.write(`${tail.join('\n')}\n`);
  }
});
