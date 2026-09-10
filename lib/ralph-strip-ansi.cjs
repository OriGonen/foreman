// Removing terminal control codes from an agent payload.
//
// In sandbox modes `sbx run` prints its own "Starting claude agent..." / "Workspace: ..."
// banner to stdout ahead of the JSON, and wraps it in terminal control codes (set-title,
// clear-screen, cursor-home) with no newline separating them from the `{` — which hides the
// object's start from a line-anchored search. In `local` mode there is no banner and this
// all reduces to a no-op.
//
// Shared by ralph-record.cjs, which strips a whole payload once at the end, and by
// ralph-stream.cjs, which has to do it per line. One copy: two would drift, and the second
// one to drift would be the one nobody is watching.

const stripAnsi = (s) =>
  String(s)
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, '') // OSC ... BEL/ST (e.g. set title)
    .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, '') // CSI ... letter (e.g. clear, cursor)
    .replace(/\x1b[()][A-Za-z0-9]/g, '') // charset select
    .replace(/\x1b./g, ''); // any other two-char escape

module.exports = stripAnsi;
