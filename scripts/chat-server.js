'use strict';

// On-demand, local-only Caretaker chat with full local Codex tools and explicit approvals.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, execFile, execFileSync } = require('node:child_process');
const readline = require('node:readline');

const ROOT = path.resolve(__dirname, '..');
const SNAPSHOT = path.join(ROOT, 'evidence', 'snapshot.json');
const PAGE = path.join(__dirname, 'chat-page.html');
const CARETAKER = path.join(__dirname, 'caretaker.ps1');
const MAX_BODY = 8 * 1024;
const MAX_MESSAGE = 3000;
const MAX_REPLY = 12000;
const MAX_TURNS = 12;
const TURN_TIMEOUT = 10 * 60 * 1000; // Includes time for the user to review approvals.
const IDLE_TIMEOUT = 15 * 60 * 1000;
const LEAVE_GRACE = Number(process.env.CARETAKER_CHAT_LEAVE_GRACE_MS) || 10000;
const CHILD_EXIT_WAIT = 5000;
const MODULES = ['processes', 'tcpListeners', 'udpEndpoints', 'services', 'tasks', 'startup'];
const ACTIVE_CARETAKER_CHILDREN = new Set();
const TOOL_DEFS = [
  { name: 'resources', description: 'Take a fresh 1-second Windows process CPU and memory sample. Optionally search for a process by name. Use for current CPU, memory, resource hogs, or a named app.',
    inputSchema: { type: 'object', properties: { processName: { type: 'string', description: 'Optional process name or distinctive substring, e.g. WorldOfWarshipsLegends.exe' } }, additionalProperties: false } },
  { name: 'process_details', description: 'Check one current process by PID, including identity, verified ancestry when available, and bounded local endpoint evidence.',
    inputSchema: { type: 'object', properties: { processId: { type: 'integer', minimum: 1, maximum: 2147483647 } }, required: ['processId'], additionalProperties: false } },
  { name: 'event_health', description: 'Read focused recent Windows System and Application event health categories with coverage; no changes are made.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false } },
  { name: 'inventory', description: 'Capture a fresh, bounded Windows inventory of processes, listeners, services, tasks and startup items, then return a selected section. Use when current inventory or change context is needed.',
    inputSchema: { type: 'object', properties: { section: { type: 'string', enum: MODULES }, query: { type: 'string', description: 'Optional name or port substring to find within the selected section' } }, required: ['section'], additionalProperties: false } },
  { name: 'caretaker_status', description: 'Read the Caretaker checker status, freshness, and coverage without changing the Windows task.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false } },
];

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

function isNativeCodexExe(candidate) {
  return typeof candidate === 'string' && candidate &&
    path.extname(candidate).toLowerCase() === '.exe' && fs.existsSync(candidate);
}

// Windows: PATH `codex` is an npm .cmd/.ps1 shim; Node cannot stdio-spawn it reliably.
// Prefer the shim's vendor codex.exe (same binary `codex` runs), then PATH/env .exe.
function resolveNpmWrapperCodexExe() {
  if (process.platform !== 'win32') return null;
  const { createRequire } = require('node:module');
  const platformPkg = process.arch === 'arm64' ? '@openai/codex-win32-arm64' : '@openai/codex-win32-x64';
  const triple = process.arch === 'arm64' ? 'aarch64-pc-windows-msvc' : 'x86_64-pc-windows-msvc';
  const roots = [];
  if (process.env.APPDATA) {
    roots.push(path.join(process.env.APPDATA, 'npm', 'node_modules', '@openai', 'codex', 'package.json'));
  }
  for (const pkgJson of roots) {
    if (!fs.existsSync(pkgJson)) continue;
    try {
      const req = createRequire(pkgJson);
      const vendorPkg = req.resolve(`${platformPkg}/package.json`);
      const exe = path.join(path.dirname(vendorPkg), 'vendor', triple, 'bin', 'codex.exe');
      if (isNativeCodexExe(exe)) return path.resolve(exe);
    } catch {
      // try next root
    }
  }
  return null;
}

function resolvePathCodexExe() {
  for (const dir of String(process.env.PATH || '').split(path.delimiter)) {
    if (!dir) continue;
    const exe = path.join(dir, 'codex.exe');
    if (isNativeCodexExe(exe)) return path.resolve(exe);
  }
  return null;
}

function resolveCodexExe() {
  const override = process.env.CARETAKER_CODEX_EXE;
  if (override) {
    const full = path.resolve(override);
    if (!isNativeCodexExe(full)) {
      throw new Error('CARETAKER_CODEX_EXE must point to an existing native codex.exe.');
    }
    return full;
  }
  const fromWrapper = resolveNpmWrapperCodexExe();
  if (fromWrapper) return fromWrapper;
  const fromPath = resolvePathCodexExe();
  if (fromPath) return fromPath;
  throw new Error(
    'No Codex CLI found. Install the npm `@openai/codex` CLI (PATH `codex`) or put codex.exe on PATH; optional CARETAKER_CODEX_EXE override.',
  );
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

function nameQuery(value) {
  if (value === undefined || value === '') return '';
  if (typeof value !== 'string' || !/^[A-Za-z0-9_. -]{1,80}$/.test(value)) {
    throw new Error('Use a short process name, service name, task name, or port.' );
  }
  return value;
}

function runCaretaker(action, params = [], timeout = 35000) {
  return new Promise((resolve, reject) => {
    const child = execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', CARETAKER, action, ...params], { cwd: ROOT, windowsHide: true, shell: false,
      timeout, maxBuffer: 2 * 1024 * 1024 }, (error, stdout) => {
      ACTIVE_CARETAKER_CHILDREN.delete(child);
      if (error) reject(new Error(`Caretaker ${action} check was unavailable.`));
      else resolve(stdout.trim());
    });
    ACTIVE_CARETAKER_CHILDREN.add(child);
    child.stdin?.end();
  });
}

function compactProcess(row) {
  return { name: row?.name || 'UNKNOWN', pid: row?.pid ?? null,
    cpuPercentOneCore: row?.cpuPercentOneCore ?? null,
    workingSetMiB: Number.isFinite(row?.workingSetBytes) ? Math.round(row.workingSetBytes / 1048576) : null,
    attributionState: row?.attributionState || 'UNKNOWN' };
}

function boundedResult(value, limit = 10000) {
  const serialized = JSON.stringify(value);
  if (serialized.length <= limit) return value;
  return { state: value?.state || 'UNKNOWN', capturedAtUtc: value?.capturedAtUtc || 'UNKNOWN',
    truncated: true, excerpt: serialized.slice(0, limit) };
}

function compactInventory(section, query = '') {
  const stat = fs.statSync(SNAPSHOT);
  if (stat.size > 2 * 1024 * 1024) throw new Error('Caretaker inventory exceeded the local evidence limit.');
  const data = JSON.parse(fs.readFileSync(SNAPSHOT, 'utf8'));
  const rows = data.observed?.[section];
  const coverage = data.coverage?.[section] || { status: 'UNKNOWN', count: null };
  if (!Array.isArray(rows)) return { capturedAtUtc: data.capturedAtUtc || 'UNKNOWN', section, coverage, rows: 'UNKNOWN' };
  const mapped = rows.map(row => {
    if (section === 'processes') return { name: row.name, pid: row.pid,
      workingSetMiB: Number.isFinite(row.workingSetBytes) ? Math.round(row.workingSetBytes / 1048576) : null };
    if (section === 'tcpListeners' || section === 'udpEndpoints') return { protocol: row.protocol,
      port: row.localPort, bind: ['127.0.0.1', '::1'].includes(row.localAddress) ? 'loopback'
        : ['0.0.0.0', '::'].includes(row.localAddress) ? 'wildcard' : 'specific',
      process: row.process?.name || 'UNKNOWN', pid: row.process?.pid ?? null };
    if (section === 'services') return { name: row.name, displayName: row.displayName,
      state: row.state, startMode: row.startMode };
    if (section === 'tasks') return { name: row.name, path: row.path, state: row.state, enabled: row.enabled };
    return { name: row.name, location: row.location, user: row.user };
  });
  const needle = query.toLowerCase();
  const filtered = needle ? mapped.filter(row => JSON.stringify(row).toLowerCase().includes(needle)) : mapped;
  if (section === 'processes' && !needle) filtered.sort((a, b) => (b.workingSetMiB || 0) - (a.workingSetMiB || 0));
  return { capturedAtUtc: data.capturedAtUtc || 'UNKNOWN', section, coverage, query,
    matchingCount: filtered.length, rows: filtered.slice(0, 20) };
}

async function callCaretakerTool(name, args) {
  if (!args || typeof args !== 'object' || Array.isArray(args)) throw new Error('Invalid tool arguments.');
  if (name === 'resources') {
    if (Object.keys(args).some(key => key !== 'processName')) throw new Error('Invalid resource arguments.');
    const processName = nameQuery(args.processName);
    const raw = await runCaretaker('busy', ['-SampleSeconds', '1', '-Top', '10', ...(processName ? ['-ProcessName', processName] : [])]);
    const data = JSON.parse(raw);
    return { capturedAtUtc: data.capturedAtUtc, state: data.state, coverage: data.coverage,
      sample: data.sample || { elapsedSeconds: data.sampleSeconds, cpuUnit: 'percent of one logical CPU' },
      systemCpu: data.systemCpu || { state: 'UNKNOWN', percent: null },
      memory: { state: data.memory?.state, usedPercent: data.memory?.usedPercent,
        totalGiB: Number.isFinite(data.memory?.totalBytes) ? +(data.memory.totalBytes / 1073741824).toFixed(1) : null,
        freeGiB: Number.isFinite(data.memory?.freeBytes) ? +(data.memory.freeBytes / 1073741824).toFixed(1) : null,
        topConsumers: (data.memory?.topConsumers || []).map(compactProcess) },
      topCpuProcesses: (data.processes || []).map(compactProcess), requestedProcessName: processName,
      namedProcesses: (data.namedProcesses || []).map(compactProcess), reason: data.reason || null };
  }
  if (name === 'process_details') {
    if (Object.keys(args).length !== 1 || !Number.isSafeInteger(args.processId) || args.processId < 1 || args.processId > 2147483647) throw new Error('A valid process ID is required.');
    const data = JSON.parse(await runCaretaker('explain', ['-ProcessId', String(args.processId)]));
    return boundedResult(data);
  }
  if (name === 'event_health') {
    if (Object.keys(args).length) throw new Error('Invalid event arguments.');
    const data = JSON.parse(await runCaretaker('events', ['-WindowDays', '7', '-MaxEventsPerLog', '100']));
    return boundedResult(data);
  }
  if (name === 'inventory') {
    if (Object.keys(args).some(key => !['section', 'query'].includes(key)) || !MODULES.includes(args.section)) throw new Error('A valid inventory section is required.');
    const query = nameQuery(args.query);
    await runCaretaker('snapshot');
    return compactInventory(args.section, query);
  }
  if (name === 'caretaker_status') {
    if (Object.keys(args).length) throw new Error('Invalid status arguments.');
    const output = await runCaretaker('status');
    return { source: 'fresh Caretaker status check', output: output.slice(0, 8000) };
  }
  throw new Error('Tool is not available.');
}

function isSlowdownQuestion(message) {
  return /\b(?:slow(?:ing|ly|ness)?|sluggish|lag(?:gy|ging)?|performance|freez(?:e|ing)|hang(?:ing)?|stutter(?:ing)?)\b/i.test(message);
}

function checkMetadata(tool, result, completed) {
  return { tool,
    capturedAtUtc: typeof result?.capturedAtUtc === 'string' ? result.capturedAtUtc : null,
    state: completed ? (typeof result?.state === 'string' ? result.state
      : typeof result?.coverage?.status === 'string' ? result.coverage.status : 'UNKNOWN') : 'UNAVAILABLE',
    completed };
}

function preferredSettings(models) {
  if (!Array.isArray(models) || !models.length) throw new Error('No chat models are available.');
  const model = models.find(item => item.id === 'gpt-6-luna') ||
    models.find(item => /(?:^|-)luna$/.test(item.id)) ||
    models.find(item => item.isDefault) || models[0];
  const efforts = (model.supportedReasoningEfforts || []).map(item => item.reasoningEffort);
  return { model: model.id, effort: efforts.includes('xhigh') ? 'xhigh'
    : efforts.includes(model.defaultReasoningEffort) ? model.defaultReasoningEffort
      : efforts[0] || model.defaultReasoningEffort || null };
}

async function collectSlowdownEvidence(message, runCheck = callCaretakerTool) {
  if (!isSlowdownQuestion(message)) return { checks: [], context: null };
  const checks = [];
  const results = {};
  for (const tool of ['resources', 'event_health']) {
    try {
      const result = await runCheck(tool, {});
      checks.push(checkMetadata(tool, result, true));
      results[tool] = result;
    } catch {
      checks.push(checkMetadata(tool, null, false));
      results[tool] = { state: 'UNKNOWN', reason: 'Caretaker check unavailable.' };
    }
  }
  return { checks, context: boundedResult({ source: 'fresh Caretaker slowdown checks', results }, 16000) };
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
    this.models = [];
    this.lastChecks = [];
    this.lastSettings = null;
    this.pendingApprovals = new Map();
    this.fileChangePreviews = new Map();
  }

  async start() {
    if (this.child) return;
    const exe = resolveCodexExe();
    // Disable configured integrations using their exact transport shape, then
    // verify the resulting thread has no MCP or app tools before any turn.
    const child = spawn(exe, isolatedCodexArgs(exe), { cwd: ROOT, windowsHide: true,
      stdio: ['pipe', 'pipe', 'pipe'], shell: false });
    this.child = child;
    child.on('error', () => this.fail(new Error('Could not start Codex app-server. Check PATH `codex`, codex.exe, or CARETAKER_CODEX_EXE.')));
    child.on('exit', () => this.fail(new Error('Codex app-server exited. Restart this chat server.')));
    child.stdin.on('error', () => {}); // EPIPE after child exit must not crash the server; send() reports it.
    const lines = readline.createInterface({ input: child.stdout });
    lines.on('line', line => this.onLine(line));
    child.stderr.on('data', () => {}); // Drain, but never expose private diagnostics.
    await this.request('initialize', { clientInfo: { name: 'goliath_caretaker_chat',
      title: 'Goliath Caretaker Chat', version: '0.2.0' },
    capabilities: { experimentalApi: true } }, 10000);
    this.send({ method: 'initialized', params: {} });
    const auth = await this.request('account/read', { refreshToken: false }, 10000);
    if (auth?.account?.type !== 'chatgpt') {
      throw new Error('Sign in to Codex with ChatGPT before using chat.');
    }
    const listed = await this.request('model/list', { limit: 50, includeHidden: false }, 10000);
    if (!Array.isArray(listed?.data)) throw new Error('Codex did not provide a model list.');
    this.models = listed.data.filter(item => typeof item?.model === 'string' && item.model &&
      typeof item.displayName === 'string' && item.hidden !== true).map(item => ({
        id: item.model, displayName: item.displayName, isDefault: item.isDefault === true,
        defaultReasoningEffort: item.defaultReasoningEffort,
        supportedReasoningEfforts: Array.isArray(item.supportedReasoningEfforts)
          ? item.supportedReasoningEfforts.filter(option => typeof option?.reasoningEffort === 'string' &&
            /^[a-z]+$/.test(option.reasoningEffort)).map(option => ({
            reasoningEffort: option.reasoningEffort,
            description: typeof option.description === 'string' ? option.description : '',
          })) : [],
      }));
    if (!this.models.length) throw new Error('No chat models are available in Codex.');
    const started = await this.request('thread/start', {
      cwd: ROOT, approvalPolicy: 'untrusted', sandbox: 'danger-full-access',
      personality: 'friendly', serviceName: 'goliath_caretaker_chat',
      dynamicTools: TOOL_DEFS,
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
    const child = this.child;
    if (this.closed || !child || !child.stdin.writable || child.exitCode !== null || child.signalCode) {
      throw new Error('Codex is unavailable.');
    }
    child.stdin.write(JSON.stringify(obj) + '\n');
  }

  // Before the turn/start reply, the first turn-scoped event names the turn; after it, ids must match.
  ownsTurn(turnId) {
    if (!this.turn) return false;
    if (typeof turnId !== 'string' || !turnId) return true;
    if (!this.turn.id) this.turn.id = turnId;
    return this.turn.id === turnId;
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

  rememberPatchPreview(itemId, changes) {
    const preview = JSON.stringify(changes);
    this.fileChangePreviews.set(itemId, preview.length <= 8000 ? preview : null);
  }

  onLine(line) {
    if (line.length > 1024 * 1024) { this.fail(new Error('Codex response exceeded the limit.')); return; }
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    if (!msg || typeof msg !== 'object') return;
    const hasId = msg.id !== undefined && msg.id !== null;
    if (typeof msg.method === 'string' && hasId) {
      // Server-initiated request: never confuse it with a reply to our own id space.
      if (msg.method === 'item/tool/call') { this.handleToolCall(msg).catch(() => {}); return; }
      if (['item/commandExecution/requestApproval', 'item/fileChange/requestApproval',
        'item/permissions/requestApproval'].includes(msg.method)) {
        this.handleApprovalRequest(msg); return;
      }
      try { this.send({ id: msg.id, error: { code: -32601, message: 'Unsupported by Caretaker chat.' } }); } catch {}
      return;
    }
    if (hasId) {
      const pending = this.pending.get(msg.id);
      if (!pending) return;
      this.pending.delete(msg.id);
      clearTimeout(pending.timer);
      if (msg.error) pending.reject(new Error('Codex rejected the request.'));
      else pending.resolve(msg.result);
      return;
    }
    if (!this.turn || msg.params?.threadId !== this.threadId) return;
    if (['item/started', 'item/updated'].includes(msg.method) &&
        this.ownsTurn(msg.params.turnId) && msg.params.item?.type === 'fileChange' &&
        typeof msg.params.item.id === 'string' && Array.isArray(msg.params.item.changes) &&
        msg.params.item.changes.length) {
      this.rememberPatchPreview(msg.params.item.id, msg.params.item.changes);
      return;
    }
    if (msg.method === 'item/fileChange/patchUpdated' && this.ownsTurn(msg.params.turnId) &&
        typeof msg.params.itemId === 'string' && Array.isArray(msg.params.changes) && msg.params.changes.length) {
      this.rememberPatchPreview(msg.params.itemId, msg.params.changes);
      return;
    }
    if (msg.method === 'item/agentMessage/delta' && typeof msg.params.delta === 'string') {
      if (!this.ownsTurn(msg.params.turnId)) return;
      this.turn.text = (this.turn.text + msg.params.delta).slice(0, MAX_REPLY);
    } else if (msg.method === 'item/completed' && msg.params.item?.type === 'agentMessage') {
      if (!this.ownsTurn(msg.params.turnId)) return;
      const text = msg.params.item.text;
      if (typeof text === 'string') this.turn.text = text.slice(0, MAX_REPLY);
    } else if (msg.method === 'turn/completed') {
      if (!this.ownsTurn(msg.params.turn?.id)) return;
      const active = this.turn;
      this.turn = null;
      clearTimeout(active.timer);
      this.denyPendingApprovals();
      this.fileChangePreviews.clear();
      if (msg.params.turn?.status !== 'completed' || msg.params.turn?.error) {
        active.reject(new Error('Codex could not complete this turn.'));
      } else {
        this.lastChecks = active.checks || [];
        active.resolve(active.text || 'Codex returned no message.');
      }
    }
  }

  handleApprovalRequest(msg) {
    const params = msg.params || {};
    const kind = msg.method === 'item/commandExecution/requestApproval' ? 'command'
      : msg.method === 'item/fileChange/requestApproval' ? 'file' : 'permissions';
    if (this.closed || !this.turn || params.threadId !== this.threadId ||
        typeof params.turnId !== 'string' || !this.ownsTurn(params.turnId) ||
        typeof params.itemId !== 'string' || this.pendingApprovals.size >= 3) {
      try { this.send({ id: msg.id, result: kind === 'permissions'
        ? { permissions: {}, scope: 'turn' } : { decision: 'decline' } }); } catch {}
      return;
    }
    const id = crypto.randomBytes(16).toString('hex');
    const preview = kind === 'file' ? this.fileChangePreviews.get(params.itemId) : null;
    const command = kind === 'command' ? params.command : null;
    const permissionDetails = kind === 'permissions' ? JSON.stringify(params.permissions || {}) : null;
    if ((kind === 'file' && !preview) ||
        (kind === 'command' && (typeof command !== 'string' || !command || command.length > 8000)) ||
        (kind === 'permissions' && (!params.permissions || permissionDetails.length > 8000)) ||
        (typeof params.cwd === 'string' && params.cwd.length > 1000) ||
        (typeof params.reason === 'string' && params.reason.length > 2000)) {
      try { this.send({ id: msg.id, result: kind === 'permissions'
        ? { permissions: {}, scope: 'turn' } : { decision: 'decline' } }); } catch {}
      return;
    }
    const approval = { id, kind,
      title: kind === 'command' ? 'Approve local command' : kind === 'file' ? 'Approve file change' : 'Approve additional access',
      command,
      cwd: typeof params.cwd === 'string' ? params.cwd : null,
      reason: typeof params.reason === 'string' ? params.reason : null,
      details: kind === 'file' ? preview
        : kind === 'permissions' ? permissionDetails : null };
    this.pendingApprovals.set(id, { rpcId: msg.id, kind, params, approval });
  }

  approvalView() {
    return this.pendingApprovals.values().next().value?.approval || null;
  }

  resolveApproval(id, decision) {
    const pending = this.pendingApprovals.get(id);
    if (!pending || !this.turn || !this.ownsTurn(pending.params.turnId) ||
        !['accept', 'decline'].includes(decision)) return false;
    if (decision === 'accept' && pending.kind === 'command' &&
        Array.isArray(pending.params.availableDecisions) &&
        !pending.params.availableDecisions.includes('accept')) return false;
    const result = pending.kind === 'permissions'
      ? { permissions: decision === 'accept' ? pending.params.permissions : {}, scope: 'turn' }
      : { decision };
    this.send({ id: pending.rpcId, result });
    this.pendingApprovals.delete(id);
    return true;
  }

  denyPendingApprovals() {
    for (const pending of this.pendingApprovals.values()) {
      try { this.send({ id: pending.rpcId, result: pending.kind === 'permissions'
        ? { permissions: {}, scope: 'turn' } : { decision: 'decline' } }); } catch {}
    }
    this.pendingApprovals.clear();
  }

  async handleToolCall(msg) {
    const params = msg.params || {};
    const active = this.turn;
    if (!active || params.threadId !== this.threadId || !params.turnId ||
        !this.ownsTurn(params.turnId) || active.toolCalls >= 6) {
      this.send({ id: msg.id, result: { success: false,
        contentItems: [{ type: 'inputText', text: 'Caretaker tool call is unavailable for this turn.' }] } });
      return;
    }
    active.toolCalls++;
    try {
      const result = await callCaretakerTool(params.tool, params.arguments);
      if (this.turn !== active || this.closed) return;
      active.checks.push(checkMetadata(params.tool, result, true));
      this.send({ id: msg.id, result: { success: true,
        contentItems: [{ type: 'inputText', text: JSON.stringify(result).slice(0, 12000) }] } });
    } catch (error) {
      if (this.turn !== active || this.closed) return;
      active.checks.push(checkMetadata(params.tool, null, false));
      this.send({ id: msg.id, result: { success: false,
        contentItems: [{ type: 'inputText', text: (error.message || 'Caretaker check failed.').slice(0, 300) }] } });
    }
  }

  async ask(message, model, effort, prefetched = { checks: [], context: null }) {
    try { await this.start(); }
    catch (error) { this.close(); throw error; }
    if (this.turn) throw new Error('A reply is already in progress.');
    this.lastChecks = [...prefetched.checks];
    const defaults = preferredSettings(this.models);
    const selectedModel = this.models.find(item => item.id === (model || defaults.model));
    if (!selectedModel) throw new Error('Choose a model from the Codex model list.');
    const availableEfforts = selectedModel.supportedReasoningEfforts.map(item => item.reasoningEffort);
    const selectedEffort = effort || (selectedModel.id === defaults.model ? defaults.effort
      : selectedModel.defaultReasoningEffort || availableEfforts[0]);
    if (!selectedEffort || !availableEfforts.includes(selectedEffort)) {
      throw new Error('Choose a reasoning effort supported by the selected model.');
    }
    const evidence = boundedEvidence();
    const patchGuidance = 'If a file patch is rejected because no reviewable diff was supplied, use a local command for that requested change; the user will review and approve the exact command. ';
    const prefix = `You are Goliath Caretaker for this Windows workstation. You may use Codex's local tools to read, diagnose, and change the system as the user requests. The dashboard will ask the user to approve each command or file change; never treat that approval as permission for unrelated actions. Do not self-elevate. Respect the current Windows account's permissions, inspect relevant state before changing it, explain material effects and rollback, and verify the result. Do not contact external services unless the user requests it. The read-only Caretaker tools provide structured checks for current status, resources, processes, listeners, services, tasks, startup, and recent events. A broad slowdown question includes fresh resources and recent event health below; use those results and call additional tools only when they would clarify the answer. A short CPU sample cannot establish sustained load, and memory working set alone does not prove pressure. Missing disk latency, paging, or history is UNKNOWN rather than healthy. Separate measured facts from possible causes. Do not guess current state from the historical snapshot. State capture time and coverage; if evidence is missing, say UNKNOWN. Saved summary (historical context only): ${JSON.stringify(evidence)}\nFresh checks for this question: ${JSON.stringify(prefetched.context || 'none')}\n\nUser question: `;
    const done = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.turn = null;
        reject(new Error('The reply timed out. Restart chat to try again.'));
      }, TURN_TIMEOUT);
      this.turn = { text: '', resolve, reject, timer, id: null, toolCalls: 0, checks: [...prefetched.checks] };
    });
    done.catch(() => {}); // A request failure may arrive before we await completion.
    try {
      const result = await this.request('turn/start', {
        threadId: this.threadId,
        input: [{ type: 'text', text: patchGuidance + prefix + message }],
        model: selectedModel.id,
        effort: selectedEffort,
        cwd: ROOT, approvalPolicy: 'untrusted',
        sandboxPolicy: { type: 'dangerFullAccess' },
      }, 15000);
      if (!result?.turn?.id) throw new Error('Codex did not start the turn.');
      if (this.turn && this.turn.id && this.turn.id !== result.turn.id) throw new Error('Codex turn identity did not match.');
      if (this.turn) this.turn.id = result.turn.id;
      const reply = await done;
      this.lastSettings = { model: selectedModel.id, effort: selectedEffort };
      return reply;
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
    this.denyPendingApprovals();
    this.closed = true;
    this.fail(new Error('Chat closed.'));
    for (const child of ACTIVE_CARETAKER_CHILDREN) child.kill();
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
  let leaveTimer = null;
  const page = fs.readFileSync(PAGE, 'utf8').replace('__CSRF_TOKEN__', token);
  let port;
  const server = http.createServer(async (req, res) => {
    lastVisit = Date.now();
    if (!validHost(req.headers.host, port)) { json(res, 403, { error: 'Invalid host.' }); return; }
    if (req.method === 'GET' && req.url === '/') {
      clearTimeout(leaveTimer); leaveTimer = null; // A reload returns within the leave grace.
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
        'Content-Security-Policy': "default-src 'none'; script-src 'nonce-caretaker'; style-src 'nonce-caretaker'; connect-src 'self'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'" });
      res.end(page); return;
    }
    if (req.method === 'GET' && req.url === '/models') {
      if (req.headers['x-caretaker-csrf'] !== token) {
        json(res, 403, { error: 'Request rejected.' }); return;
      }
      clearTimeout(leaveTimer); leaveTimer = null;
      try {
        await session.start();
        const defaults = preferredSettings(session.models);
        json(res, 200, { models: session.models,
          selectedModel: defaults.model, selectedEffort: defaults.effort });
      } catch (error) {
        session.close();
        json(res, 503, { error: error.message || 'Could not load Codex models.' });
      }
      return;
    }
    if (req.method === 'GET' && req.url === '/summary') {
      if (req.headers['x-caretaker-csrf'] !== token) {
        json(res, 403, { error: 'Request rejected.' }); return;
      }
      json(res, 200, { snapshot: boundedEvidence(), generatedAtUtc: new Date().toISOString() });
      return;
    }
    if (req.method === 'GET' && req.url === '/approval') {
      if (req.headers['x-caretaker-csrf'] !== token) {
        json(res, 403, { error: 'Request rejected.' }); return;
      }
      json(res, 200, { approval: session.approvalView() });
      return;
    }
    if (req.method !== 'POST' || !['/chat', '/close', '/leave', '/approval'].includes(req.url)) {
      json(res, 404, { error: 'Not found.' }); return;
    }
    if (!validPost(req, token, port)) { json(res, 403, { error: 'Request rejected.' }); return; }
    if (req.url === '/approval') {
      try {
        let body = '';
        for await (const chunk of req) {
          body += chunk;
          if (Buffer.byteLength(body) > 1024) throw new Error('Approval response is too large.');
        }
        const parsed = JSON.parse(body);
        if (typeof parsed.id !== 'string' || !session.resolveApproval(parsed.id, parsed.decision)) {
          json(res, 409, { error: 'Approval is no longer pending.' }); return;
        }
        json(res, 200, { ok: true });
      } catch { json(res, 400, { error: 'Invalid approval response.' }); }
      return;
    }
    if (req.url === '/close') { json(res, 200, { ok: true }); shutdown(); return; }
    if (req.url === '/leave') {
      json(res, 200, { ok: true });
      if (!leaveTimer) leaveTimer = setTimeout(shutdown, LEAVE_GRACE);
      return;
    }
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
      if (typeof parsed.model !== 'string' || parsed.model.length > 100) {
        throw new Error('Choose a model from the list.');
      }
      if (parsed.effort !== undefined &&
          (typeof parsed.effort !== 'string' || parsed.effort.length > 20)) {
        throw new Error('Choose a reasoning effort from the list.');
      }
      turns++;
      const question = parsed.message.trim();
      const prefetched = await collectSlowdownEvidence(question);
      const reply = await session.ask(question, parsed.model, parsed.effort, prefetched);
      json(res, 200, { reply, checks: session.lastChecks, ...session.lastSettings });
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
    server.closeAllConnections?.();
    const deadline = Date.now() + CHILD_EXIT_WAIT;
    const childAlive = () => session.child && session.child.exitCode === null && !session.child.signalCode;
    (function finish() {
      if ((childAlive() || ACTIVE_CARETAKER_CHILDREN.size) && Date.now() < deadline) { setTimeout(finish, 100); return; }
      if (childAlive()) {
        console.error('Could not verify Codex child exit; no force kill attempted.');
        process.exitCode = 1;
      }
      if (ACTIVE_CARETAKER_CHILDREN.size) {
        console.error('Could not verify Caretaker check exit.');
        process.exitCode = 1;
      }
      process.exit();
    })();
  }
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
  setInterval(() => {
    if (!busy && Date.now() - lastVisit > IDLE_TIMEOUT) shutdown();
  }, 30000).unref();
}

if (require.main === module) main();
module.exports = { boundedEvidence, validHost, validPost, isolatedCodexArgs, compactInventory,
  nameQuery, callCaretakerTool, isSlowdownQuestion, collectSlowdownEvidence, preferredSettings, CodexSession,
  resolveCodexExe, resolveNpmWrapperCodexExe, resolvePathCodexExe };
