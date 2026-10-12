import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
import { Client } from '../baseline/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js';
import { StreamableHTTPClientTransport } from '../baseline/node_modules/@modelcontextprotocol/sdk/dist/esm/client/streamableHttp.js';
import { root } from './policy.mjs';
const config = JSON.parse(await fs.readFile(root + '/work/mcpproxy-pilot/config.json', 'utf8'));
const client = new Client({ name: 'local-gateway-check', version: '1' });
const token = process.argv.includes('--admin') ? config.api_key : (await fs.readFile(root + '/work/mcpproxy-runtime.key', 'utf8')).trim();
await client.connect(new StreamableHTTPClientTransport(new URL('http://127.0.0.1:18089/mcp'), { requestInit: { headers: { 'X-API-Key': token } } }));
try {
  if (process.argv.includes('--tools')) {
    console.log(JSON.stringify((await client.listTools()).tools.map(t => ({ name: t.name, schema: t.inputSchema }))));
  } else if (process.argv.includes('--discover')) {
    console.log(JSON.stringify(await client.callTool({ name: 'quarantine_security', arguments: { operation: 'inspect_quarantined', name: 'permissions' } })));
  } else {
    console.log(JSON.stringify(await client.callTool({ name: 'call_tool_read', arguments: { name: 'permissions:allowed_locations', args: {} } })));
    const denied = await client.callTool({ name: 'upstream_servers', arguments: { operation: 'patch', name: 'permissions', patch: {} } });
    if (!process.argv.includes('--admin')) assert.ok(denied.isError && JSON.stringify(denied).includes('Agent tokens cannot'), 'Agent must not have administrator access');
    console.log(JSON.stringify(denied));
  }
} finally { await client.close(); }
