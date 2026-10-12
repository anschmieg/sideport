// Runs locally before opening the tunnel. Never returns the admin key to MCP.
import fs from 'node:fs/promises';
import { root } from './policy.mjs';
import { reviewBundle } from './bundled-review.mjs';
const config = JSON.parse(await fs.readFile(root + '/work/mcpproxy-pilot/config.json', 'utf8'));
async function api(method, suffix, body) {
  const response = await fetch('http://127.0.0.1:18089/api/v1/tokens' + suffix, {
    method, headers: { 'X-API-Key': config.api_key, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(10000)
  });
  if (method === 'DELETE' && response.status === 404) return null;
  if (!response.ok) throw new Error('Local credential setup failed (' + response.status + ')');
  return response.status === 204 ? null : await response.json();
}
await api('DELETE', '/mac-chatgpt-session/permanent');
if (!process.argv.includes('--revoke')) {
  await reviewBundle(config);
  const response = await api('POST', '', { name: 'mac-chatgpt-session', allowed_servers: ['permissions'], permissions: ['read', 'write', 'destructive'], expires_in: '365d' });
  const token = (response.data || response).token;
  if (typeof token !== 'string' || !token.startsWith('mcp_agt_')) throw new Error('Invalid scoped credential');
  await fs.writeFile(root + '/work/mcpproxy-runtime.key', token + '\n', { mode: 0o600 });
  await fs.chmod(root + '/work/mcpproxy-runtime.key', 0o600);
  console.log('Scoped connection credential ready.');
} else {
  await fs.rm(root + '/work/mcpproxy-runtime.key', { force: true });
  console.log('Scoped connection credential revoked.');
}
