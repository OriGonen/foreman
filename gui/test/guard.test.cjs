'use strict';
// guard.cjs and the page's static promises: what the window will not do, and what the page files
// must not contain. The CSP is in the page itself, so a test can hold it there.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { repoFromArgv, refuseNavigation, openWindowHandler, repoPath } = require('../guard.cjs');

const here = (f) => path.join(__dirname, '..', f);
const read = (f) => fs.readFileSync(here(f), 'utf8');

// ---- which repository the app was opened on ----

test('repoFromArgv: `npm start -- <repo>` runs `electron . <repo>`', () => {
  assert.equal(repoFromArgv(['C:\\e\\electron.exe', '.', 'C:\\Projects\\app'], true), 'C:\\Projects\\app');
});
test('repoFromArgv: the app named by the Start-menu shortcut\'s argument, then the repo', () => {
  assert.equal(repoFromArgv(['C:\\e\\electron.exe', 'C:\\foreman\\gui', 'C:\\Projects\\app'], true), 'C:\\Projects\\app');
});
test('repoFromArgv: no repo given is null (the app then asks), and flags are not repos', () => {
  assert.equal(repoFromArgv(['electron.exe', '.'], true), null);
  assert.equal(repoFromArgv(['electron.exe', '.', '--inspect=5858', '--no-sandbox'], true), null);
  assert.equal(repoFromArgv(['electron.exe', '.', '--inspect', 'C:\\r'], true), 'C:\\r');
});
test('repoFromArgv: a packaged app has no script argument to skip', () => {
  assert.equal(repoFromArgv(['foreman.exe', 'C:\\r'], false), 'C:\\r');
});

// ---- navigation ----

test('every navigation is refused, and window.open opens nothing', () => {
  let prevented = 0;
  refuseNavigation({ preventDefault() { prevented++; } });
  assert.equal(prevented, 1);
  assert.deepEqual(openWindowHandler({ url: 'https://example.com' }), { action: 'deny' });
});

// ---- paths the page may ask main to open ----

test('repoPath joins a repo-relative path to the root the Windows way', () => {
  assert.equal(repoPath('C:/Projects/app', '.scratch/gui/issues/02-x.md'), 'C:\\Projects\\app\\.scratch\\gui\\issues\\02-x.md');
  assert.equal(repoPath('C:\\Projects\\app\\', '.scratch/gui'), 'C:\\Projects\\app\\.scratch\\gui');
});

test('repoPath refuses what leaves the repository: absolute, parent, backslash, flag-like, empty', () => {
  for (const bad of ['', '/etc/passwd', 'C:/Windows', 'C:\\Windows', '..', 'a/../../b', 'a\\b', '-rf', 'a\0b', null, 7]) {
    assert.throws(() => repoPath('C:/Projects/app', bad), (e) => e.kind === 'bad-batch', String(bad));
  }
});

// ---- the page ----

const csp = /<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]*)"/i.exec(read('index.html'));

test('index.html has a strict CSP: own files only, no inline script or style, no eval, no plugins', () => {
  assert.ok(csp, 'a CSP meta tag');
  const policy = Object.fromEntries(csp[1].split(';').map((d) => d.trim()).filter(Boolean)
    .map((d) => { const [k, ...v] = d.split(/\s+/); return [k, v]; }));
  assert.deepEqual(policy['default-src'], ["'self'"]);
  assert.deepEqual(policy['script-src'], ["'self'"]);
  assert.deepEqual(policy['style-src'], ["'self'"]);
  assert.deepEqual(policy['object-src'], ["'none'"]);
  assert.deepEqual(policy['base-uri'], ["'none'"]);
  assert.deepEqual(policy['form-action'], ["'none'"]);
  assert.doesNotMatch(csp[1], /unsafe-|https?:|\*/);
});

test('index.html: scripts are files, there is no inline style and no event-handler attribute', () => {
  const html = read('index.html');
  for (const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
    assert.match(m[1], /\bsrc="[^":]+"/, 'script has a local src');
    assert.equal(m[2].trim(), '', 'no inline script body');
  }
  assert.doesNotMatch(html, /<style\b/i);
  assert.doesNotMatch(html, /\sstyle\s*=/i);
  assert.doesNotMatch(html, /\son[a-z]+\s*=/i);
  assert.doesNotMatch(html, /(?:src|href)="(?:https?:)?\/\//i);
});

test('the page scripts never build HTML from text: ticket and CLI text only ever goes in with textContent', () => {
  for (const f of ['app.js', 'art.js', 'model.js', 'preview.js', 'preload.cjs']) {
    const src = read(f).replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
    for (const bad of ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'createContextualFragment',
      'DOMParser', 'eval(', 'new Function', "setAttribute('style'", 'setAttribute("style"', 'srcdoc']) {
      assert.ok(!src.includes(bad), `${f} must not use ${bad}`);
    }
  }
});

test('app.css loads nothing: no @import, no url() to anything but a data URI', () => {
  const css = read('app.css');
  assert.doesNotMatch(css, /@import/i);
  assert.doesNotMatch(css, /url\(\s*['"]?(?!data:)/i);
});

// The tokens are the design's (spec: "The light palette"). A typo here is a colour nobody signed off.
const TOKENS = {
  bg: ['#0d0c0b', '#f4efe6'], panel: ['#171614', '#fffcf6'], 'panel-2': ['#1c1a17', '#f9f3e8'],
  line: ['#3a3732', '#e2d8c6'], text: ['#ece8e1', '#2a2117'], muted: ['#a8a299', '#6b6154'],
  dim: ['#5c574f', '#a2978a'], accent: ['#e0a84a', '#9a5a17'], sunfill: ['#f6d58e', '#eaa43a'],
  rust: ['#c9772f', '#a3561b'], ok: ['#8fcf8f', '#2e7d3c'], err: ['#f08078', '#b43a2f'],
  'sky-top': ['#1c1a17', '#fff8ea'], 'sky-bot': ['#3a2a18', '#fbe2b0'], outline: ['#8a5a24', '#3a2a18'],
};

function block(css, open) {
  const i = css.indexOf(open);
  assert.ok(i >= 0, `${open} in app.css`);
  return css.slice(css.indexOf('{', i), css.indexOf('}', i));
}

test('app.css: dark is the default, light follows Windows, and every token is the design\'s', () => {
  const css = read('app.css');
  const dark = block(css, ':root');
  const light = block(css, '@media (prefers-color-scheme: light)');
  for (const [name, [d, l]] of Object.entries(TOKENS)) {
    assert.match(dark, new RegExp(`--${name}:\\s*${d};`, 'i'), `dark --${name}`);
    assert.match(light.slice(light.indexOf('--')), new RegExp(`--${name}:\\s*${l};`, 'i'), `light --${name}`);
  }
});

test('the window\'s own files exist: everything index.html names, and everything the architecture lists for this ticket', () => {
  const html = read('index.html');
  for (const m of html.matchAll(/(?:src|href)="([^"]+)"/g)) assert.ok(fs.existsSync(here(m[1])), m[1]);
  for (const f of ['main.cjs', 'preload.cjs', 'bash.cjs', 'foreman.cjs', 'watch.cjs', 'ticket.cjs', 'preview.js', 'index.html', 'app.css', 'app.js', 'art.js', 'icon.ico']) {
    assert.ok(fs.existsSync(here(f)), f);
  }
});

test('electron is the only dependency, pinned to an exact version, with no native module', () => {
  const pkg = JSON.parse(read('package.json'));
  assert.deepEqual(Object.keys(pkg.dependencies), ['electron']);
  assert.match(pkg.dependencies.electron, /^\d+\.\d+\.\d+$/);
  assert.equal(pkg.devDependencies, undefined);
  const lock = JSON.parse(read('package-lock.json'));
  assert.equal(lock.packages['node_modules/electron'].version, pkg.dependencies.electron);
  for (const [name, p] of Object.entries(lock.packages)) {
    assert.ok(!p.hasInstallScript || name === 'node_modules/electron', `${name} has an install script`);
  }
});

test('the app writes the handoff and the run\'s own output file, and nothing else: only ticket.cjs writes, and runner.cjs only makes <batch>/.foreman-run/ and opens out', () => {
  const writes = /\b(writeFile|writeFileSync|appendFile|appendFileSync|createWriteStream|mkdir|mkdirSync|rename|renameSync|unlink|unlinkSync|rm|rmSync|rmdir|rmdirSync|copyFile|copyFileSync|truncate|truncateSync)\b\s*\(/;
  const strip = (f) => read(f).replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
  for (const f of fs.readdirSync(here('.')).filter((n) => /\.(cjs|js)$/.test(n))) {
    if (f === 'ticket.cjs' || f === 'runner.cjs') continue;
    assert.doesNotMatch(strip(f), writes, `${f} must not write files`);
  }
  assert.match(strip('ticket.cjs'), /writeFileSync/, 'ticket.cjs is where the handoff is written');

  // The run's stdout and stderr go to `<batch>/.foreman-run/out` (spec: Spawn). That is the only thing
  // runner.cjs creates: the directory, and the file the process is handed. It writes no other file, and
  // never foreman.conf.
  const r = strip('runner.cjs');
  const used = [...r.matchAll(new RegExp(writes.source, 'g'))].map((m) => m[1]);
  assert.deepEqual([...new Set(used)], ['mkdirSync'], 'runner.cjs creates one directory and no file by writing');
  assert.equal([...r.matchAll(/mkdirSync\(([^)]*)\)/g)].every((m) => /\.foreman-run/.test(m[1])), true, 'and that directory is .foreman-run');
  assert.equal([...r.matchAll(/\bopenSync\(/g)].length, 1, 'runner.cjs opens one file');
  assert.match(r, /openSync\(outPath\(batch\), 'w'\)/, 'and it is out, for writing');
  assert.doesNotMatch(r, /foreman\.conf/, 'runner.cjs never names foreman.conf');
});
