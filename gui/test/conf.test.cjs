'use strict';
// conf.js and the three readers built on it (caps on the live bar, the exec mode, "where a cap is set"):
// they must land where the shell does when it sources foreman.conf (lib/foreman-config.sh, foreman-legacy.sh).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Conf = require('../conf.js');
const { capsFromConf, createLive } = require('../live.cjs');
const { execModeOf } = require('../conditions.cjs');
const R = require('../runplan.js');

const NONE = { cost: null, minutes: null };

test('the last assignment wins, as in the shell', () => {
  assert.deepEqual(capsFromConf('FOREMAN_MAX_COST_USD=5\nFOREMAN_MAX_COST_USD=50\n'), { cost: 50, minutes: null });
  assert.equal(execModeOf('FOREMAN_EXEC=sandbox\nFOREMAN_EXEC=local\n'), 'local');
  assert.equal(Conf.confValue('X_A=1\nFOREMAN_A=2\nFOREMAN_A=3\n', 'FOREMAN_A'), '3');
});

test('an `export` prefix is accepted', () => {
  assert.deepEqual(capsFromConf('export FOREMAN_MAX_COST_USD=12\n  export   FOREMAN_MAX_MINUTES=30\n'), { cost: 12, minutes: 30 });
  assert.equal(execModeOf('export FOREMAN_EXEC=local\n'), 'local');
});

test('a trailing comment and surrounding quotes are not part of the value', () => {
  assert.deepEqual(capsFromConf('FOREMAN_MAX_COST_USD=7.5   # the budget\nFOREMAN_MAX_MINUTES="45" # an hour less\n'), { cost: 7.5, minutes: 45 });
  assert.deepEqual(capsFromConf("FOREMAN_MAX_COST_USD='3'\n"), { cost: 3, minutes: null });
  assert.equal(execModeOf('FOREMAN_EXEC=local # CI only\r\n'), 'local');
  assert.equal(Conf.confValue('FOREMAN_PROMPT_EXTRA="a # b"  # c\n', 'FOREMAN_PROMPT_EXTRA'), 'a # b', 'a # inside quotes is the value');
  assert.equal(Conf.confValue('FOREMAN_MODEL=a#b\n', 'FOREMAN_MODEL'), 'a#b', 'a # that starts no word is the value');
});

test('the legacy RALPH_MAX_* knobs are read', () => {
  assert.deepEqual(capsFromConf('RALPH_MAX_COST_USD=7\nRALPH_MAX_MINUTES=20\n'), { cost: 7, minutes: 20 });
  assert.deepEqual(capsFromConf('', { RALPH_MAX_COST_USD: '9' }), { cost: 9, minutes: null }, 'and from the environment');
  assert.equal(R.capSource(R.COST, { confText: 'RALPH_MAX_COST_USD=7\n', env: {} }).kind, 'conf');
  assert.equal(R.capSource(R.COST, { confText: '', env: { RALPH_MAX_COST_USD: '7' } }).kind, 'environment');
});

test('FOREMAN_ beats RALPH_, wherever each is: in the file, and in the environment', () => {
  assert.equal(execModeOf('FOREMAN_EXEC=host\nRALPH_EXEC=sandbox\n'), 'host');
  assert.equal(execModeOf('RALPH_EXEC=sandbox\nFOREMAN_EXEC=host\n'), 'host');
  assert.equal(execModeOf('RALPH_EXEC=local\n'), 'local');
  assert.deepEqual(capsFromConf('RALPH_MAX_COST_USD=7\nFOREMAN_MAX_COST_USD=3\n'), { cost: 3, minutes: null });
  assert.equal(execModeOf('', { FOREMAN_EXEC: 'host', RALPH_EXEC: 'sandbox' }), 'host');
  assert.equal(execModeOf('FOREMAN_EXEC=host\n', { RALPH_EXEC: 'local' }), 'local', 'the environment still ranks above the file');
  assert.equal(execModeOf('RALPH_EXEC=local\n', { FOREMAN_EXEC: 'host' }), 'host');
});

test('${X:-9} is the default, as this reader cannot know X; other forms it cannot settle are no number', () => {
  assert.deepEqual(capsFromConf('FOREMAN_MAX_COST_USD=${X:-9}\n'), { cost: 9, minutes: null });
  assert.deepEqual(capsFromConf('FOREMAN_MAX_COST_USD="${FOREMAN_MAX_COST_USD:-25}"\n'), { cost: 25, minutes: null });
  assert.equal(execModeOf('FOREMAN_EXEC=${E-local}\n'), 'local');
  assert.deepEqual(capsFromConf('FOREMAN_MAX_COST_USD=${X}\nFOREMAN_MAX_MINUTES=$((2*3))\n'), NONE);
  assert.deepEqual(capsFromConf('FOREMAN_MAX_COST_USD=$(cat x)\n'), NONE);
});

test('a batch with no foreman.conf has its ralph.conf read; foreman.conf wins when both are there', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'conf-')).replace(/\\/g, '/');
  assert.equal(Conf.readBatchConf(fs, dir), null, 'neither: nothing');
  fs.writeFileSync(`${dir}/ralph.conf`, 'RALPH_EXEC=local\nRALPH_MAX_COST_USD=8\n');
  assert.equal(Conf.readBatchConf(fs, dir), 'RALPH_EXEC=local\nRALPH_MAX_COST_USD=8\n');
  fs.writeFileSync(`${dir}/foreman.conf`, 'FOREMAN_EXEC=host\n');
  assert.equal(Conf.readBatchConf(fs, dir), 'FOREMAN_EXEC=host\n');
});

test('the live bar takes its caps from ralph.conf when the batch has no foreman.conf', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'conf-')).replace(/\\/g, '/');
  fs.mkdirSync(`${root}/b/.foreman-run`, { recursive: true });
  fs.writeFileSync(`${root}/b/ralph.conf`, 'RALPH_MAX_COST_USD=7\n');
  const live = createLive({ repoRoot: root, foreman: { report: async () => ({ run: { iterations: [] } }) }, env: {} });
  const out = await live.read({ batch: 'b', run: { in_flight: true, id: 'r', control_dir: 'b/.foreman-run' } });
  assert.deepEqual(out.caps, { cost: 7, minutes: null });
});

test('an ordinary single-assignment conf reads as it always did', () => {
  assert.deepEqual(capsFromConf('FOREMAN_MAX_COST_USD=25\nFOREMAN_MAX_MINUTES=90\n'), { cost: 25, minutes: 90 });
  assert.deepEqual(capsFromConf('#FOREMAN_MAX_COST_USD=25\n'), NONE);
  assert.equal(execModeOf('# FOREMAN_EXEC=local\nFOREMAN_MODEL=x\n'), 'sandbox');
  assert.equal(R.capSource(R.COST, { confText: '#FOREMAN_MAX_COST_USD=25\n', env: {} }).kind, 'none');
  assert.equal(R.capSource(R.COST, { confText: 'FOREMAN_MAX_COST_USD=\n', env: {} }).kind, 'conf', 'an empty assignment is still set');
});
