'use strict';

// Manual end-to-end smoke. Requires the user's existing Codex ChatGPT sign-in.
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawn } = require('node:child_process');

async function main() {
  const slowdown = process.argv.includes('--slowdown');
  const root = path.resolve(__dirname, '..');
  const child = spawn(process.execPath, [path.join(root, 'scripts', 'chat-server.js')], {
    cwd: root, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], shell: false,
  });
  let stderr = '';
  child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-1000); });
  let url;
  const started = new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => reject(new Error('Chat server did not start.')), 10000);
    child.stdout.on('data', chunk => {
      output += chunk;
      const match = output.match(/http:\/\/127\.0\.0\.1:\d+\//);
      if (match) { clearTimeout(timer); url = match[0]; resolve(); }
    });
    child.once('exit', code => { clearTimeout(timer); reject(new Error(`Chat server exited ${code}: ${stderr}`)); });
  });
  try {
    await started;
    const page = await (await fetch(url)).text();
    const token = page.match(/const csrf = '([a-f0-9]{64})'/)?.[1];
    assert.ok(token, 'page has a CSRF token');
    assert.equal((await fetch(url + 'models')).status, 403, 'model discovery requires the page token');
    const modelResponse = await fetch(url + 'models', { headers: { 'x-caretaker-csrf': token } });
    const listing = await modelResponse.json();
    assert.equal(modelResponse.status, 200, listing.error);
    assert.ok(listing.models?.length, 'models are available');
    assert.ok(listing.models.some(item => item.id === listing.selectedModel));
    assert.equal(listing.selectedModel, 'gpt-6-luna', 'Luna is the initial model');
    assert.equal(listing.selectedEffort, 'xhigh', 'extra-high is the initial effort');
    const response = await fetch(url + 'chat', { method: 'POST', headers: {
      'content-type': 'application/json', origin: url.slice(0, -1), 'x-caretaker-csrf': token,
    }, body: JSON.stringify({ model: listing.selectedModel, effort: listing.selectedEffort,
      message: slowdown ? 'Do you see anything that could be slowing the system down right now? Tell me what you checked, what you found, and what remains unknown.'
        : 'Check current system CPU and memory usage now with a fresh Caretaker sample. Report timestamp, overall system CPU percent, RAM used percent, and at least one current top CPU process.' }) });
    const answer = await response.json();
    assert.equal(response.status, 200, answer.error);
    assert.ok(answer.reply?.length > 20, 'Codex returned an answer');
    assert.equal(answer.model, listing.selectedModel);
    assert.equal(answer.effort, listing.selectedEffort);
    if (slowdown) {
      assert.ok(answer.checks?.some(check => check.tool === 'resources' && check.completed), 'fresh resource check completed');
      assert.ok(answer.checks?.some(check => check.tool === 'event_health' && check.completed), 'fresh event check completed');
    }
    console.log(JSON.stringify({ models: listing.models.length, selectedModel: listing.selectedModel,
      selectedEffort: listing.selectedEffort,
      checks: answer.checks, reply: answer.reply.slice(0, 2500) }));
    const otherModel = listing.models.find(item => item.id !== listing.selectedModel);
    if (otherModel && !slowdown) {
      const secondResponse = await fetch(url + 'chat', { method: 'POST', headers: {
        'content-type': 'application/json', origin: url.slice(0, -1), 'x-caretaker-csrf': token,
      }, body: JSON.stringify({ model: otherModel.id, effort: otherModel.defaultReasoningEffort,
        message: 'How much CPU and memory is WorldOfWarshipsLegends.exe using right now? Please take a fresh named-process sample.' }) });
      const second = await secondResponse.json();
      assert.equal(secondResponse.status, 200, second.error);
      assert.ok(second.reply?.length > 20);
      assert.equal(second.model, otherModel.id);
      assert.equal(second.effort, otherModel.defaultReasoningEffort);
      console.log(JSON.stringify({ switchedModel: otherModel.id, switchedEffort: second.effort,
        reply: second.reply.slice(0, 1500) }));
    }
    const close = await fetch(url + 'close', { method: 'POST', headers: {
      'content-type': 'application/json', origin: url.slice(0, -1), 'x-caretaker-csrf': token,
    }, body: '{}' });
    assert.equal(close.status, 200);
    const exitCode = child.exitCode ?? await Promise.race([
      new Promise(resolve => child.once('exit', resolve)),
      new Promise((_, reject) => setTimeout(() => reject(new Error('Chat server did not stop.')), 3000)),
    ]);
    assert.equal(exitCode, 0, 'owned chat server and Codex child stopped cleanly');
  } finally {
    if (child.exitCode === null) {
      await Promise.race([new Promise(resolve => child.once('exit', resolve)),
        new Promise(resolve => setTimeout(resolve, 3000))]);
      if (child.exitCode === null) child.kill();
    }
  }
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
