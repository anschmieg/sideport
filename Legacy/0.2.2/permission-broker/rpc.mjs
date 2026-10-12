import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import { StringDecoder } from 'node:string_decoder';
const version = '2026-07-28';
const identity = { name: 'mac-chatgpt-admission', version: '1.1.0' };
export class StdioPeer {
  constructor(command, args, options = {}) {
    this.pending = new Map(); this.buffer = ''; this.decoder = new StringDecoder('utf8'); this.closed = false;
    this.child = spawn(command, args, { ...options, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
    this.child.stdout.on('data', bytes => {
      this.buffer += this.decoder.write(bytes);
      if (this.buffer.length > 4 * 1024 * 1024) { this.close(); return; }
      let newline;
      while ((newline = this.buffer.indexOf('\n')) !== -1) {
        const line = this.buffer.slice(0, newline); this.buffer = this.buffer.slice(newline + 1);
        if (!line.trim()) continue;
        try {
          const message = JSON.parse(line);
          if (message.method && message.id !== undefined) {
            this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Client-side requests are not permitted' } }) + '\n');
          } else if (message.id !== undefined && this.pending.has(message.id)) {
            const pending = this.pending.get(message.id); this.pending.delete(message.id); clearTimeout(pending.timer);
            if (message.error) pending.reject(Object.assign(new Error(message.error.message), { code: message.error.code }));
            else pending.resolve(message.result);
          }
        } catch { this.close(); }
      }
    });
    this.child.stderr.on('data', () => {}); // Drain without retaining arbitrary provider logs.
    this.child.stdin.on('error', () => this.close());
    this.child.on('error', () => this.close());
    this.child.on('close', () => this.close());
  }
  async request(method, params = {}, timeout = 30000) {
    if (this.closed) throw new Error('Server is not running');
    const id = crypto.randomUUID();
    if (this.protocol === version || method === 'server/discover') params = { ...params, _meta: {
      'io.modelcontextprotocol/protocolVersion': version,
      'io.modelcontextprotocol/clientInfo': identity,
      'io.modelcontextprotocol/clientCapabilities': {}
    } };
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); if (method !== 'server/discover') this.close(); reject(new Error('Server request timed out')); }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n', error => {
        if (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
      });
    });
  }
  async connect() {
    try {
      const discovery = await this.request('server/discover', {}, 4000);
      if (discovery.supportedVersions?.includes(version)) { this.protocol = version; return; }
    } catch (error) { if (![undefined, -32601, -32602, -32022].includes(error.code)) throw error; }
    const result = await this.request('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: identity });
    if (!['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'].includes(result.protocolVersion)) throw new Error('Unsupported protocol');
    this.protocol = result.protocolVersion;
    this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  }
  close() {
    if (this.closed) return;
    this.closed = true;
    try { process.kill(-this.child.pid, 'SIGKILL'); } catch {}
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error('Server stopped')); }
    this.pending.clear();
  }
}
