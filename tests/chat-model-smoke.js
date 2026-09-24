'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { CodexSession, preferredSettings } = require('../scripts/chat-server.js');

const models = [
  { id: 'gpt-6-astra', displayName: 'GPT-6-Astra', isDefault: true,
    defaultReasoningEffort: 'medium', supportedReasoningEfforts: [
      { reasoningEffort: 'medium' }, { reasoningEffort: 'high' }] },
  { id: 'gpt-6-luna', displayName: 'GPT-6-Luna', isDefault: false,
    defaultReasoningEffort: 'medium', supportedReasoningEfforts: [
      { reasoningEffort: 'low' }, { reasoningEffort: 'medium' },
      { reasoningEffort: 'high' }, { reasoningEffort: 'xhigh' }] },
];

test('Caretaker defaults to the available Luna model at extra-high effort', () => {
  assert.deepEqual(preferredSettings(models), { model: 'gpt-6-luna', effort: 'xhigh' });
  assert.deepEqual(preferredSettings(models.slice(0, 1)), { model: 'gpt-6-astra', effort: 'medium' });
});

test('selected model and effort reach turn/start; unsupported combinations fail', async () => {
  const session = new CodexSession();
  session.models = models;
  session.threadId = 'thread-1';
  session.start = async () => {};
  let sent;
  session.request = async (method, params) => {
    assert.equal(method, 'turn/start');
    sent = params;
    setImmediate(() => session.onLine(JSON.stringify({ method: 'turn/completed', params: {
      threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } } })));
    return { turn: { id: 'turn-1' } };
  };
  assert.equal(await session.ask('hello', 'gpt-6-luna', 'xhigh'), 'Codex returned no message.');
  assert.equal(sent.model, 'gpt-6-luna');
  assert.equal(sent.effort, 'xhigh');
  assert.deepEqual(session.lastSettings, { model: 'gpt-6-luna', effort: 'xhigh' });
  await assert.rejects(session.ask('hello', 'gpt-6-astra', 'xhigh'), /reasoning effort supported/);
});
