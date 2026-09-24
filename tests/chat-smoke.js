'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { boundedEvidence, validHost, validPost, nameQuery, callCaretakerTool } = require('../scripts/chat-server.js');

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

test('Caretaker tool arguments reject command text before starting a check', async () => {
  assert.equal(nameQuery('WorldOfWarshipsLegends.exe'), 'WorldOfWarshipsLegends.exe');
  assert.throws(() => nameQuery('foo; Stop-Process'), /short process name/);
  await assert.rejects(callCaretakerTool('resources', { processName: 'foo; Stop-Process' }), /short process name/);
  await assert.rejects(callCaretakerTool('process_details', { processId: '42' }), /valid process ID/);
  await assert.rejects(callCaretakerTool('shell', {}), /not available/);
});
