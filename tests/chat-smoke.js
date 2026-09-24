'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { boundedEvidence, validHost, validPost, nameQuery, callCaretakerTool, CodexSession } = require('../scripts/chat-server.js');

test('chat evidence is bounded, historical, and omits raw private fields', () => {
  const fixture = path.join(__dirname, 'fixtures', 'chat-snapshot.json');
  const value = boundedEvidence(fixture);
  assert.equal(value.capturedAtUtc, '2026-09-23T22:15:35Z');
  assert.equal(value.coverage.tasks.status, 'DEGRADED');
  assert.equal(value.topWorkingSet[0].name, 'large.exe');
  assert.equal(value.tcpListenerSample[0].bind, 'wildcard');
  const serialized = JSON.stringify(value);
  assert.ok(!serialized.includes('PRIVATE-'));
  assert.ok(!serialized.includes('0.0.0.0'));
  assert.ok(serialized.length < 3000);
  assert.match(value.source, /historical/);
});

test('missing evidence stays unknown', () => {
  const value = boundedEvidence(path.join(__dirname, 'fixtures', 'missing-chat-snapshot.json'));
  assert.equal(value.capturedAtUtc, 'UNKNOWN');
  assert.equal(value.coverage, 'UNKNOWN');
});

test('chat writes require the exact loopback origin and token', () => {
  const port = 12345;
  const request = { headers: { host: '127.0.0.1:12345', origin: 'http://127.0.0.1:12345',
    'x-caretaker-csrf': 'secret', 'content-type': 'application/json' } };
  assert.equal(validHost(request.headers.host, port), true);
  assert.equal(validPost(request, 'secret', port), true);
  assert.equal(validPost(request, 'wrong', port), false);
  assert.equal(validPost({ headers: { ...request.headers, origin: 'https://other.example' } }, 'secret', port), false);
  assert.equal(validPost({ headers: { ...request.headers, host: 'localhost:12345' } }, 'secret', port), false);
});

function fakeSession() {
  const session = new CodexSession();
  const written = [];
  session.child = { exitCode: null, signalCode: null,
    stdin: { writable: true, write: line => written.push(JSON.parse(line)), end() { this.writable = false; } } };
  session.threadId = 'thread-1';
  return { session, written };
}

function fakeTurn(session, id, sink) {
  session.turn = { text: '', id, toolCalls: 0,
    resolve: value => { sink.value = value; }, reject: assert.fail,
    timer: setTimeout(() => assert.fail('turn timer fired'), 5000) };
}

test('a server request sharing a client id is answered, not taken as our reply', async () => {
  const { session, written } = fakeSession();
  let settled = false;
  const pending = session.request('ping', {}, 5000).then(value => { settled = true; return value; });
  session.onLine(JSON.stringify({ id: 0, method: 'item/commandExecution/requestApproval', params: {} }));
  await new Promise(setImmediate);
  assert.equal(settled, false);
  assert.deepEqual(written.at(-1), { id: 0, error: { code: -32601, message: 'Unsupported by Caretaker chat.' } });
  session.onLine(JSON.stringify({ id: 0, result: { ok: true } }));
  assert.deepEqual(await pending, { ok: true });
});

test('turn events before the turn/start reply bind the turn; other turns are ignored', () => {
  const { session } = fakeSession();
  const sink = {};
  fakeTurn(session, null, sink);
  session.onLine(JSON.stringify({ method: 'item/agentMessage/delta', params: { threadId: 'thread-1', turnId: 't1', delta: 'hi' } }));
  session.onLine(JSON.stringify({ method: 'item/agentMessage/delta', params: { threadId: 'thread-1', turnId: 't0', delta: ' stale' } }));
  session.onLine(JSON.stringify({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 't0', status: 'completed' } } }));
  assert.equal(session.turn.text, 'hi');
  session.onLine(JSON.stringify({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 't1', status: 'completed' } } }));
  assert.equal(sink.value, 'hi');
  assert.equal(session.turn, null);
});

test('a closed or exited Codex child is never written to', async () => {
  const { session, written } = fakeSession();
  session.child.exitCode = 0;
  assert.throws(() => session.send({ method: 'x' }), /unavailable/);
  session.child.exitCode = null;
  session.close();
  assert.throws(() => session.send({ method: 'x' }), /unavailable/);
  session.onLine(JSON.stringify({ id: 7, method: 'item/tool/call', params: { threadId: 'thread-1', turnId: 't', tool: 'caretaker_status', arguments: {} } }));
  session.onLine(JSON.stringify({ id: 8, method: 'unknown/request', params: {} }));
  await new Promise(setImmediate);
  assert.equal(written.length, 0);
});

test('page hide waits for a reload; an unreturned page stops the server', async () => {
  const child = spawn(process.execPath, [path.join(__dirname, '..', 'scripts', 'chat-server.js')],
    { env: { ...process.env, CARETAKER_CHAT_LEAVE_GRACE_MS: '400' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const exited = new Promise(resolve => child.on('exit', code => resolve(code)));
  try {
    const port = await new Promise((resolve, reject) => {
      child.stdout.on('data', chunk => { const m = /127\.0\.0\.1:(\d+)/.exec(String(chunk)); if (m) resolve(Number(m[1])); });
      setTimeout(() => reject(new Error('server did not start')), 5000).unref();
    });
    const base = `http://127.0.0.1:${port}`;
    const page = await (await fetch(`${base}/`)).text();
    const token = /const csrf = '([0-9a-f]{64})'/.exec(page)[1];
    const leave = () => fetch(`${base}/leave`, { method: 'POST', body: '{}', headers: {
      'Content-Type': 'application/json', Origin: base, 'X-Caretaker-CSRF': token } });
    assert.equal((await leave()).status, 200);
    await fetch(`${base}/`);
    await new Promise(resolve => setTimeout(resolve, 700));
    assert.equal(child.exitCode, null, 'reload within the grace keeps the server');
    await leave();
    assert.equal(await Promise.race([exited, new Promise(resolve => setTimeout(() => resolve('alive'), 3000).unref())]), 0);
  } finally { if (child.exitCode === null) child.kill(); }
});

test('CodexSession matches JSON-RPC replies and turn events by id', async () => {
  const { session } = fakeSession();
  const first = session.request('ping', {}, 5000);
  session.onLine(JSON.stringify({ id: 99, result: { stray: true } }));
  session.onLine(JSON.stringify({ id: 0, result: { ok: true } }));
  assert.deepEqual(await first, { ok: true });

  let resolved = '';
  session.turn = {
    text: '',
    id: 'turn-a',
    resolve: value => { resolved = value; },
    reject: assert.fail,
    timer: setTimeout(() => assert.fail('turn timer fired'), 5000),
    toolCalls: 0,
  };
  session.onLine(JSON.stringify({ method: 'item/agentMessage/delta', params: { threadId: 'other', delta: 'no' } }));
  assert.equal(session.turn.text, '');
  session.onLine(JSON.stringify({ method: 'item/agentMessage/delta', params: { threadId: 'thread-1', delta: 'hello' } }));
  assert.equal(session.turn.text, 'hello');
  session.onLine(JSON.stringify({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-b', status: 'completed' } } }));
  assert.equal(session.turn.text, 'hello');
  session.onLine(JSON.stringify({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-a', status: 'completed' } } }));
  assert.equal(resolved, 'hello');
  assert.equal(session.turn, null);
});

test('Caretaker tool arguments reject command text before starting a check', async () => {
  assert.equal(nameQuery('WorldOfWarshipsLegends.exe'), 'WorldOfWarshipsLegends.exe');
  assert.throws(() => nameQuery('foo; Stop-Process'), /short process name/);
  await assert.rejects(callCaretakerTool('resources', { processName: 'foo; Stop-Process' }), /short process name/);
  await assert.rejects(callCaretakerTool('process_details', { processId: '42' }), /valid process ID/);
  await assert.rejects(callCaretakerTool('shell', {}), /not available/);
});
