'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { isSlowdownQuestion, collectSlowdownEvidence } = require('../scripts/chat-server');

test('slowdown questions get fresh resource and event checks in order', async () => {
  assert.equal(isSlowdownQuestion('Do you see anything that could be slowing the system down?'), true);
  assert.equal(isSlowdownQuestion('What ports are open?'), false);
  const called = [];
  const evidence = await collectSlowdownEvidence('Why is this PC so sluggish?', async (tool, args) => {
    called.push([tool, args]);
    return { state: 'OK', capturedAtUtc: '2026-09-24T05:00:00Z', coverage: { status: 'OK' } };
  });
  assert.deepEqual(called.map(item => item[0]), ['resources', 'event_health']);
  assert.equal(evidence.checks.length, 2);
  assert.ok(evidence.checks.every(item => item.completed && item.capturedAtUtc));
  assert.equal(evidence.context.source, 'fresh Caretaker slowdown checks');
});

test('failed checks remain unavailable, and unrelated questions do not trigger prechecks', async () => {
  const evidence = await collectSlowdownEvidence('Is it lagging?', async tool => {
    if (tool === 'resources') throw new Error('private diagnostic text');
    return { capturedAtUtc: '2026-09-24T05:00:00Z', state: 'DEGRADED' };
  });
  assert.deepEqual(evidence.checks.map(item => item.completed), [false, true]);
  assert.equal(evidence.context.results.resources.state, 'UNKNOWN');
  assert.equal(JSON.stringify(evidence).includes('private diagnostic text'), false);
  let called = false;
  const unrelated = await collectSlowdownEvidence('Show TCP listeners', async () => { called = true; });
  assert.equal(called, false);
  assert.deepEqual(unrelated.checks, []);
});

test('local summary is token-protected and does not start Codex', async () => {
  const root = path.resolve(__dirname, '..');
  const child = spawn(process.execPath, [path.join(root, 'scripts', 'chat-server.js')], {
    cwd: root, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], shell: false,
  });
  let url;
  let output = '';
  const started = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Local chat server did not start.')), 10000);
    child.stdout.on('data', chunk => {
      output += chunk;
      const match = output.match(/http:\/\/127\.0\.0\.1:\d+\//);
      if (match) { clearTimeout(timer); url = match[0]; resolve(); }
    });
    child.once('exit', code => { clearTimeout(timer); reject(new Error(`Local chat server exited ${code}.`)); });
  });
  try {
    await started;
    const page = await (await fetch(url)).text();
    const token = page.match(/const csrf = '([a-f0-9]{64})'/)?.[1];
    assert.ok(token);
    assert.equal((await fetch(url + 'summary')).status, 403);
    const response = await fetch(url + 'summary', { headers: { 'x-caretaker-csrf': token } });
    const data = await response.json();
    assert.equal(response.status, 200);
    assert.equal(typeof data.generatedAtUtc, 'string');
    assert.ok(data.snapshot?.source?.includes('saved Caretaker snapshot'));
    const close = await fetch(url + 'close', { method: 'POST', headers: {
      'content-type': 'application/json', origin: url.slice(0, -1), 'x-caretaker-csrf': token,
    }, body: '{}' });
    assert.equal(close.status, 200);
    const code = child.exitCode ?? await Promise.race([
      new Promise(resolve => child.once('exit', resolve)),
      new Promise((_, reject) => setTimeout(() => reject(new Error('Local chat server did not exit.')), 6000)),
    ]);
    assert.equal(code, 0);
  } finally {
    if (child.exitCode === null) child.kill();
  }
});
