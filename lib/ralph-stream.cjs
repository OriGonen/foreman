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
// Usage:  exec_run … | node ralph-stream.cjs [--live] > payload

const stripAnsi = require('./ralph-strip-ansi.cjs');

const live = process.argv.includes('--live');

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
  const line = `   ${clock()} · ${label}`;
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

// The wall-clock counter has to advance while nothing is happening — a stalled iteration is
// precisely the one worth being able to see. Only on a TTY, where the line is rewritten in
// place; unref'd so it can never be the reason the process stays alive.
let ticker = null;
if (tty) {
  ticker = setInterval(() => render(lastLabel), 1000);
  if (typeof ticker.unref === 'function') ticker.unref();
}

process.on('exit', clearLine);

// --- the stream -------------------------------------------------------------
function handle(line) {
  const clean = stripAnsi(line).trim();
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
    clearLine();
    process.stdout.write(`${clean}\n`);
    return;
  }

  const content = event.message && event.message.content;
  if (event.type !== 'assistant' || !Array.isArray(content)) return;
  for (const block of content) {
    if (!block || block.type !== 'tool_use') continue;
    const label = describeTool(block.name, block.input);
    if (label) render(label);
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
});
