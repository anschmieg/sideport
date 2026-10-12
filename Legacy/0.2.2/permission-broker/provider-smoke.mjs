import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { providerManager } from './providers.mjs';
import { root } from './policy.mjs';
const outside = await fs.mkdtemp('/private/tmp/mac-permission-test-');
await fs.writeFile(outside + '/sentinel', 'synthetic denied sentinel');
const allowed = await fs.mkdtemp('/private/tmp/mac-permission-test-');
await fs.writeFile(allowed + '/sentinel', 'synthetic allowed sentinel');
const session = await fs.mkdtemp(root + '/work/permission-sessions/smoke-');
await fs.writeFile(session + '/grants.json', JSON.stringify([{ path: allowed, kind: 'directory', access: 'read_write' }]));
const libraries = new Set(), queue = [process.execPath], checked = new Set();
while (queue.length) {
  const binary = queue.pop(); if (checked.has(binary)) continue; checked.add(binary);
  const { stdout } = await promisify(execFile)('/usr/bin/otool', ['-L', binary]);
  for (const line of stdout.split('\n').slice(1)) {
    const item = line.trim().split(' (')[0]; if (!item.startsWith('/opt/homebrew/')) continue;
    const resolved = await fs.realpath(item); libraries.add(path.dirname(resolved)); queue.push(resolved);
  }
}
const children = new Set(), manager = providerManager(session, libraries, children);
try {
  const started = manager.call('request_server', { package: '@modelcontextprotocol/server-filesystem', version: '2026.8.31', args: [allowed], reason: 'Run the known filesystem package against synthetic fixtures to verify isolated on-demand execution.' });
  let file;
  for (let i = 0; i < 100; i++) {
    file = (await fs.readdir(session)).find(f => f.endsWith('.capability.json'));
    if (file) break; await new Promise(resolve => setTimeout(resolve, 30));
  }
  assert.ok(file);
  const request = JSON.parse(await fs.readFile(session + '/' + file, 'utf8'));
  assert.equal(request.capability, 'npm_server');
  assert.ok(request.details.network === 'blocked');
  await fs.writeFile(session + '/' + request.id + '.decision.json', JSON.stringify({ id: request.id, capability: request.capability, approved: true }));
  const result = JSON.parse((await started).content[0].text);
  assert.equal(result.status, 'running'); console.log('PASS: exact-version package downloaded, audited and sandboxed; protocol ' + result.protocol);
  const tools = result.tools.map(tool => tool.name); assert.ok(tools.includes('read_file') || tools.includes('read_text_file'));
  const reader = tools.includes('read_text_file') ? 'read_text_file' : 'read_file';
  const read = await manager.call('call_server_tool', { id: result.id, tool: reader, arguments: { path: allowed + '/sentinel' } });
  assert.ok(!read.isError && JSON.stringify(read).includes('synthetic allowed sentinel'), JSON.stringify(read));
  const denied = await manager.call('call_server_tool', { id: result.id, tool: reader, arguments: { path: outside + '/sentinel' } }); assert.ok(denied.isError);
  await manager.call('stop_server', { id: result.id }); assert.equal(children.size, 0);
  console.log('PASS: provider tool invocation, denied path and explicit shutdown.');
} finally {
  manager.close(); await Promise.all([fs.rm(session, { recursive: true, force: true }), fs.rm(outside, { recursive: true, force: true }), fs.rm(allowed, { recursive: true, force: true })]);
}
