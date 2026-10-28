// Reads one `claude --print --output-format json` reply on stdin and prints four lines:
// is_error (1/0), the cost to four places (empty when the reply has none), the agent's own
// message as one line of at most 300 characters, and whether that message is a login failure
// (1/0).
//
// `subtype` is no use here — a failed call can say "success" next to is_error:true — so
// is_error and result are what count. Output that is not JSON at all is kept as its last few
// lines, the best account of the failure there is.
//
// Shared by foreman-order.sh and foreman-commands.sh, the two one-off agent passes
// `foreman init` runs, so both read a reply — and a failed one — the same way.

const AUTH_PATTERNS = require('./foreman-auth-patterns.cjs');

const text = require('fs').readFileSync(0, 'utf8');
let isError = false, cost = '', said = '';
try {
  const p = JSON.parse(text);
  isError = p.is_error === true;
  if (typeof p.total_cost_usd === 'number') cost = p.total_cost_usd.toFixed(4);
  said = typeof p.result === 'string' ? p.result : '';
} catch {
  said = text.split('\n').map((l) => l.trim()).filter(Boolean).slice(-5).join(' ');
}
said = said.replace(/\s+/g, ' ').trim();
const auth = AUTH_PATTERNS.some((s) => said.toLowerCase().includes(s));
console.log(isError ? 1 : 0);
console.log(cost);
console.log(said.length > 300 ? said.slice(0, 297) + '...' : said);
console.log(auth ? 1 : 0);
