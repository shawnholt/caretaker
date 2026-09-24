'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { boundedEvidence, validHost, validPost, nameQuery, callCaretakerTool, CodexSession,
  resolveCodexExe, resolveNpmWrapperCodexExe } = require('../scripts/chat-server.js');

test('chat page prioritizes accessible questions and evidence provenance', () => {
  const page = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'chat-page.html'), 'utf8');
  for (const fragment of [
    'Do you see anything that could be slowing the system down?',
    'aria-label="Caretaker conversation"', 'aria-live="polite"', 'Ctrl + Enter to send',
    'max-width: 760px', 'id="stop" class="stop" type="button">Stop chat',
    'aria-label="Chat model settings"', 'label for="model">Model', 'label for="effort">Reasoning',
    'supportedReasoningEfforts', 'defaultReasoningEffort', 'populateEfforts(model.value, data.selectedEffort || \'\')',
    "model.addEventListener('change'", "model.value === 'gpt-6-luna' ? 'xhigh'", 'Extra high',
    'JSON.stringify({ message, model: submittedModel, effort: submittedEffort })',
    'Model: ${selected.model} · Reasoning: ${effortLabel(selected.effort)}.',
    "fetch('/summary', { cache: 'no-store', headers: { 'x-caretaker-csrf': csrf } })",
    'Snapshot captured (UTC)', 'Collection coverage',
    'point-in-time context. It does not describe live system status',
    'No structured checks used; local commands may still have been used.', 'check?.completed === true', "typeof check?.state === 'string'",
  ]) assert.ok(page.includes(fragment), `chat page should include ${fragment}`);
});

test('chat approval UI shows exact request details and requires an explicit decision', () => {
  const page = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'chat-page.html'), 'utf8');
  for (const fragment of [
    'id="approval-card"', 'aria-live="assertive"', 'Approval needed',
    'Nothing is approved automatically.', 'id="approval-allow" type="button">Allow once',
    'id="approval-deny" class="approval-deny" type="button">Deny',
    "fetch('/approval', { cache: 'no-store', headers: { 'x-caretaker-csrf': csrf } })",
    "JSON.stringify({ id, decision })", "decideApproval('accept')", "decideApproval('decline')",
    "addApprovalDetail('Command', approval.command)", "addApprovalDetail('Working directory', approval.cwd)",
    "addApprovalDetail('File or permission details', approval.details)",
    'function startApprovalPolling()', 'setTimeout(pollApproval, 500)',
    'if (!chatPending || closing || approvalPollBusy) return', 'stopApprovalPolling();',
  ]) assert.ok(page.includes(fragment), `approval UI should include ${fragment}`);
});

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
  assert.deepEqual(written.at(-1), { id: 0, result: { decision: 'decline' } });
  session.onLine(JSON.stringify({ id: 0, result: { ok: true } }));
  assert.deepEqual(await pending, { ok: true });
});

test('full-access command waits for the exact user decision', () => {
  const { session, written } = fakeSession();
  fakeTurn(session, 'turn-1', {});
  session.onLine(JSON.stringify({ id: 12, method: 'item/commandExecution/requestApproval',
    params: { threadId: 'thread-1', turnId: 'turn-1', itemId: 'item-1',
      command: 'Set-Content evidence/test.txt ok', cwd: 'C:\\caretaker',
      availableDecisions: ['accept', 'decline'] } }));
  const approval = session.approvalView();
  assert.equal(approval.kind, 'command');
  assert.match(approval.command, /Set-Content/);
  assert.equal(written.length, 0, 'a pending command is not auto-approved');
  assert.equal(session.resolveApproval('wrong-id', 'accept'), false);
  assert.equal(written.length, 0);
  assert.equal(session.resolveApproval(approval.id, 'accept'), true);
  assert.deepEqual(written, [{ id: 12, result: { decision: 'accept' } }]);
  assert.equal(session.approvalView(), null);
  session.turn.reject = () => {};
  session.close();
});

test('unmatched approval is denied and Stop declines a pending command', () => {
  const { session, written } = fakeSession();
  fakeTurn(session, 'turn-1', {});
  session.onLine(JSON.stringify({ id: 13, method: 'item/commandExecution/requestApproval',
    params: { threadId: 'other-thread', turnId: 'turn-1', itemId: 'wrong' } }));
  assert.deepEqual(written.pop(), { id: 13, result: { decision: 'decline' } });
  session.onLine(JSON.stringify({ id: 14, method: 'item/commandExecution/requestApproval',
    params: { threadId: 'thread-1', turnId: 'turn-1', itemId: 'pending', command: 'whoami' } }));
  assert.ok(session.approvalView());
  session.turn.reject = () => {};
  session.close();
  assert.deepEqual(written.pop(), { id: 14, result: { decision: 'decline' } });
  assert.equal(session.approvalView(), null);
});

test('file approvals show the proposed patch and permission grants stay turn-scoped', () => {
  const { session, written } = fakeSession();
  fakeTurn(session, 'turn-1', {});
  session.onLine(JSON.stringify({ method: 'item/fileChange/patchUpdated', params: {
    threadId: 'thread-1', turnId: 'turn-1', itemId: 'patch-1',
    changes: [{ path: 'evidence/test.txt', kind: 'add', diff: '+approved' }] } }));
  session.onLine(JSON.stringify({ id: 20, method: 'item/fileChange/requestApproval', params: {
    threadId: 'thread-1', turnId: 'turn-1', itemId: 'patch-1' } }));
  const patch = session.approvalView();
  assert.match(patch.details, /evidence\/test.txt/);
  assert.match(patch.details, /\+approved/);
  assert.equal(session.resolveApproval(patch.id, 'accept'), true);
  assert.deepEqual(written.pop(), { id: 20, result: { decision: 'accept' } });
  session.onLine(JSON.stringify({ id: 21, method: 'item/permissions/requestApproval', params: {
    threadId: 'thread-1', turnId: 'turn-1', itemId: 'permissions-1', cwd: 'C:\\caretaker',
    permissions: { fileSystem: { read: ['C:\\Windows'] } } } }));
  const grant = session.approvalView();
  assert.equal(grant.kind, 'permissions');
  assert.equal(session.resolveApproval(grant.id, 'accept'), true);
  assert.deepEqual(written.pop(), { id: 21, result: { permissions: {
    fileSystem: { read: ['C:\\Windows'] } }, scope: 'turn' } });
  session.turn.reject = () => {};
  session.close();
});

test('file patch without a preview is declined before user approval', () => {
  const { session, written } = fakeSession();
  fakeTurn(session, 'turn-1', {});
  session.onLine(JSON.stringify({ id: 22, method: 'item/fileChange/requestApproval', params: {
    threadId: 'thread-1', turnId: 'turn-1', itemId: 'no-preview' } }));
  assert.deepEqual(written, [{ id: 22, result: { decision: 'decline' } }]);
  assert.equal(session.approvalView(), null);
  session.onLine(JSON.stringify({ method: 'item/started', params: {
    threadId: 'thread-1', turnId: 'turn-1', item: { type: 'fileChange', id: 'patch-2',
      changes: [{ path: 'evidence/from-item.txt', kind: 'add', diff: '+approved' }] } } }));
  session.onLine(JSON.stringify({ id: 23, method: 'item/fileChange/requestApproval', params: {
    threadId: 'thread-1', turnId: 'turn-1', itemId: 'patch-2' } }));
  assert.match(session.approvalView().details, /from-item.txt/);
  session.turn.reject = () => {};
  session.close();
});

test('approval never hides the tail of an oversized command', () => {
  const { session, written } = fakeSession();
  fakeTurn(session, 'turn-1', {});
  session.onLine(JSON.stringify({ id: 24, method: 'item/commandExecution/requestApproval', params: {
    threadId: 'thread-1', turnId: 'turn-1', itemId: 'long-command', command: 'x'.repeat(8001) } }));
  assert.deepEqual(written, [{ id: 24, result: { decision: 'decline' } }]);
  assert.equal(session.approvalView(), null);
  session.turn.reject = () => {};
  session.close();
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

test('Codex resolve prefers npm wrapper vendor exe before PATH codex.exe', () => {
  const previous = process.env.CARETAKER_CODEX_EXE;
  delete process.env.CARETAKER_CODEX_EXE;
  try {
    const wrapper = resolveNpmWrapperCodexExe();
    if (!wrapper) {
      assert.ok(true, 'SKIP: npm @openai/codex vendor binary not installed');
      return;
    }
    assert.match(wrapper, /codex\.exe$/i);
    assert.equal(resolveCodexExe(), wrapper);
    process.env.CARETAKER_CODEX_EXE = wrapper;
    assert.equal(resolveCodexExe(), wrapper);
  } finally {
    if (previous === undefined) delete process.env.CARETAKER_CODEX_EXE;
    else process.env.CARETAKER_CODEX_EXE = previous;
  }
});
