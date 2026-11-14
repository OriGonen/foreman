'use strict';
// What main reads for a ticket's page, and the one file the app ever writes: the handoff file a
// human ticket names on its `Handoff:` line.
//
// The page never names a path. It names a batch and a ticket (by its name, which a `DONE_` rename
// does not change), and main finds the file and the handoff path in `foreman status --json` — the
// CLI's own reading of the ticket — so a page that has been fed something odd cannot ask for another
// file. Every path is then held to `resolveInside`: repo-relative, no `..`, no drive letter, and,
// once symlinks are followed, still inside the repository.
//
// Saving does not overwrite what it has not seen. The page sends the text it was based on; if the
// file on disk is not that any more, nothing is written and the text now on disk is handed back, for
// the person to decide (spec: "Changes made on disk while the page is open").
const fs = require('fs');
const path = require('path');
const { ForemanError } = require('./foreman.cjs');

const MAX_BYTES = 2 * 1024 * 1024;       // a handoff file is a page of notes, not a data store

const refuse = (rel, why) => new ForemanError('bad-handoff', `refusing ${JSON.stringify(rel)}: ${why}`);

// The real path of a repo-relative file (which need not exist yet), or a ForemanError('bad-handoff').
// Walks up to the deepest part that does exist, resolves symlinks there, and requires the result to
// be inside the repository's own real path. A link that points at nothing is refused: writing
// through it would create the file wherever it points.
function resolveInside(repoRoot, rel, io = fs) {
  if (typeof rel !== 'string' || rel === '') throw refuse(rel, 'no path');
  if (rel.includes('\0')) throw refuse(rel, 'has a NUL');
  if (rel.includes('\\')) throw refuse(rel, 'has a backslash; paths are written with forward slashes');
  if (rel.startsWith('/') || /^[A-Za-z]:/.test(rel)) throw refuse(rel, 'is an absolute path; it must be inside the repository');
  const segments = rel.split('/').filter((s) => s !== '' && s !== '.');
  if (segments.length === 0) throw refuse(rel, 'no path');
  if (segments.includes('..')) throw refuse(rel, 'reaches out of the repository with ..');
  if (segments.some((s) => s.toLowerCase() === '.git')) throw refuse(rel, 'is inside .git');

  let realRoot;
  try { realRoot = io.realpathSync(path.resolve(repoRoot)); } catch (e) {
    throw refuse(rel, `the repository cannot be read (${e.code || e.message})`);
  }
  let probe = path.join(realRoot, ...segments);
  const rest = [];
  for (;;) {
    try { probe = io.realpathSync(probe); break; } catch (e) {
      if (e.code !== 'ENOENT' && e.code !== 'ENOTDIR') throw refuse(rel, `cannot be read (${e.code || e.message})`);
      let isLink = false;
      try { isLink = io.lstatSync(probe).isSymbolicLink(); } catch { /* not there at all */ }
      if (isLink) throw refuse(rel, 'is a link to something that is not there');
      const up = path.dirname(probe);
      if (up === probe) throw refuse(rel, 'is not inside the repository');
      rest.unshift(path.basename(probe));
      probe = up;
    }
  }
  const full = path.join(probe, ...rest);
  const from = path.relative(realRoot, full);
  if (from === '' || from === '..' || from.startsWith('..' + path.sep) || path.isAbsolute(from)) {
    throw refuse(rel, 'resolves to a place outside the repository');
  }
  return full;
}

// CRLF if most of the line ends are CRLF; otherwise (and for no line ends at all) LF.
function detectEol(text) {
  if (typeof text !== 'string') return '\n';
  const crlf = (text.match(/\r\n/g) || []).length;
  const lf = (text.match(/\n/g) || []).length - crlf;
  return crlf > lf ? '\r\n' : '\n';
}

function toEol(text, eol) {
  return text.replace(/\r\n|\r|\n/g, eol);
}

// null for a file that is not there; anything else that stops it being read is an error.
function readOrNull(file, io) {
  try { return io.readFileSync(file, 'utf8'); } catch (e) {
    if (e.code === 'ENOENT') return null;
    throw e;
  }
}

// `known(batch)` is the status the overview read last, or null: reading a page uses it, so a file
// changing does not start another foreman for the same answer. Saving never does — it asks again.
function createTicketFiles({ repoRoot, foreman, known = () => null, io = fs }) {
  const find = (status, name) => (typeof name === 'string' && status && Array.isArray(status.tickets)
    ? status.tickets.find((t) => t.name === name) : undefined);

  async function ticketOf(batch, name, { fresh }) {
    let ticket = fresh ? undefined : find(known(batch), name);
    if (!ticket) ticket = find(await foreman.status(batch), name);
    if (!ticket) throw new ForemanError('no-ticket', `there is no ticket ${JSON.stringify(name)} in ${batch}`);
    return ticket;
  }

  return {
    // The ticket's text and notes, and for a human ticket its handoff file. A handoff the path check
    // refuses is not read: the refusal is the answer, to be shown as text.
    async load(batch, name) {
      const ticket = await ticketOf(batch, name, { fresh: false });
      let text;
      try {
        text = readOrNull(resolveInside(repoRoot, ticket.file, io), io);
      } catch (e) {
        throw new ForemanError('read', `could not read ${ticket.file}: ${e.message}`);
      }
      if (text === null) throw new ForemanError('read', `could not read ${ticket.file}: it is not there (the loop may have renamed it; it is read again when the files change)`);

      let progress = null;
      try { progress = readOrNull(resolveInside(repoRoot, `${batch}/progress.txt`, io), io); } catch { /* an unreadable note file is no notes */ }

      let handoff = null;
      if (ticket.human && ticket.handoff) {
        handoff = { path: ticket.handoff, text: null, error: null };
        try { handoff.text = readOrNull(resolveInside(repoRoot, ticket.handoff, io), io); } catch (e) {
          handoff.error = e.message;
        }
      }
      return { name: ticket.name, file: ticket.file, text, progress, handoff };
    },

    // Write the handoff. `base` is the text the page's editor was opened on (null: there was no file).
    // Resolves { saved: true, text } with the text as written, or { saved: false, conflict: true,
    // disk } — the file is not what `base` says — having written nothing. Anything else is thrown.
    async save(batch, name, text, base) {
      if (typeof text !== 'string' || (base !== null && typeof base !== 'string') || text.length > MAX_BYTES) {
        throw new ForemanError('bad-text', 'a handoff is saved as text, up to 2 MB');
      }
      const ticket = await ticketOf(batch, name, { fresh: true });
      if (!ticket.human || !ticket.handoff) {
        throw new ForemanError('no-handoff', `${ticket.name} is not a human ticket with a Handoff: line, so there is no file to save`);
      }
      const file = resolveInside(repoRoot, ticket.handoff, io);
      const ticketFile = resolveInside(repoRoot, ticket.file, io);
      if (file === ticketFile) throw refuse(ticket.handoff, 'that is the ticket itself, which is only ever edited in your own editor');
      if (path.basename(file).toLowerCase() === 'foreman.conf') throw refuse(ticket.handoff, 'foreman.conf is only ever edited in your own editor');

      let disk;
      try { disk = readOrNull(file, io); } catch (e) {
        throw refuse(ticket.handoff, e.code === 'EISDIR' ? 'it is a folder' : `cannot be read (${e.code || e.message})`);
      }
      if (disk !== base) return { saved: false, conflict: true, disk };

      const out = toEol(text, disk === null ? '\n' : detectEol(disk));
      io.mkdirSync(path.dirname(file), { recursive: true });
      io.writeFileSync(file, out, 'utf8');
      return { saved: true, text: out };
    },
  };
}

module.exports = { resolveInside, detectEol, toEol, createTicketFiles, MAX_BYTES };
