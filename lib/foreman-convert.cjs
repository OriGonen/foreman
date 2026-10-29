// Converts a project that used the toolkit under its old name, ralph, to foreman.
//
//   foreman convert [<project>]              convert it (default: the repo you are in)
//   foreman convert [<project>] --dry-run    say what would change, change nothing
//   foreman convert [<project>] --allow-dirty  convert even with uncommitted changes
//
// What it does, in the project's git repository:
//
//   renames    every ralph.conf to foreman.conf (`git mv` when tracked), and the per-batch
//              run files: ralph-runs.jsonl, ralph-runs.log, .ralph-stall-marker. The old
//              .ralph-iter.bundle is deleted — it is rebuilt on every iteration.
//   rewrites   every text file git knows about (tracked, or untracked and not ignored):
//              RALPH_X → FOREMAN_X, `ralph run` → `foreman run`, ralph-loop.sh →
//              foreman-loop.sh, "Ralph" → "Foreman", and so on, case for case.
//   keeps      credit to the technique ("Ralph loop", "Ralph Wiggum"), and any path to a
//              file or directory of the project's own whose name has ralph in it — those are
//              listed at the end, for you to rename or not.
//
// On this machine it also copies ~/.config/ralph/env to ~/.config/foreman/env, with its
// names renamed, when there is no foreman one yet (the old file stays), and says what is
// left that only you can do: RALPH_* variables in your environment, the old sandbox.
//
// It never commits. Review with `git diff`, then commit. A second run finds nothing to do.
//
// At a terminal wide enough for it, the result is drawn by foreman-draw.cjs (the `convert` scene) as
// the sign repainted from RALPH to FOREMAN, with what changed under it; anywhere else it is the plain
// text below, which is what scripts have always read. bin/foreman decides which, from the same
// variables as every other command (foreman-ui.sh's ui_show and ui_cols), and says so in
// FOREMAN_DRAW_TIER and FOREMAN_DRAW_COLS; without them this prints the plain text.

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execFileSync } = require('node:child_process');

const argv = process.argv.slice(2);
const DRY = argv.includes('--dry-run');
const ALLOW_DIRTY = argv.includes('--allow-dirty');
if (argv.includes('--help') || argv.includes('-h')) {
  const head = fs.readFileSync(__filename, 'utf8').split('\n');
  for (const line of head) {
    if (!line.startsWith('//')) break;
    console.log(line.replace(/^\/\/ ?/, ''));
  }
  process.exit(0);
}
const unknown = argv.filter((a) => a.startsWith('-') && !['--dry-run', '--allow-dirty'].includes(a));
const positional = argv.filter((a) => !a.startsWith('-'));
if (unknown.length || positional.length > 1) {
  console.error('Usage: foreman convert [<project>] [--dry-run] [--allow-dirty]');
  process.exit(1);
}

const show = (p) => String(p).split('\\').join('/');
const git = (args, opts = {}) =>
  execFileSync('git', ['-C', ROOT, ...args], { encoding: 'utf8', maxBuffer: 1 << 28, ...opts });

// --- the project ------------------------------------------------------------
const start = path.resolve(positional[0] || '.');
if (!fs.existsSync(start) || !fs.statSync(start).isDirectory()) {
  console.error(`foreman convert: ${show(start)} is not a directory`);
  process.exit(1);
}
let ROOT;
try {
  ROOT = execFileSync('git', ['-C', start, 'rev-parse', '--show-toplevel'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore']
  }).trim();
} catch {
  console.error(`foreman convert: ${show(start)} is not inside a git repository`);
  process.exit(1);
}

// The toolkit's own repository keeps its legacy code and its history on purpose.
if (fs.existsSync(path.join(ROOT, 'lib', 'foreman-legacy.sh'))) {
  console.error(`foreman convert: ${show(ROOT)} is the foreman toolkit itself — nothing to convert`);
  process.exit(1);
}

// A clean tree makes the conversion the whole of `git diff`, so it can be reviewed alone.
if (!ALLOW_DIRTY && !DRY) {
  const dirty = git(['status', '--porcelain', '--untracked-files=no']).trim();
  if (dirty) {
    console.error(`foreman convert: ${show(ROOT)} has uncommitted changes:`);
    console.error(dirty.split('\n').slice(0, 10).map((l) => `  ${l}`).join('\n'));
    console.error('Commit or stash them first, so the conversion is a diff of its own');
    console.error('(or pass --allow-dirty).');
    process.exit(1);
  }
}

// THE SHOW. bin/foreman says, in these two variables, that the result is wanted as a picture and how to
// draw it: the colour tier (16, 256 or 24) and the width. Neither set is today's text. Then the text is
// held back until the work is done, and printed if the picture cannot be made — the renderer will not
// load, a row of it is wider than the screen — or if the work stops half way, as it printed as it went.
const tier = Number(process.env.FOREMAN_DRAW_TIER);
const cols = Number(process.env.FOREMAN_DRAW_COLS);
const showing = [16, 256, 24].includes(tier) && Number.isInteger(cols) && cols > 0;
const held = [];
const say = (line = '') => (showing ? held.push(line) : console.log(line));
const flushHeld = () => { if (held.length) process.stdout.write(`${held.splice(0).join('\n')}\n`); };
process.on('exit', flushHeld);

function drawn(facts) {
  try {
    const draw = require('./foreman-draw.cjs');
    const scene = draw.SCENES.convert;
    if (cols < scene.min) return null;
    const rows = scene.rows(facts, { tier, cols });
    if (rows.some((row) => draw.runsWidth(row) > cols)) return null;
    return draw.encode(rows, tier);
  } catch {
    return null;
  }
}

// What the picture is told, for it to word: the lists are lines of tab-separated fields.
const facts = { project: show(ROOT), home: process.env.HOME || os.homedir(), dry: DRY ? '1' : undefined };

say(`Project: ${show(ROOT)}${DRY ? '   (dry run — nothing is changed)' : ''}`);

// --- the rules --------------------------------------------------------------
// The word in each of its three spellings, case for case. RALPH_X, ralph-loop.sh, .ralph-*,
// `ralph run`, "Ralph's" all match; "ralphs" or "Ralphie" do not.
const WORD = /(?<![A-Za-z0-9])(ralph|Ralph|RALPH)(?![A-Za-z0-9])/g;
// Credit to the technique the toolkit is named after stays as written: "Ralph loop(s)",
// "Ralph-loop", "Ralph Wiggum" — but not ralph-loop.sh, which is a file of the toolkit's.
const KEEP_AFTER = /^(?:[ -][Ll]oops?(?!\.\w|-)|\s+Wiggum)/;
const SPELL = { ralph: 'foreman', Ralph: 'Foreman', RALPH: 'FOREMAN' };

// The run files a batch keeps beside its conf, git-ignored, so not something `git ls-files`
// lists. Renamed where found; never over a file already there.
const STATE_RENAMES = {
  'ralph.conf': 'foreman.conf',
  'ralph-runs.jsonl': 'foreman-runs.jsonl',
  'ralph-runs.log': 'foreman-runs.log',
  '.ralph-stall-marker': '.foreman-stall-marker'
};
const STATE_DELETES = new Set(['.ralph-iter.bundle']);
const PRUNE = new Set(['.git', 'node_modules', '.svelte-kit', '.next', 'dist', 'build', 'target', '.venv', 'venv']);

const lsFiles = (extra) =>
  git(['ls-files', '-z', ...extra]).split('\0').filter(Boolean);
const tracked = new Set(lsFiles(['--cached']));
const trackedOrNew = [...new Set([...tracked, ...lsFiles(['--others', '--exclude-standard'])])];

// A file or directory of the project's own whose name says ralph — `docs/ralph-notes.md`,
// `.scratch/ralph-setup/` — is not the toolkit's to rename. Its name is protected wherever
// it is mentioned, so no reference to it breaks; it is listed at the end instead.
const ownNames = new Set();
for (const f of trackedOrNew) {
  for (const seg of f.split('/')) {
    if (/ralph/i.test(seg) && !(seg in STATE_RENAMES) && !STATE_DELETES.has(seg)) ownNames.add(seg);
  }
}
const protectedNames = [...ownNames].sort((a, b) => b.length - a.length);

function convertText(text) {
  // Mask the protected names, then swap the word, then unmask.
  const masks = [];
  for (const name of protectedNames) {
    if (!text.includes(name)) continue;
    const token = `\u0000${masks.length}\u0000`;
    masks.push(name);
    text = text.split(name).join(token);
  }
  let n = 0;
  text = text.replace(WORD, (m, w, offset, whole) => {
    if (KEEP_AFTER.test(whole.slice(offset + m.length, offset + m.length + 40))) return m;
    n++;
    return SPELL[w];
  });
  masks.forEach((name, i) => { text = text.split(`\u0000${i}\u0000`).join(name); });
  return { text, n };
}

// --- 1. the files to rename -------------------------------------------------
const renames = [];
const deletes = [];
const blocked = [];
(function walk(rel) {
  let entries;
  try { entries = fs.readdirSync(path.join(ROOT, rel), { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    const r = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) {
      if (PRUNE.has(e.name) || r === '.claude/worktrees') continue;
      walk(r);
    } else if (e.name in STATE_RENAMES) {
      const to = `${rel ? `${rel}/` : ''}${STATE_RENAMES[e.name]}`;
      if (fs.existsSync(path.join(ROOT, to))) blocked.push([r, to]);
      else renames.push([r, to]);
    } else if (STATE_DELETES.has(e.name)) {
      deletes.push(r);
    }
  }
})('');

// --- 2. the text to rewrite -------------------------------------------------
const rewrites = [];
for (const f of trackedOrNew) {
  const abs = path.join(ROOT, f);
  let buf;
  try {
    if (!fs.statSync(abs).isFile()) continue;
    buf = fs.readFileSync(abs);
  } catch { continue; }
  if (buf.subarray(0, 8000).includes(0)) continue; // binary
  // latin1 is byte for byte, so line endings and any non-ASCII text come back unchanged —
  // every replacement is plain ASCII.
  const before = buf.toString('latin1');
  if (!/ralph/i.test(before)) continue;
  const { text, n } = convertText(before);
  if (n > 0) rewrites.push({ f, text, n });
}

// --- 3. do it ---------------------------------------------------------------
const plan = renames.length + deletes.length + rewrites.length;
if (plan === 0) {
  say('Nothing in the project to convert — it already speaks foreman.');
} else {
  say('');
  for (const { f, text, n } of rewrites) {
    if (!DRY) fs.writeFileSync(path.join(ROOT, f), Buffer.from(text, 'latin1'));
    say(`   rewrote  ${f}  (${n} change${n === 1 ? '' : 's'})`);
  }
  // After the rewrites, so a renamed file keeps its rewritten content.
  for (const [from, to] of renames) {
    if (!DRY) {
      if (tracked.has(from)) git(['mv', '--', from, to]);
      else fs.renameSync(path.join(ROOT, from), path.join(ROOT, to));
    }
    say(`   renamed  ${from} → ${path.posix.basename(to)}`);
  }
  for (const f of deletes) {
    if (!DRY) fs.rmSync(path.join(ROOT, f), { force: true });
    say(`   deleted  ${f}  (rebuilt on the next iteration)`);
  }
}
for (const [from, to] of blocked) {
  say(`   left     ${from} — ${to} is already there; merge the two by hand and delete the old one`);
}
// The busiest file first, the others as they were found.
facts.rewrite = rewrites.slice().sort((a, b) => b.n - a.n).map(({ f, n }) => `${f}\t${n}`);
facts.rename = renames.map(([from, to]) => `${from}\t${to}`);
facts.delete = deletes;
facts.blocked = blocked.map(([from, to]) => `${from}\t${to}`);

// --- 4. what is left in the project ----------------------------------------
const left = [];
const mentions = [];
let credit = 0;
// A line that still says ralph is credit to the technique when, with the project's own names and that
// credit taken out of it, it says no ralph. The rest are for a person to look at.
function isCredit(line) {
  let rest = line;
  for (const name of protectedNames) rest = rest.split(name).join('');
  let kept = 0;
  rest = rest.replace(WORD, (m, w, offset, whole) => {
    if (!KEEP_AFTER.test(whole.slice(offset + m.length, offset + m.length + 40))) return m;
    kept++;
    return '';
  });
  return kept > 0 && !/ralph/i.test(rest);
}
for (const f of trackedOrNew) {
  const abs = path.join(ROOT, f);
  let text;
  try {
    if (!fs.statSync(abs).isFile()) continue;
    const buf = fs.readFileSync(abs);
    if (buf.subarray(0, 8000).includes(0)) continue;
    text = buf.toString('latin1');
  } catch { continue; }
  if (DRY) text = convertText(text).text;
  text.split('\n').forEach((line, i) => {
    if (!/ralph/i.test(line)) return;
    const said = line.replace(/\r$/, '').trim();
    left.push(`${f}:${i + 1}: ${said.slice(0, 100)}`);
    if (isCredit(said)) credit++;
    else mentions.push(`${f}:${i + 1}\t${said}`);
  });
}
const ownPaths = trackedOrNew.filter((f) => f.split('/').some((s) => ownNames.has(s)));
facts.own = ownPaths;
facts.credit = String(credit);
facts.mention = mentions;
if (left.length || ownPaths.length) {
  say('');
  say('Kept as they are (look them over):');
  if (ownPaths.length) {
    say("  the project's own files whose names say ralph — rename with `git mv` if you want to,");
    say('  and the references to them along with it:');
    for (const f of ownPaths.slice(0, 20)) say(`    ${f}`);
    if (ownPaths.length > 20) say(`    … and ${ownPaths.length - 20} more`);
  }
  if (left.length) {
    say('  mentions left (credit to the Ralph loop, or a name above):');
    for (const l of left.slice(0, 30)) say(`    ${l}`);
    if (left.length > 30) say(`    … and ${left.length - 30} more`);
  }
}

// --- 5. this machine --------------------------------------------------------
const home = process.env.HOME || os.homedir();
const machine = [];
const oldEnv = path.join(home, '.config', 'ralph', 'env');
const newEnv = path.join(home, '.config', 'foreman', 'env');
if (!process.env.FOREMAN_CREDENTIALS_FILE && fs.existsSync(oldEnv)) {
  if (fs.existsSync(newEnv)) {
    machine.push(`~/.config/ralph/env is no longer read (~/.config/foreman/env is); delete it once you have checked nothing in it is missing from the new one`);
    facts.envfile = 'exists';
  } else {
    if (!DRY) {
      fs.mkdirSync(path.dirname(newEnv), { recursive: true });
      const { text } = convertText(fs.readFileSync(oldEnv).toString('latin1'));
      fs.writeFileSync(newEnv, Buffer.from(text, 'latin1'), { mode: 0o600 });
    }
    machine.push(`${DRY ? 'would copy' : 'copied'} ~/.config/ralph/env to ~/.config/foreman/env, names renamed; delete the old one when you are happy`);
    facts.envfile = 'copied';
  }
}
const oldVars = Object.keys(process.env).filter((k) => k.startsWith('RALPH_')).sort();
facts.var = oldVars.map((k) => `${k}\tFOREMAN_${k.slice('RALPH_'.length)}`);
facts.windows = process.platform === 'win32' ? '1' : undefined;
for (const k of oldVars) {
  const neu = `FOREMAN_${k.slice('RALPH_'.length)}`;
  machine.push(
    process.platform === 'win32'
      ? `${k} is set in your environment: setx ${neu} "<its value>", then reg delete HKCU\\Environment /v ${k} /f`
      : `${k} is set in your environment: export ${neu} in its place, wherever you set it`
  );
}
const repoName = path.basename(ROOT);
if (renames.some(([from]) => from.endsWith('ralph.conf'))) {
  machine.push(`a sandbox named ralph-${repoName} may be left from before; foreman makes foreman-${repoName}. Once you no longer need it: sbx rm ralph-${repoName}`);
  facts.sandbox = `ralph-${repoName}`;
}
if (machine.length) {
  say('');
  say('On this machine:');
  for (const m of machine) say(`  ${m}`);
}

say('');
if (DRY) {
  say(plan ? 'Run it without --dry-run to make these changes.' : '');
} else if (plan) {
  say('Nothing is committed. Review with `git diff`, then commit.');
}

// The picture, or the text it stood in for.
if (showing) {
  const picture = drawn(facts);
  if (picture !== null) {
    held.length = 0;
    process.stdout.write(picture);
  }
}
flushHeld();
