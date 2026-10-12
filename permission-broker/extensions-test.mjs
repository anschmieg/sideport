import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { providerManager } from './providers.mjs';
import { npmSpec, validateArgs, validateBin, selectorDrag } from './provider-policy.mjs';
import { publicAddress, remoteURL } from './remote.mjs';
import { StdioPeer } from './rpc.mjs';
import { root, workspace, grants } from './policy.mjs';
for (const spec of [['foo', 'latest'], ['https://evil.test', '1.0.0'], ['../secret', '1.0.0'], ['foo', '^1.0.0']]) assert.throws(() => npmSpec(...spec));
assert.equal(npmSpec('@scope/server', '1.2.3'), '@scope/server@1.2.3');
assert.throws(() => validateArgs(['bad\narg']));
assert.throws(() => validateBin('/cache/pkg', '../escape.js'));
assert.throws(() => selectorDrag('drag', { from: '10,20', to: '30,40' }));
assert.throws(() => selectorDrag('drag', { startX: 1, startY: 2, endX: 3, endY: 4 }));
assert.throws(() => selectorDrag('drag', { from: 'B1', to: 'B2', from_coords: '10,20' }));
selectorDrag('drag', { from: 'B1', to: 'B2' });
for (const ip of ['127.0.0.1', '10.2.3.4', '172.16.0.1', '192.168.1.1', '169.254.169.254', '::1', '::ffff:127.0.0.1', 'fe80::1', '2001:db8::1']) assert.equal(publicAddress(ip), false);
assert.equal(publicAddress('1.1.1.1'), true);
for (const url of ['http://example.com/mcp', 'https://user:pass@example.com/mcp', 'https://example.com:444/mcp', 'https://example.com/mcp?token=secret']) assert.throws(() => remoteURL(url));
const session = await fs.mkdtemp(root + '/work/permission-sessions/test-');
await fs.writeFile(session + '/grants.json', JSON.stringify([{ path: workspace, kind: 'directory', access: 'read_write' }]));
const children = new Set();
const manager = providerManager(session, [], children);
async function decide(approved) {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    const file = (await fs.readdir(session)).find(file => file.endsWith('.capability.json'));
    if (file) {
      const request = JSON.parse(await fs.readFile(session + '/' + file, 'utf8'));
      await fs.writeFile(session + '/' + request.id + '.decision.json', JSON.stringify({ id: request.id, capability: request.capability, approved }));
      return;
    }
    await new Promise(resolve => setTimeout(resolve, 30));
  }
  throw new Error('Approval was not requested');
}
try {
  const denied = manager.call('request_computer_control', { reason: 'Synthetic denial test' });
  await decide(false); assert.equal(JSON.parse((await denied).content[0].text).status, 'denied');
  const blocked = await manager.call('computer_action', { tool: 'click', arguments: {} }); assert.ok(blocked.isError);
  const npmDenied = manager.call('request_server', { package: '@modelcontextprotocol/server-filesystem', version: '2026.8.31', args: [workspace], reason: 'Synthetic denial test' });
  await decide(false); assert.equal(JSON.parse((await npmDenied).content[0].text).status, 'denied');
  assert.equal(children.size, 0);
  const removed = await fs.mkdtemp('/private/tmp/mac-permission-test-');
  await fs.writeFile(session + '/grants.json', JSON.stringify([{ path: workspace, kind: 'directory', access: 'read_write' }, { path: removed, kind: 'directory', access: 'read' }]));
  await fs.rm(removed, { recursive: true }); assert.equal((await grants(session)).length, 1);
  console.log('PASS: exact versions, safe package executables, selector-only drag, denial without process startup, deleted grants do not block remaining locations.');
} finally { manager.close(); await fs.rm(session, { recursive: true, force: true }); }
// Exercise both protocol modes against harmless synthetic servers, without downloading code.
for (const july of [true, false]) {
  const source = `let b='';process.stdin.on('data',d=>{b+=d;let n;while((n=b.indexOf('\\n'))>=0){const m=JSON.parse(b.slice(0,n));b=b.slice(n+1);if(m.id===undefined)continue;let r;if(m.method==='server/discover'){${july ? "r={supportedVersions:['2026-07-28'],capabilities:{tools:{}}};" : "process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,error:{code:-32601,message:'unsupported'}})+'\\n');continue;"}}else if(m.method==='initialize')r={protocolVersion:'2025-11-25',capabilities:{},serverInfo:{name:'fixture',version:'1'}};else if(m.method==='tools/list')r={tools:[]};else r={content:[{type:'text',text:'fixture'}]};process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result:r})+'\\n');}});`;
  const peer = new StdioPeer(process.execPath, ['-e', source], { env: { PATH: '/usr/bin:/bin' } });
  try { await peer.connect(); assert.equal(peer.protocol, july ? '2026-07-28' : '2025-11-25'); assert.deepEqual((await peer.request('tools/list')).tools, []); }
  finally { peer.close(); }
}
console.log('PASS: July 2026 discovery and legacy fallback.');
