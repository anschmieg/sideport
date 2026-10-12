import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
import { Client } from '../baseline/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js';
import { StdioClientTransport } from '../baseline/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js';
import { root, workspace } from './policy.mjs';
const config = JSON.parse(await fs.readFile(root + '/work/mcpproxy-pilot/config.json', 'utf8'));
const session = config.mcpServers.find(s => s.name === 'permissions').env.MAC_CHATGPT_APPROVAL_DIR;
const client = new Client({ name: 'native-provider-test', version: '1' });
await client.connect(new StdioClientTransport({ command: process.execPath, args: [root + '/work/permission-broker/server.mjs'], env: { SIDEPORT_HOME: root, HOME: process.env.HOME, PATH: root + '/work/node/bin:/usr/bin:/bin', MAC_CHATGPT_APPROVAL_DIR: session } }));
try {
  console.log('Waiting for native MCP server approval.');
  const response = await client.callTool({ name: 'request_server', arguments: { package: '@modelcontextprotocol/server-filesystem', version: '2026.8.31', args: [workspace], reason: 'Test the new permission prompt. The file tool will start, show its available actions, and then stop. It will not read or change your files.' } }, undefined, { timeout: 120000 });
  assert.ok(!response.isError, JSON.stringify(response));
  const result = JSON.parse(response.content[0].text);
  console.log('Native decision: ' + result.status);
  if (result.status === 'running') {
    const stopped = await client.callTool({ name: 'stop_server', arguments: { id: result.id } }); assert.ok(!stopped.isError);
    console.log('PASS: actual native approval started and stopped the reviewed package.');
  } else assert.equal(result.status, 'denied');
} finally { await client.close(); }
