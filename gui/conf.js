'use strict';
// The one place the app reads a batch's foreman.conf. The CLI does not parse that file, it `source`s it
// (lib/foreman-config.sh), so what this does is what a text reader can do to land on the same answer:
//
//   - the LAST assignment of a name wins (`X=5` then `X=50` is 50);
//   - an optional leading `export`, surrounding quotes and a trailing ` # comment` are not part of the value;
//   - FOREMAN_<knob> beats the legacy RALPH_<knob> (lib/foreman-legacy.sh copies RALPH_ onto FOREMAN_ only
//     when FOREMAN_ is not set already), wherever in the file each one is; and in the environment the same,
//     with the environment ranked above the file (the CLI puts it back after sourcing);
//   - `${X:-default}` is the default: this cannot know X;
//   - a batch with no foreman.conf has its ralph.conf read (lib/foreman-repo.sh).
//
// It does not run shell. A value it cannot know (`$(cat x)`, `$((1+1))`, `${X}`) comes back as the text that
// is there, which no caller mistakes for a number or a known mode: "unknown", as the old readers had it.
//
// Loaded two ways, like model.js: as a plain <script> (it puts `ForemanConf` on the window) and with
// require() in main and the tests. No DOM and no Node in here: the file system is handed in.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.ForemanConf = factory();
}(typeof self !== 'undefined' ? self : this, function () {

  // One shell word from the start of `s`, quotes removed and `${X:-d}` expanded to d. It stops at the first
  // unquoted blank or `;` — the rest of the line is another word, or a comment. `inner` is for the default of
  // a `${X:-...}`, which is read to its end.
  function word(s, inner) {
    let out = '', q = null, i = 0;
    while (i < s.length) {
      const c = s[i];
      if (q === "'") {
        if (c === "'") q = null; else out += c;
        i++; continue;
      }
      if (q === '"') {
        if (c === '"') { q = null; i++; continue; }
        if (c === '\\' && i + 1 < s.length && '"\\$`'.includes(s[i + 1])) { out += s[i + 1]; i += 2; continue; }
      } else {
        if (c === "'" || c === '"') { q = c; i++; continue; }
        if (c === '\\' && i + 1 < s.length) { out += s[i + 1]; i += 2; continue; }
        if (!inner && (c === ' ' || c === '\t' || c === ';')) break;
      }
      if (c === '$' && s[i + 1] === '{') {
        let depth = 1, j = i + 2;
        while (j < s.length && depth > 0) { if (s[j] === '{') depth++; else if (s[j] === '}') depth--; j++; }
        if (depth === 0) {
          const body = s.slice(i + 2, j - 1);
          const m = /^([A-Za-z_][A-Za-z0-9_]*)(:?-)([\s\S]*)$/.exec(body);
          out += m ? word(m[3], true) : s.slice(i, j);
          i = j; continue;
        }
      }
      out += c; i++;
    }
    return out;
  }

  // Every assignment of FOREMAN_<suffix> or RALPH_<suffix> in the text, in file order.
  function assignments(confText, suffix) {
    const re = new RegExp('^[ \\t]*(?:export[ \\t]+)?(FOREMAN|RALPH)_' + suffix.replace(/[^A-Za-z0-9_]/g, '') + '=(.*)$');
    const found = [];
    for (const line of String(confText).split('\n')) {
      const m = re.exec(line.replace(/\r$/, ''));
      if (m) found.push({ prefix: m[1], value: word(m[2], false) });
    }
    return found;
  }

  const suffixOf = (name) => String(name).replace(/^(?:FOREMAN|RALPH)_/, '');

  // What the conf text sets a knob to: a string, or undefined when it does not set it. `name` is the knob
  // with either prefix (FOREMAN_EXEC or RALPH_EXEC: the same knob). FOREMAN_ wins over RALPH_, and the
  // last assignment of each wins.
  function confValue(confText, name) {
    if (typeof confText !== 'string') return undefined;
    let foreman, ralph;
    for (const a of assignments(confText, suffixOf(name))) {
      if (a.prefix === 'FOREMAN') foreman = a.value; else ralph = a.value;
    }
    return foreman !== undefined ? foreman : ralph;
  }

  // The value a knob has for a run, the way the CLI ranks the places: the environment (FOREMAN_ first, then
  // RALPH_; a blank variable is not set), then the conf, else nowhere.
  //   -> { source: 'environment' | 'conf' | null, value: string | null }
  function knob(confText, name, env) {
    const e = env || {};
    const sfx = suffixOf(name);
    for (const prefix of ['FOREMAN', 'RALPH']) {
      const v = e[`${prefix}_${sfx}`];
      if (v !== undefined && v !== null && String(v).trim() !== '') return { source: 'environment', value: String(v).trim() };
    }
    const c = confValue(confText, name);
    return c === undefined ? { source: null, value: null } : { source: 'conf', value: c };
  }

  // The text of a batch's conf: foreman.conf, or ralph.conf when that is all it has. null when neither can be
  // read. `fs` is anything with readFileSync; `dir` is the batch's full path.
  function readBatchConf(fs, dir) {
    for (const name of ['foreman.conf', 'ralph.conf']) {
      try { return fs.readFileSync(`${dir}/${name}`, 'utf8'); } catch { /* not there: the next */ }
    }
    return null;
  }

  return { confValue, knob, readBatchConf };
}));
