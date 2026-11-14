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

// A `dry-run --json` object for the same batch: 05 and 06 would run (no iteration limit), and the run
// would stop at 07, the human ticket, with 07a, 08 and 09 behind it.
function dryRunSample() {
  const E = (number, slug, state, extra = {}) => ({
    file: `.scratch/b/issues/${number}-${slug}.md`, name: `${number}-${slug}`, number, slug, title: slug,
    human: false, checks: null, handoff: null, state, ...extra,
  });
  const remaining = [
    E('05', 'document-human-tickets', 'run'),
    E('06', 'doctor-human-warnings', 'run'),
    E('07', 'try-it-on-a-real-repo', 'stop', { human: true, handoff: '.scratch/b/handoff/07-try-it-on-a-real-repo.md' }),
    E('07a', 'followup-try-the-followup-skill', 'later', { checks: '07-try-it-on-a-real-repo.md' }),
    E('08', 'readme-human-tickets-section', 'later'),
    E('09', 'end-to-end-check', 'later'),
  ];
  const strip = ({ state, ...rest }) => rest;
  const prompt = '@.scratch/b/issues/05-document-human-tickets.md\n\nImplement the attached ticket, and only that ticket,\nto a high standard.\n\n    indented <b>line</b>\n';
  return {
    foreman_json: 1, command: 'dry-run', repo_root: 'C:/Projects/app', batch: { path: '.scratch/b', name: 'b' },
    counts: { done: 4, total: 10 },
    would_run: { tickets: remaining.slice(0, 2).map(strip), remaining, stops_at: { ...strip(remaining[2]), reached: true } },
    settings: {
      exec: 'local', perms: 'acceptEdits', model: 'claude-sonnet-5-5', effort: 'high', live: false,
      budgets: { cost_usd: 25, minutes: 90, iterations: null, text: 'cost=$25  time=90m  iterations=unlimited' },
      logs: { jsonl: '.scratch/b/foreman-runs.jsonl', log: '.scratch/b/foreman-runs.log' },
    },
    warnings: [],
    prompt: { for: remaining[0].file, text: prompt, lines: prompt.split('\n').length },
  };
}

// `report --json` objects, as the CLI prints them for test/golden/report-runs.jsonl (three runs, seven
// iterations and a checkpoint turn, one unreadable line): by run, by ticket, and the `run` that
// `--run 20261022T140533Z-9020` adds.
const REPORT = {"foreman_json":1,"command":"report","batch":{"path":"batch","name":"batch"},"log":"batch/foreman-runs.jsonl","by":"run","totals":{"runs":3,"iterations":7,"landed":3,"progressed":1,"stalled":1,"unproductive":2,"checkpoints":1,"limit_hits":1,"unreadable":1,"tokens":{"input":21200,"output":146300,"cache_read":5820000,"cache_write":432000,"billed":167500},"cost_usd":6.95,"minutes":48.2,"turns":220,"per_iteration":{"cost_usd":0.9928571428571429,"billed_tokens":23929}},"rows":[{"id":"20261021T091200Z-4411","started_at":"2026-10-21T09:12:00Z","iterations":2,"landed":2,"progressed":0,"stalled":0,"unproductive":0,"checkpoints":0,"limit_hits":0,"tokens":{"input":7000,"output":50000,"cache_read":2000000,"cache_write":150000,"billed":57000},"cost_usd":2,"minutes":18,"turns":70},{"id":"20261022T140533Z-9020","started_at":"2026-10-22T14:05:33Z","iterations":3,"landed":1,"progressed":1,"stalled":0,"unproductive":1,"checkpoints":1,"limit_hits":1,"tokens":{"input":12500,"output":93000,"cache_read":3650000,"cache_write":265000,"billed":105500},"cost_usd":4.25,"minutes":28.5,"turns":137},{"id":"20261023T081014Z-1207","started_at":"2026-10-23T08:10:14Z","iterations":2,"landed":0,"progressed":0,"stalled":1,"unproductive":1,"checkpoints":0,"limit_hits":0,"tokens":{"input":1700,"output":3300,"cache_read":170000,"cache_write":17000,"billed":5000},"cost_usd":0.7,"minutes":1.7,"turns":13}]};
const REPORT_BY_TICKET = {"foreman_json":1,"command":"report","batch":{"path":"batch","name":"batch"},"log":"batch/foreman-runs.jsonl","by":"ticket","totals":{"runs":3,"iterations":7,"landed":3,"progressed":1,"stalled":1,"unproductive":2,"checkpoints":1,"limit_hits":1,"unreadable":1,"tokens":{"input":21200,"output":146300,"cache_read":5820000,"cache_write":432000,"billed":167500},"cost_usd":6.95,"minutes":48.2,"turns":220,"per_iteration":{"cost_usd":0.9928571428571429,"billed_tokens":23929}},"rows":[{"id":"batch/issues/01-first.md","iterations":1,"landed":1,"progressed":0,"stalled":0,"unproductive":0,"checkpoints":0,"limit_hits":0,"tokens":{"input":4000,"output":30000,"cache_read":1200000,"cache_write":90000,"billed":34000},"cost_usd":1.25,"minutes":10,"turns":40},{"id":"batch/issues/02-second.md","iterations":1,"landed":1,"progressed":0,"stalled":0,"unproductive":0,"checkpoints":0,"limit_hits":0,"tokens":{"input":3000,"output":20000,"cache_read":800000,"cache_write":60000,"billed":23000},"cost_usd":0.75,"minutes":8,"turns":30},{"id":"batch/issues/03-third.md","iterations":2,"landed":1,"progressed":1,"stalled":0,"unproductive":0,"checkpoints":0,"limit_hits":0,"tokens":{"input":11000,"output":90000,"cache_read":3500000,"cache_write":250000,"billed":101000},"cost_usd":3.5,"minutes":27,"turns":125},{"id":"batch/issues/04-fourth.md","iterations":1,"landed":0,"progressed":0,"stalled":0,"unproductive":1,"checkpoints":1,"limit_hits":1,"tokens":{"input":1500,"output":3000,"cache_read":150000,"cache_write":15000,"billed":4500},"cost_usd":0.75,"minutes":1.5,"turns":12},{"id":"batch/issues/05-fifth.md","iterations":2,"landed":0,"progressed":0,"stalled":1,"unproductive":1,"checkpoints":0,"limit_hits":0,"tokens":{"input":1700,"output":3300,"cache_read":170000,"cache_write":17000,"billed":5000},"cost_usd":0.7,"minutes":1.7,"turns":13}]};
const REPORT_RUN = {"id":"20261022T140533Z-9020","started_at":"2026-10-22T14:05:33Z","iterations":[{"iteration":1,"kind":"iteration","ticket":"batch/issues/03-third.md","outcome":"progressed","flags":[],"limit_hit":false,"cost_usd":2,"duration_ms":900000,"turns":70,"exit_status":0,"started_at":"2026-10-22T14:05:33Z"},{"iteration":2,"kind":"iteration","ticket":"batch/issues/03-third.md","outcome":"landed","flags":[],"limit_hit":false,"cost_usd":1.5,"duration_ms":720000,"turns":55,"exit_status":0,"started_at":"2026-10-22T14:30:00Z"},{"iteration":3,"kind":"iteration","ticket":"batch/issues/04-fourth.md","outcome":"unproductive","flags":["error","limit"],"limit_hit":true,"cost_usd":0.5,"duration_ms":60000,"turns":8,"exit_status":1,"started_at":"2026-10-22T15:00:00Z"},{"iteration":3,"kind":"checkpoint","ticket":"batch/issues/04-fourth.md","outcome":"checkpoint","flags":[],"limit_hit":false,"cost_usd":0.25,"duration_ms":30000,"turns":4,"exit_status":0,"started_at":"2026-10-22T15:05:00Z"}]};
const reportSample = () => structuredClone(REPORT);
const reportByTicketSample = () => structuredClone(REPORT_BY_TICKET);
// The answer to `--run <id>`: the whole report, with the run added.
const reportRunSample = () => ({ ...structuredClone(REPORT), run: structuredClone(REPORT_RUN) });

// What `status --json` adds to a ticket that ran (ticket 16): 03 of the sample, as design 02's b3 shows
// it — three iterations in one run, the middle one a stall and a checkpoint turn after it.
function statsSample() {
  return {
    iterations: 3, cost_usd: 4.62, duration_ms: 1710000, turns: 112,
    tokens: { input: 310000, output: 46000, cache_read: 4100000, cache_creation: 380000 },
    models: ['claude-sonnet-5-5'],
    runs: [
      { run: '20261021T091200Z-4411', kind: 'iteration', outcome: 'progressed', cost_usd: 1.64, duration_ms: 675000, started_at: '2026-10-21T09:12:00Z', finished_at: '2026-10-21T09:23:15Z' },
      { run: '20261021T091200Z-4411', kind: 'iteration', outcome: 'stalled', cost_usd: 1.48, duration_ms: 490000, started_at: '2026-10-21T09:23:20Z', finished_at: '2026-10-21T09:31:30Z' },
      { run: '20261021T091200Z-4411', kind: 'checkpoint', outcome: 'checkpoint', cost_usd: 0.2, duration_ms: 40000, started_at: '2026-10-21T09:31:31Z', finished_at: '2026-10-21T09:32:11Z' },
      { run: '20261021T091200Z-4411', kind: 'iteration', outcome: 'landed', cost_usd: 1.3, duration_ms: 505000, started_at: '2026-10-21T09:32:20Z', finished_at: '2026-10-21T09:40:45Z' },
    ],
  };
}

// What `foreman doctor --json` prints for a repo with one thing `--fix` can write, a stale skill copy,
// and a batch that is fine. `doctorSample('ready')` is the same repo with nothing wrong; 'blocked' has
// a blocker `--fix` cannot write.
const GITIGNORE_TEXT = '# Foreman: per-batch run state.\n**/.foreman-iter.bundle\n**/.foreman-stall-marker\n**/foreman-runs.jsonl\n**/foreman-runs.log\n';
function doctorSample(kind = 'fixable') {
  const ok = (label, detail = '') => ({ result: 'ok', label, detail, fix: null, auto: false, notes: [] });
  const fixable = kind === 'fixable';
  const blocked = kind === 'blocked';
  const doc = {
    foreman_json: 1, command: 'doctor', repo: 'C:/Projects/app', rev: 'd0d6874', date: '2026-10-21',
    sections: [
      { id: 'machine', title: 'Machine', info: [], rows: [ok('git'), ok('node'), ok('awk'), ok('bash 5.2.26 (4+ required)'), ok('sbx (required by FOREMAN_EXEC=sandbox)')] },
      { id: 'repository', title: 'Repository', info: [], rows: [
        ok('.foreman-iter.bundle ignored'),
        fixable
          ? { result: 'fail', label: 'foreman-runs.log not ignored', detail: '', fix: 'foreman doctor --fix appends it to .gitignore', auto: true, notes: ['run state would show up as changes'] }
          : ok('foreman-runs.log ignored'),
        ok('.gitattributes keeps foreman.conf LF'),
      ] },
      { id: 'skill', title: 'Skill', info: [], rows: [
        { result: 'warn', label: 'foreman-conf-commands — installed copy differs from skills/foreman-conf-commands/SKILL.md', detail: '', fix: 'run: bash C:/tools/foreman/install.sh', auto: false, notes: [] },
        ok('foreman-human-followup-tickets copy is current'),
      ] },
      { id: 'batches', title: 'Batches', info: [], rows: [
        ok('gui', '3 of 14 done'),
        ...(blocked ? [{ result: 'fail', label: 'other/foreman.conf — FOREMAN_EXEC=local with no way for the agent to commit', detail: '', fix: 'Add to other/foreman.conf: FOREMAN_CLAUDE_ARGS=(--allowed-tools "Bash(git add:*)")', auto: false, notes: ['acceptEdits does not cover Bash'] }] : []),
      ] },
    ],
    counts: { ok: 10, warn: 1, fail: fixable ? 1 : blocked ? 1 : 0 },
    verdict: fixable
      ? { passed: false, label: 'NOT PASSED', detail: '1 to fix', fixable: 1, blockers: 0 }
      : blocked
        ? { passed: false, label: 'NOT PASSED', detail: '1 blocker', fixable: 0, blockers: 1 }
        : { passed: true, label: 'PASSED', detail: 'ready to run', fixable: 0, blockers: 0 },
    next: fixable ? { label: 'fix', command: 'foreman doctor --fix' } : blocked ? null : { label: 'next', command: 'foreman run .scratch/gui' },
    plan: fixable ? [{ file: '.gitignore', text: GITIGNORE_TEXT, why: 'the repo does not ignore foreman\'s run state (1 of 4 lines missing), so a run\'s files would show up as changes' }] : [],
    credentials: [{ name: 'FOREMAN_DOCKER_USERNAME', state: 'unset' }, { name: 'FOREMAN_DOCKER_PAT', state: 'unset' }],
  };
  return doc;
}

module.exports = { statsSample, sample, dryRunSample, reportSample, reportByTicketSample, reportRunSample, doctorSample, T };
