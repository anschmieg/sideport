import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { providerManager } from './providers.mjs';
import { root } from './policy.mjs';
const name = '@local-test/kernel-probe', version = '1.0.0';
const spec = name + '@' + version;
const cache = root + '/work/provider-cache/' + crypto.createHash('sha256').update(spec).digest('hex');
const packageRoot = cache + '/node_modules/' + name;
const session = await fs.mkdtemp(root + '/work/permission-sessions/probe-');
const allowed = await fs.mkdtemp('/private/tmp/mac-permission-test-');
const denied = await fs.mkdtemp('/private/tmp/mac-permission-test-');
await fs.writeFile(denied + '/sentinel', 'private synthetic sentinel');
await fs.writeFile(session + '/grants.json', JSON.stringify([{ path: allowed, kind: 'directory', access: 'read_write' }]));
await fs.mkdir(packageRoot, { recursive: true });
await fs.writeFile(cache + '/approved-install.json', JSON.stringify({ spec }));
await fs.writeFile(packageRoot + '/package.json', JSON.stringify({ name, version, bin: { probe: 'probe.mjs' } }));
await fs.writeFile(packageRoot + '/probe.mjs', `import fs from 'node:fs';import {execFileSync} from 'node:child_process';let b='';process.stdin.on('data',d=>{b+=d;let n;while((n=b.indexOf('\\n'))>=0){const m=JSON.parse(b.slice(0,n));b=b.slice(n+1);if(m.id===undefined)continue;let r;if(m.method==='server/discover')r={supportedVersions:['2026-07-28'],capabilities:{tools:{}}};else if(m.method==='tools/list')r={tools:[{name:'probe',description:'Synthetic sandbox boundary check',inputSchema:{type:'object'}}]};else{const p=process.argv[2];let read,child,network;try{fs.readFileSync(p);read='escaped';}catch(e){read=e.code;}try{execFileSync('/bin/cat',[p]);child='escaped';}catch(e){child='denied';}try{execFileSync('/usr/bin/curl',['--max-time','2','http://127.0.0.1:18089/healthz']);network='escaped';}catch(e){network='denied';}r={content:[{type:'text',text:JSON.stringify({read,child,network,credential:!!process.env.MAC_CHATGPT_APPROVAL_DIR})}]};}process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result:r})+'\\n');}});`);
const libraries = new Set(), queue = [process.execPath], checked = new Set();
while (queue.length) {
  const binary = queue.pop(); if (checked.has(binary)) continue; checked.add(binary);
  const { stdout } = await promisify(execFile)('/usr/bin/otool', ['-L', binary]);
  for (const line of stdout.split('\n').slice(1)) { const item = line.trim().split(' (')[0]; if (!item.startsWith('/opt/homebrew/')) continue; const resolved = await fs.realpath(item); libraries.add(path.dirname(resolved)); queue.push(resolved); }
}
const children = new Set(), manager = providerManager(session, libraries, children);
try {
  const promise = manager.call('request_server', { package: name, version, args: [denied + '/sentinel'], reason: 'Synthetic kernel boundary check' });
  let file; for (let i = 0; i < 100; i++) { file = (await fs.readdir(session)).find(f => f.endsWith('.capability.json')); if (file) break; await new Promise(resolve => setTimeout(resolve, 30)); }
  const request = JSON.parse(await fs.readFile(session + '/' + file, 'utf8'));
  await fs.writeFile(session + '/' + request.id + '.decision.json', JSON.stringify({ id: request.id, capability: request.capability, approved: true }));
  const provider = JSON.parse((await promise).content[0].text); assert.equal(provider.protocol, '2026-07-28');
  const response = await manager.call('call_server_tool', { id: provider.id, tool: 'probe', arguments: {} });
  const result = JSON.parse(response.content[0].text);
  assert.ok(['EPERM', 'EACCES'].includes(result.read), JSON.stringify(result)); assert.equal(result.child, 'denied'); assert.equal(result.network, 'denied'); assert.equal(result.credential, false);
  await manager.call('stop_server', { id: provider.id }); assert.equal(children.size, 0);
  console.log('PASS: July provider enforced kernel denial, descendant denial, network denial, credential exclusion and process shutdown.');
} finally { manager.close(); for (const directory of [cache, session, allowed, denied]) await fs.rm(directory, { recursive: true, force: true }); }
