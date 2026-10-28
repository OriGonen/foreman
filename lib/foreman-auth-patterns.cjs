// The strings that say the agent's own login is gone: an expired or revoked OAuth session,
// or a bad API key. Lowercase, matched against lowercased text.
//
// Shared by foreman-record.cjs, which classifies an iteration's failure with them, and by
// foreman-claude-reply.cjs, which `foreman order` and `foreman commands` use to tell the
// user to log in again. One list: two would
// drift, and a login error would then be recognised by one and missed by the other.

module.exports = [
  'failed to authenticate',
  'oauth session expired',
  'oauth token has expired',
  'invalid api key',
  'authentication_error',
  'please run /login'
];
