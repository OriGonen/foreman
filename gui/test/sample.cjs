'use strict';
// A `status --json` object to test the screens against: the design's sample, 4 of 10 landed, 05
// next, 07 a human ticket with 07a its followup.

const T = (number, slug, extra = {}) => ({
  file: `.scratch/b/issues/${number}-${slug}.md`, name: `${number}-${slug}`, number, slug,
  title: slug, status: 'ready-for-agent', state: 'todo', done: false, human: false,
  blocked_by: 'None — can start immediately', checks: null, handoff: null, spent_usd: null, ...extra,
});

// 4 of 10 landed, 05 next, 07 a human ticket with 07a its followup (the design's sample).
function sample() {
  const tickets = [
    T('01', 'human-ticket-status', { state: 'done', done: true, status: 'done', spent_usd: 1.12 }),
    T('02', 'handoff-file-path', { state: 'done', done: true, status: 'done', spent_usd: 2.4 }),
    T('03', 'stop-on-waiting-human', { state: 'done', done: true, status: 'done', spent_usd: 3.08 }),
    T('04', 'sent-back-detection', { state: 'done', done: true, status: 'done', spent_usd: 3.24 }),
    T('05', 'document-human-tickets', { state: 'next', blocked_by: '04' }),
    T('06', 'doctor-human-warnings'),
    T('07', 'try-it-on-a-real-repo', { human: true, status: 'ready-for-human', handoff: '.scratch/b/handoff/07-try-it-on-a-real-repo.md' }),
    T('07a', 'followup-try-the-followup-skill', { checks: '07-try-it-on-a-real-repo.md', blocked_by: '07' }),
    T('08', 'readme-human-tickets-section'),
    T('09', 'end-to-end-check'),
  ];
  return {
    foreman_json: 1, command: 'status', repo_root: 'C:/Projects/app', batch: { path: '.scratch/b', name: 'b' },
    counts: { done: 4, total: 10 }, next: { file: tickets[4].file, human: false, handoff: null, sent_back_by: null },
    human_remaining: 1,
    run_until: { tickets: 2, stop: tickets[6].file, text: 'The loop will run 2 ticket(s), then stop at 07-try-it-on-a-real-repo.md for a human.' },
    warnings: [], spent_usd: 9.84, runs: 2, tickets,
    last_run: { id: '20261021-2', end: 'paused', exit: 10, reason: 'iteration budget reached' }, run: null,
  };
}

module.exports = { sample, T };
