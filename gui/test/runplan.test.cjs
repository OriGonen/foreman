'use strict';
// runplan.js: what a run is asked to do and what the confirmation says. No DOM, no process.
const test = require('node:test');
const assert = require('node:assert/strict');
const R = require('../runplan.js');
const { dryRunSample } = require('./sample.cjs');

const facts = (over = {}) => ({
  dry: dryRunSample(), confText: 'FOREMAN_MAX_COST_USD=25\nFOREMAN_MAX_MINUTES=90\n', env: {}, ignored: true, inFlight: false, ...over,
});
const base = (f) => R.start(f);

// ---- the fields ----

test('minutes: a whole number, normalised, 0 is allowed; anything else is refused with words', () => {
  assert.deepEqual(R.checkMinutes('90'), { ok: true, value: '90' });
  assert.deepEqual(R.checkMinutes(' 0 '), { ok: true, value: '0' });
  assert.deepEqual(R.checkMinutes('007'), { ok: true, value: '7' }, 'no leading zeros: bash would read 08 as octal');
  for (const bad of ['', '1.5', '-3', '1e3', '90m', 'ninety', '1,5', '1234567', '٣']) {
    const r = R.checkMinutes(bad);
    assert.equal(r.ok, false, JSON.stringify(bad));
    assert.ok(r.message.length > 10, 'it says what is wrong');
  }
});

test('dollars: up to two decimals, an optional $, normalised; anything else is refused', () => {
  assert.deepEqual(R.checkDollars('10'), { ok: true, value: '10' });
  assert.deepEqual(R.checkDollars('10.5'), { ok: true, value: '10.5' });
  assert.deepEqual(R.checkDollars('$ 10.50'), { ok: true, value: '10.50' });
  assert.deepEqual(R.checkDollars('0'), { ok: true, value: '0' });
  assert.deepEqual(R.checkDollars('0.05'), { ok: true, value: '0.05' });
  assert.deepEqual(R.checkDollars('010.25'), { ok: true, value: '10.25' });
  for (const bad of ['', '10.505', '.5', '5.', '1e2', '-1', '10 dollars', '1,000', '$', '$$5', '1234567']) {
    assert.equal(R.checkDollars(bad).ok, false, JSON.stringify(bad));
  }
});

test('iterations: from 1, or unlimited', () => {
  assert.deepEqual(R.checkIterations('3'), { ok: true, value: 3 });
  assert.deepEqual(R.checkIterations(3), { ok: true, value: 3 });
  assert.deepEqual(R.checkIterations('unlimited'), { ok: true, value: null });
  assert.deepEqual(R.checkIterations(null), { ok: true, value: null });
  for (const bad of ['0', '', '-1', '2.5', 'many', '10000', undefined]) assert.equal(R.checkIterations(bad).ok, false, String(bad));
});

// ---- the request, the arguments, the environment, the command ----

test('the budget field is the <n|--unlimited> argument, and the live field decides --live', () => {
  const p = (r) => R.planFrom(r).plan;
  assert.deepEqual(R.runArgs('.scratch/b', p({ iterations: 3, live: true })), ['run', '.scratch/b', '3', '--live']);
  assert.deepEqual(R.runArgs('.scratch/b', p({ iterations: 3, live: false })), ['run', '.scratch/b', '3']);
  assert.deepEqual(R.runArgs('.scratch/b', p({ iterations: null, live: true })), ['run', '.scratch/b', '--unlimited', '--live']);
});

test('a request is refused whole when any part of it is not understood', () => {
  assert.equal(R.planFrom({ iterations: 0 }).ok, false);
  assert.equal(R.planFrom({ iterations: 2, caps: { cost: '1.234' } }).ok, false);
  assert.equal(R.planFrom({ iterations: 2, caps: { minutes: '1.5' } }).ok, false);
  assert.equal(R.planFrom({}).ok, false, 'no iterations is not "one"');
  assert.equal(R.planFrom(null).ok, false);
  assert.equal(R.planFrom({ iterations: 2, caps: { cost: '1; rm -rf /' } }).ok, false);
});

test('building the env and the command, without and with an edited cap', () => {
  const none = R.planFrom({ iterations: 3, live: true }).plan;
  assert.deepEqual(R.capEnv(none), {}, 'no edit: nothing is passed, the file decides');
  assert.deepEqual(R.command('.scratch/b', none), { prefix: [], text: 'foreman run .scratch/b 3 --live', full: 'foreman run .scratch/b 3 --live' });

  const one = R.planFrom({ iterations: 3, live: true, caps: { cost: '$10.50' } }).plan;
  assert.deepEqual(R.capEnv(one), { FOREMAN_MAX_COST_USD: '10.50' });
  assert.equal(R.command('.scratch/b', one).full, 'FOREMAN_MAX_COST_USD=10.50 foreman run .scratch/b 3 --live');

  const both = R.planFrom({ iterations: null, live: false, caps: { cost: '0', minutes: '045' } }).plan;
  assert.deepEqual(R.capEnv(both), { FOREMAN_MAX_COST_USD: '0', FOREMAN_MAX_MINUTES: '45' });
  assert.equal(R.command('b', both).full, 'FOREMAN_MAX_COST_USD=0 FOREMAN_MAX_MINUTES=45 foreman run b --unlimited');
});

// ---- the confirmation ----

test('up front: the budget starts from the dry run, the caps are not edits, and the button names the file\'s cap', () => {
  const f = facts();
  const v = R.view(f, base(f));
  assert.equal(v.batch, '.scratch/b');
  assert.equal(v.startsAt, '05 document-human-tickets');
  assert.equal(v.iterations.text, 'unlimited', 'the dry run says iterations: null for unlimited');
  assert.equal(v.button, 'Start run · up to $25.00');
  assert.equal(v.command.full, 'foreman run .scratch/b --unlimited --live');
  assert.equal(v.edited, false);
  assert.equal(v.blocked, null);
  assert.deepEqual(v.plan.caps, { cost: null, minutes: null });
});

test('where a cap is set: the environment first, then foreman.conf, else none set', () => {
  const src = (name, confText, env) => R.capSource(name, { confText, env });
  assert.equal(src(R.COST, 'FOREMAN_MAX_COST_USD=25\n', {}).kind, 'conf');
  assert.equal(src(R.COST, '  export FOREMAN_MAX_COST_USD=25\n', {}).kind, 'conf');
  assert.equal(src(R.COST, '#FOREMAN_MAX_COST_USD=25\n', {}).kind, 'none', 'a commented line is not a setting');
  assert.equal(src(R.COST, 'X=1\n', {}).kind, 'none');
  assert.equal(src(R.COST, 'FOREMAN_MAX_COST_USD=25\n', { FOREMAN_MAX_COST_USD: '5' }).kind, 'environment');
  assert.equal(src(R.COST, 'FOREMAN_MAX_COST_USD=25\n', { FOREMAN_MAX_COST_USD: '  ' }).kind, 'conf', 'a blank variable is not set');
  assert.equal(src(R.MINUTES, 'FOREMAN_MAX_COST_USD=25\n', {}).text, 'not set · 0 = no cap');
});

test('a cap with no value anywhere says "none set", and the button says no spend cap', () => {
  const dry = dryRunSample();
  dry.settings.budgets.cost_usd = null;
  dry.settings.budgets.minutes = null;
  const f = facts({ dry, confText: '' });
  const v = R.view(f, base(f));
  assert.equal(v.cost.unset, true);
  assert.equal(v.minutes.unset, true);
  assert.equal(v.cost.source.kind, 'none');
  assert.equal(v.button, 'Start run · no spend cap');
});

test('a spend cap lowered for this run: it says so, has a way back, is in the command, and drives the button', () => {
  const f = facts();
  const v = R.view(f, { ...base(f), iterations: '3', cost: '10' });
  assert.equal(v.cost.changed, true);
  assert.equal(v.cost.rust, false, 'lowering a cap is not a warning');
  assert.equal(v.cost.reset, '$25.00');
  assert.equal(v.button, 'Start run · up to $10.00');
  assert.equal(v.command.full, 'FOREMAN_MAX_COST_USD=10 foreman run .scratch/b 3 --live');
  assert.deepEqual(v.plan.caps, { cost: '10', minutes: null });
  assert.equal(v.edited, true);
});

test('a value equal to the file\'s is not an edit: 25 and 25.00 are the same cap', () => {
  const f = facts();
  const v = R.view(f, { ...base(f), iterations: '3', cost: '25.00', minutes: '090' });
  assert.equal(v.cost.changed, false);
  assert.equal(v.minutes.changed, false);
  assert.equal(v.command.prefix.length, 0);
  assert.equal(v.cost.reset, null);
});

test('a cap raised above the file\'s, or set to 0 where the file has one, is marked in rust; lowering is not', () => {
  const f = facts();
  const at = (over) => R.view(f, { ...base(f), iterations: '3', ...over });
  assert.equal(at({ cost: '30' }).cost.rust, true, 'raised');
  assert.equal(at({ minutes: '120' }).minutes.rust, true, 'raised');
  assert.equal(at({ cost: '0' }).cost.rust, true, 'zero where the file has a cap');
  assert.equal(at({ minutes: '0' }).minutes.rust, true);
  assert.equal(at({ cost: '5' }).cost.rust, false);
  assert.equal(at({ minutes: '30' }).minutes.rust, false);
  assert.equal(at({ cost: '0' }).button, 'Start run · no spend cap', 'the button follows the edited spend cap');
  assert.equal(at({ cost: '0' }).command.full, 'FOREMAN_MAX_COST_USD=0 foreman run .scratch/b 3 --live');

  // Where the file has no cap, setting one is tightening, not raising.
  const dry = dryRunSample();
  dry.settings.budgets.cost_usd = null;
  const g = facts({ dry });
  const v = R.view(g, { ...base(g), iterations: '3', cost: '50' });
  assert.equal(v.cost.rust, false);
  assert.equal(v.cost.reset, 'none');
  assert.equal(v.button, 'Start run · up to $50.00');
});

test('a cap that is not a whole number of minutes or dollars with two decimals is refused on the field, and Start is off', () => {
  const f = facts();
  const bad = R.view(f, { ...base(f), iterations: '3', minutes: '1.5' });
  assert.match(bad.minutes.error, /whole number/);
  assert.equal(bad.blocked, bad.minutes.error, 'Start is disabled, for that reason');
  assert.equal(bad.minutes.reset, '90', 'and the file\'s value is one click away');
  assert.deepEqual(bad.plan.caps, { cost: null, minutes: null }, 'a refused value is never passed on');

  const bad2 = R.view(f, { ...base(f), iterations: '3', cost: '10.999' });
  assert.match(bad2.cost.error, /two decimals/);
  assert.equal(bad2.blocked, bad2.cost.error);
  assert.equal(bad2.button, 'Start run', 'no price is claimed while the field is not valid');

  const empty = R.view(f, { ...base(f), iterations: '3', cost: '' });
  assert.ok(empty.cost.error, 'an emptied field is refused, not read as 0');

  const iter = R.view(f, { ...base(f), iterations: '0' });
  assert.ok(iter.iterations.error);
  assert.equal(iter.blocked, iter.iterations.error);
});

test('Start is off, with the words, when the control directory is not ignored, a run is in flight, or nothing would run', () => {
  const f = facts({ ignored: false });
  assert.equal(R.view(f, base(f)).blocked, 'Starting from the app needs `doctor --fix`');
  const g = facts({ inFlight: true });
  assert.match(R.view(g, base(g)).blocked, /already in flight/);
  const dry = dryRunSample();
  dry.would_run.remaining = dry.would_run.remaining.slice(2);   // 07 (human) is next
  const h = facts({ dry });
  assert.match(R.view(h, base(h)).blocked, /Nothing would run/);
  // the doctor reason wins over the rest: it is the one a person can act on
  const both = facts({ ignored: false, inFlight: true });
  assert.equal(R.view(both, base(both)).blocked, 'Starting from the app needs `doctor --fix`');
});

test('can reach: runnable tickets within the budget, then the human stop or the end of the budget', () => {
  const rem = dryRunSample().would_run.remaining;      // 05 run, 06 run, 07 stop, then later
  const text = (parts) => parts.map((p) => p.text).join('');
  assert.equal(text(R.reach(rem, 1)), '05, then the budget ends the run');
  assert.equal(text(R.reach(rem, 2)), '05 → 06, then stops at 07 (human)');
  assert.equal(text(R.reach(rem, null)), '05 → 06, then stops at 07 (human)');
  assert.equal(R.reach(rem, 2).find((p) => p.tone === 'rust').text, '07 (human)');
  assert.equal(text(R.reach(rem.slice(0, 2), null)), '05 → 06, then nothing is left');
  assert.equal(text(R.reach(rem.slice(2), 3)), 'nothing, stops at 07 (human)');
  assert.equal(text(R.reach([], 3)), 'nothing is left to run');
});

test('the model and mode are shown for reading; resuming has its own title', () => {
  const f = facts();
  const v = R.view(f, base(f));
  assert.equal(v.model, 'claude-sonnet-5-5 · exec local · acceptEdits');
  assert.equal(v.title, 'Start a run');
  assert.equal(R.view(f, base(f), { resume: true }).title, 'Resume a run');
  assert.equal(R.view(f, { ...base(f), live: false }).command.text.endsWith('--live'), false);
});

test('every field has words behind its ?, and the time cap says it is for the whole run', () => {
  for (const k of ['starts at', 'can reach', 'iterations', 'spend cap', 'time cap', 'live tool calls', 'model', 'runs']) {
    assert.ok(R.HELP[k] && R.HELP[k].title && R.HELP[k].body.length > 20, k);
    assert.ok(!/[<>]/.test(R.HELP[k].body), `${k}: plain text, no markup`);
  }
  assert.match(R.HELP['time cap'].body, /the whole run may take/);
  assert.match(R.HELP['time cap'].body, /not each iteration/);
  assert.match(R.HELP['spend cap'].body, /a little over/);
});
