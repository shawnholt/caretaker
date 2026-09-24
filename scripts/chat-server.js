'use strict';

// On-demand, local-only Caretaker chat. No background service or live diagnostics.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');
const readline = require('node:readline');

const ROOT = path.resolve(__dirname, '..');
const SNAPSHOT = path.join(ROOT, 'evidence', 'snapshot.json');
const PAGE = path.join(__dirname, 'chat-page.html');
const MAX_BODY = 8 * 1024;
const MAX_MESSAGE = 3000;
const MAX_REPLY = 12000;
const MAX_TURNS = 12;
const TURN_TIMEOUT = 120000;
const IDLE_TIMEOUT = 15 * 60 * 1000;
const MODULES = ['processes', 'tcpListeners', 'udpEndpoints', 'services', 'tasks', 'startup'];

function boundedEvidence(file = SNAPSHOT) {
  try {
    if (fs.statSync(file).size > 2 * 1024 * 1024) throw new Error('oversized');
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    const when = typeof data.capturedAtUtc === 'string' && data.capturedAtUtc.length < 80
      ? data.capturedAtUtc : 'UNKNOWN';
    const coverage = {};
    for (const name of MODULES) {
      const item = data.coverage?.[name];
      coverage[name] = {
        status: typeof item?.status === 'string' ? item.status.slice(0, 32) : 'UNKNOWN',
        count: Number.isSafeInteger(item?.count) && item.count >= 0 ? item.count : null,
      };
    }
    const processes = coverage.processes.status === 'OK' && Array.isArray(data.observed?.processes)
      ? data.observed.processes.filter(p => p && typeof p.name === 'string' &&
          Number.isSafeInteger(p.workingSetBytes) && p.workingSetBytes >= 0)
          .sort((a, b) => b.workingSetBytes - a.workingSetBytes).slice(0, 6)
          .map(p => ({ name: p.name.slice(0, 60), workingSetMiB: Math.round(p.workingSetBytes / 1048576) }))
      : 'UNKNOWN';
    const listeners = coverage.tcpListeners.status === 'OK' && Array.isArray(data.observed?.tcpListeners)
      ? data.observed.tcpListeners.slice(0, 8).map(p => ({
          process: typeof p?.process?.name === 'string' ? p.process.name.slice(0, 60) : 'UNKNOWN',
          port: Number.isInteger(p?.localPort) && p.localPort >= 0 && p.localPort <= 65535 ? p.localPort : null,
          bind: ['127.0.0.1', '::1'].includes(p?.localAddress) ? 'loopback'
            : ['0.0.0.0', '::'].includes(p?.localAddress) ? 'wildcard' : 'specific',
        })) : 'UNKNOWN';
    return { source: 'saved Caretaker snapshot; historical, not live', capturedAtUtc: when,
      coverage, topWorkingSet: processes, tcpListenerSample: listeners };
  } catch {
    return { source: 'saved Caretaker snapshot', capturedAtUtc: 'UNKNOWN', coverage: 'UNKNOWN' };
  }
}

function validHost(value, port) {
  return value === `127.0.0.1:${port}`;
}

function validPost(req, token, port) {
  if (!validHost(req.headers.host, port)) return false;
  if (req.headers.origin !== `http://127.0.0.1:${port}`) return false;
  if (req.headers['x-caretaker-csrf'] !== token) return false;
  return /^application\/json(?:;|$)/i.test(req.headers['content-type'] || '');
}

function isolatedCodexArgs(exe) {
  const args = ['--no-daemon', '--disable', 'apps', '--disable', 'plugins'];
  let servers;
  try {
    const output = execFileSync(exe, [...args, 'mcp', 'list', '--json'], {
      cwd: ROOT, windowsHide: true, encoding: 'utf8', timeout: 10000, maxBuffer: 1024 * 1024,
    });
    servers = JSON.parse(output);
  } catch {
    throw new Error('Could not verify the Codex tool configuration.');
  }
  if (!Array.isArray(servers)) throw new Error('Codex returned an unknown tool configuration.');
  for (const server of servers) {
    if (!server || !/^[A-Za-z0-9_-]+$/.test(server.name) || typeof server.enabled !== 'boolean') {
      throw new Error('Codex returned an unknown MCP server entry.');
    }
    if (!server.enabled) continue;
    const transport = server.transport;
    let required;
    if (transport?.type === 'stdio' && typeof transport.command === 'string' && transport.command) {
      required = `command=${JSON.stringify(transport.command)},args=[]`;
    } else if (transport?.type === 'streamable_http' && typeof transport.url === 'string' && transport.url) {
      required = `url=${JSON.stringify(transport.url)}`;
    } else {
      throw new Error('A configured MCP server cannot be disabled safely for chat.');
    }
    args.push('-c', `mcp_servers.${server.name}={${required},enabled=false}`);
  }
  args.push('app-server');
  return args;
}

function json(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(body);
}

class CodexSession {
  constructor() {
    this.child = null;
    this.pending = new Map();
    this.nextId = 0;
    this.threadId = null;
    this.turn = null;
    this.buffer = '';
    this.closed = false;
  }

  async start() {
    if (this.child) return;
    const exe = process.env.CARETAKER_CODEX_EXE || 'codex.exe';
    if (path.extname(exe).toLowerCase() !== '.exe') throw new Error('A native codex.exe is required.');
    // Disable configured integrations using their exact transport shape, then
    // verify the resulting thread has no MCP or app tools before any turn.
    const child = spawn(exe, isolatedCodexArgs(exe), { cwd: ROOT, windowsHide: true,
      stdio: ['pipe', 'pipe', 'pipe'], shell: false });
    this.child = child;
    child.on('error', () => this.fail(new Error('Could not start native codex.exe. Check PATH or CARETAKER_CODEX_EXE.')));
    child.on('exit', () => this.fail(new Error('Codex app-server exited. Restart this chat server.')));
    const lines = readline.createInterface({ input: child.stdout });
    lines.on('line', line => this.onLine(line));
    child.stderr.on('data', () => {}); // Drain, but never expose private diagnostics.
    await this.request('initialize', { clientInfo: { name: 'goliath_caretaker_chat',
      title: 'Goliath Caretaker Chat', version: '0.1.0' } }, 10000);
    this.send({ method: 'initialized', params: {} });
    const auth = await this.request('account/read', { refreshToken: false }, 10000);
    if (auth?.account?.type !== 'chatgpt') {
      throw new Error('Sign in to Codex with ChatGPT before using chat.');
    }
    const started = await this.request('thread/start', {
      cwd: ROOT, approvalPolicy: 'never', sandbox: 'read-only',
      personality: 'friendly', serviceName: 'goliath_caretaker_chat',
    }, 15000);
    if (typeof started?.thread?.id !== 'string') throw new Error('Codex did not return a thread ID.');
    this.threadId = started.thread.id;
    const mcp = await this.request('mcpServerStatus/list', {
      detail: 'toolsAndAuthOnly', limit: 1, threadId: this.threadId,
    }, 10000);
    if (!Array.isArray(mcp?.data) || mcp.nextCursor || mcp.data.some(item => item?.runtimeStatus !== 'disabled')) {
      throw new Error('Chat blocked: an MCP integration is active or its status is unknown.');
    }
    const apps = await this.request('app/installed', { threadId: this.threadId }, 10000);
    const installed = Array.isArray(apps?.data) ? apps.data : apps?.apps;
    if (!Array.isArray(installed) || installed.some(item => item?.enabled !== false || item?.callable !== false)) {
      throw new Error('Chat blocked: an app integration is active or its status is unknown.');
    }
  }

  send(obj) {
    if (!this.child || this.child.stdin.destroyed) throw new Error('Codex is unavailable.');
    this.child.stdin.write(JSON.stringify(obj) + '\n');
  }

  request(method, params, timeout) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out.`));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      try { this.send({ method, id, params }); }
      catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
    });
  }

  onLine(line) {
    if (line.length > 1024 * 1024) { this.fail(new Error('Codex response exceeded the limit.')); return; }
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    if (msg.id !== undefined && msg.id !== null) {
      const pending = this.pending.get(msg.id);
      if (!pending) return;
      this.pending.delete(msg.id);
      clearTimeout(pending.timer);
      if (msg.error) pending.reject(new Error('Codex rejected the request.'));
      else pending.resolve(msg.result);
      return;
    }
    if (!this.turn || msg.params?.threadId !== this.threadId) return;
    if (msg.method === 'item/agentMessage/delta' && typeof msg.params.delta === 'string') {
      this.turn.text = (this.turn.text + msg.params.delta).slice(0, MAX_REPLY);
    } else if (msg.method === 'item/completed' && msg.params.item?.type === 'agentMessage') {
      const text = msg.params.item.text;
      if (typeof text === 'string') this.turn.text = text.slice(0, MAX_REPLY);
    } else if (msg.method === 'turn/completed') {
      const active = this.turn;
      this.turn = null;
      clearTimeout(active.timer);
      if (msg.params.turn?.status !== 'completed' || msg.params.turn?.error) {
        active.reject(new Error('Codex could not complete this turn.'));
      } else {
        active.resolve(active.text || 'Codex returned no message.');
      }
    }
  }

  async ask(message) {
    try { await this.start(); }
    catch (error) { this.close(); throw error; }
    if (this.turn) throw new Error('A reply is already in progress.');
    const evidence = boundedEvidence();
    const prefix = `Use only the provided saved snapshot summary. It is historical, not live. Do not use tools, inspect files, or claim current system status. If evidence is unavailable, say UNKNOWN. Snapshot summary: ${JSON.stringify(evidence)}\n\nQuestion: `;
    const done = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.turn = null;
        reject(new Error('The reply timed out. Restart chat to try again.'));
      }, TURN_TIMEOUT);
      this.turn = { text: '', resolve, reject, timer };
    });
    done.catch(() => {}); // A request failure may arrive before we await completion.
    try {
      const result = await this.request('turn/start', {
        threadId: this.threadId,
        input: [{ type: 'text', text: prefix + message }],
        cwd: ROOT, approvalPolicy: 'never',
        sandboxPolicy: { type: 'readOnly' },
      }, 15000);
      if (!result?.turn?.id) throw new Error('Codex did not start the turn.');
      return await done;
    } catch (error) {
      if (this.turn) { clearTimeout(this.turn.timer); this.turn = null; }
      this.close();
      throw error;
    }
  }

  fail(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer); pending.reject(error);
    }
    this.pending.clear();
    if (this.turn) {
      clearTimeout(this.turn.timer); this.turn.reject(error); this.turn = null;
    }
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.fail(new Error('Chat closed.'));
    // Closing the owned stdio channel asks app-server to exit. No force kill is
    // attempted because Node alone cannot verify Windows image and start time.
    if (this.child && !this.child.stdin.destroyed) this.child.stdin.end();
  }
}

function main() {
  const token = crypto.randomBytes(32).toString('hex');
  const session = new CodexSession();
  let turns = 0;
  let busy = false;
  let lastVisit = Date.now();
  const page = fs.readFileSync(PAGE, 'utf8').replace('__CSRF_TOKEN__', token);
  let port;
  const server = http.createServer(async (req, res) => {
    lastVisit = Date.now();
    if (!validHost(req.headers.host, port)) { json(res, 403, { error: 'Invalid host.' }); return; }
    if (req.method === 'GET' && req.url === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
        'Content-Security-Policy': "default-src 'none'; script-src 'nonce-caretaker'; style-src 'nonce-caretaker'; connect-src 'self'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'" });
      res.end(page); return;
    }
    if (req.method !== 'POST' || !['/chat', '/close'].includes(req.url)) {
      json(res, 404, { error: 'Not found.' }); return;
    }
    if (!validPost(req, token, port)) { json(res, 403, { error: 'Request rejected.' }); return; }
    if (req.url === '/close') { json(res, 200, { ok: true }); shutdown(); return; }
    if (busy) { json(res, 409, { error: 'Wait for the current reply.' }); return; }
    if (turns >= MAX_TURNS) { json(res, 429, { error: 'This session reached its 12-turn limit. Restart chat.' }); return; }
    busy = true;
    try {
      let body = '';
      for await (const chunk of req) {
        body += chunk;
        if (Buffer.byteLength(body) > MAX_BODY) throw new Error('Message is too large.');
      }
      const parsed = JSON.parse(body);
      if (typeof parsed.message !== 'string' || !parsed.message.trim() || parsed.message.length > MAX_MESSAGE) {
        throw new Error('Enter a message of at most 3,000 characters.');
      }
      turns++;
      json(res, 200, { reply: await session.ask(parsed.message.trim()), evidence: boundedEvidence() });
    } catch (error) {
      json(res, 400, { error: error.message || 'Chat failed.' });
    } finally { busy = false; }
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  server.listen(0, '127.0.0.1', () => {
    port = server.address().port;
    console.log(`Caretaker chat: http://127.0.0.1:${port}/`);
    console.log('Close the page or press Ctrl-C to stop.');
  });
  let stopping = false;
  function shutdown() {
    if (stopping) return;
    stopping = true;
    session.close();
    server.close();
    setTimeout(() => {
      if (session.child && session.child.exitCode === null) {
        console.error('Could not verify Codex child exit; no force kill attempted.');
        process.exitCode = 1;
      }
      process.exit();
    }, 1200).unref();
  }
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
  setInterval(() => {
    if (!busy && Date.now() - lastVisit > IDLE_TIMEOUT) shutdown();
  }, 30000).unref();
}

if (require.main === module) main();
module.exports = { boundedEvidence, validHost, validPost, isolatedCodexArgs, CodexSession };
