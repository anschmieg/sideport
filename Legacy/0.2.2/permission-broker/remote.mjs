import https from 'node:https';
import http from 'node:http';
import dns from 'node:dns/promises';
import net from 'node:net';
import crypto from 'node:crypto';
export function publicAddress(address) {
  if (net.isIPv4(address)) {
    const [a, b] = address.split('.').map(Number);
    return !(a === 0 || a === 10 || a === 127 || a >= 224 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && [0, 168].includes(b)) || (a === 198 && [18, 19, 51].includes(b)) || (a === 203 && b === 0));
  }
  return net.isIPv6(address) && /^[23]/.test(address) && !/^2001:db8:/i.test(address);
}
export function remoteURL(value, managed = false) {
  if (typeof value !== 'string' || value.length > 2000 || /[\x00-\x20\x7f]/.test(value)) throw new Error('Invalid remote URL');
  const url = new URL(value);
  if ((!managed && (url.protocol !== 'https:' || (url.port && url.port !== '443'))) || (managed && !['https:', 'http:'].includes(url.protocol)) || (url.protocol === 'http:' && !['localhost', '127.0.0.1', '[::1]'].includes(url.hostname)) || url.username || url.password || url.hash || url.search) throw new Error('Use a public HTTPS endpoint on port 443 without embedded credentials or query parameters');
  return url;
}
async function post(url, data, headers, managed = false) {
  const host = url.hostname.replace(/^\[|\]$/g, '');
  const addresses = net.isIP(host) ? [{ address: host, family: net.isIP(host) }] : await dns.lookup(host, { all: true });
  if (!addresses.length || (!managed && addresses.some(a => !publicAddress(a.address)))) throw new Error('Local, private and reserved remote endpoints are blocked');
  const chosen = addresses.find(a => a.family === 4) || addresses[0];
  return await new Promise((resolve, reject) => {
    const req = (url.protocol === 'https:' ? https : http).request(url, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
      lookup: (_host, options, callback) => options.all ? callback(null, [chosen]) : callback(null, chosen.address, chosen.family) }, response => {
      let body = '', size = 0;
      response.on('data', bytes => { size += bytes.length; if (size > 4 * 1024 * 1024) req.destroy(new Error('Remote response too large')); else body += bytes; });
      response.on('error', reject);
      response.on('end', () => resolve({ status: response.statusCode, body, headers: response.headers }));
    });
    const deadline = setTimeout(() => req.destroy(new Error('Remote server timed out')), 30000);
    req.on('close', () => clearTimeout(deadline)); req.on('error', reject); req.end(JSON.stringify(data));
  });
}
export class RemotePeer {
  constructor(url, options = {}) { this.url = remoteURL(url, options.managed === true); this.managed = options.managed === true; this.headers = options.headers || {}; this.closed = false; }
  async request(method, params = {}) {
    if (this.closed) throw new Error('Remote provider is stopped');
    const july = this.protocol === '2026-07-28' || method === 'server/discover';
    const id = crypto.randomUUID();
    if (july) params = { ...params, _meta: { 'io.modelcontextprotocol/protocolVersion': '2026-07-28', 'io.modelcontextprotocol/clientInfo': { name: 'mac-chatgpt-admission', version: '1.1.0' }, 'io.modelcontextprotocol/clientCapabilities': {} } };
    const headers = { ...this.headers, 'MCP-Protocol-Version': july ? '2026-07-28' : (this.protocol || '2025-11-25'), 'Mcp-Method': method };
    if (params.name) headers['Mcp-Name'] = params.name;
    if (this.session && !july) headers['Mcp-Session-Id'] = this.session;
    const response = await post(this.url, { jsonrpc: '2.0', id, method, params }, headers, this.managed);
    if (response.status < 200 || response.status >= 300) throw Object.assign(new Error('Remote MCP HTTP ' + response.status), { code: response.status });
    if (response.headers['mcp-session-id']) this.session = response.headers['mcp-session-id'];
    let payload;
    if ((response.headers['content-type'] || '').includes('text/event-stream')) {
      for (const event of response.body.split(/\r?\n\r?\n/)) {
        const data = event.split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
        if (!data) continue;
        const item = JSON.parse(data); if (item.id === id) payload = item;
      }
    } else payload = JSON.parse(response.body);
    if (payload?.id !== id) throw new Error('Remote response id mismatch');
    if (payload.error) throw Object.assign(new Error(payload.error.message), { code: payload.error.code });
    return payload.result;
  }
  async connect() {
    try {
      const discovery = await this.request('server/discover');
      if (discovery.supportedVersions?.includes('2026-07-28')) { this.protocol = '2026-07-28'; return; }
    } catch (error) { if (![400, 404, 405, 406, 415, -32601, -32602, -32022].includes(error.code)) throw error; }
    const result = await this.request('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'mac-chatgpt-admission', version: '1.1.0' } });
    if (!['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'].includes(result.protocolVersion)) throw new Error('Unsupported remote protocol');
    this.protocol = result.protocolVersion;
    const response = await post(this.url, { jsonrpc: '2.0', method: 'notifications/initialized' }, { ...this.headers, 'MCP-Protocol-Version': this.protocol, ...(this.session ? { 'Mcp-Session-Id': this.session } : {}) }, this.managed);
    if (response.status < 200 || response.status >= 300) throw new Error('Remote initialization notification failed');
  }
  close() { this.closed = true; }
}
