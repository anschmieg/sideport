import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
import http from 'node:http';
import {managedManager,SmitheryPeer} from './managed.mjs';
import {RemotePeer,remoteURL} from './remote.mjs';
import {root} from './policy.mjs';
const controllerFixture=await fs.mkdtemp(root+'/work/managed-secret-');
const project=await fs.mkdtemp('/private/tmp/sideport-agents-fixture-');
const session=await fs.mkdtemp(root+'/work/permission-sessions/managed-');
await fs.mkdir(project+'/.agents');await fs.writeFile(session+'/grants.json',JSON.stringify([{path:project,kind:'directory',access:'read_write'}]));
await fs.writeFile(controllerFixture+'/sentinel','fixture-controller-secret');
const source=`import fs from 'node:fs';let b='';process.stdin.on('data',d=>{b+=d;let n;while((n=b.indexOf('\\n'))>=0){const m=JSON.parse(b.slice(0,n));b=b.slice(n+1);if(m.id===undefined)continue;let result;if(m.method==='server/discover')result={supportedVersions:['2026-07-28']};else if(m.method==='tools/list')result={tools:['probe','hidden'].map(name=>({name,inputSchema:{type:'object'}}))};else{let status;try{fs.readFileSync(m.params.arguments.path);status='escaped';}catch{status='denied';}result={content:[{type:'text',text:JSON.stringify({status,configuredToken:process.env.TEST_TOKEN==='fixture-manager-secret',controllerEnv:!!process.env.MAC_CHATGPT_APPROVAL_DIR})}]};}process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,result})+'\\n');}});`;
let config={mcp:{servers:{local:{transport:'stdio',command:process.execPath,args:['-e',source],cwd:project,env:{TEST_TOKEN:'placeholder'},disabledTools:['hidden'],enabled:true},disabled:{transport:'stdio',enabled:false}}}};
await fs.writeFile(project+'/.agents/agents.json',JSON.stringify(config));await fs.writeFile(project+'/.agents/local.json',JSON.stringify({mcpServers:{local:{env:{TEST_TOKEN:'fixture-manager-secret'}}}}));
let approve=false;const seen=[],children=new Set();const manager=managedManager(session,async(kind,details)=>{seen.push({kind,details});return approve;},children,peer=>{children.add(peer.child);peer.child.on('close',()=>children.delete(peer.child));});
let server;
try{
 const names=await manager.list({manager:'agents',project});assert.equal(names.length,2);assert.ok(!JSON.stringify(names).includes('fixture-manager-secret'));
 assert.deepEqual(await manager.start({manager:'agents',project,name:'local',reason:'Test configured forwarding'}),{denied:true});assert.equal(children.size,0);
 await assert.rejects(manager.start({manager:'agents',project,name:'disabled',reason:'test'}),/disabled/);
 await assert.rejects(manager.list({manager:'agents',project:'/private/tmp'}),/Approve/);
 approve=true;const provider=await manager.start({manager:'agents',project,name:'local',reason:'Test configured forwarding'});
 assert.equal(provider.peer.protocol,'2026-07-28');assert.deepEqual(provider.tools.map(t=>t.name),['probe']);
 for(const location of[controllerFixture+'/sentinel',project+'/.agents/local.json']){
  const response=await provider.peer.request('tools/call',{name:'probe',arguments:{path:location}});const result=JSON.parse(response.content[0].text);assert.equal(result.status,'denied',location);assert.equal(result.configuredToken,true);assert.equal(result.controllerEnv,false);
 }
 provider.peer.close();await new Promise(r=>setTimeout(r,100));assert.equal(children.size,0);
 console.log('PASS: agents discovery redacts credentials; denial/disabled/unapproved scopes; July stdio forwarding; configured tool filters; controller/config credential containment; shutdown.');
 let auth;
 server=http.createServer((req,res)=>{let body='';req.on('data',b=>body+=b);req.on('end',()=>{const m=JSON.parse(body);auth=req.headers.authorization;res.setHeader('Content-Type','application/json');res.end(JSON.stringify({jsonrpc:'2.0',id:m.id,result:m.method==='server/discover'?{supportedVersions:['2026-07-28']}:m.method==='tools/list'?{tools:[{name:'echo',inputSchema:{type:'object'}}]}:{content:[{type:'text',text:'forwarded'}]}}));});});await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const url='http://127.0.0.1:'+server.address().port+'/mcp';assert.throws(()=>remoteURL(url));
 config.mcp.servers.remote={transport:'http',url,headers:{Authorization:'Bearer fixture-service-secret'},enabled:true};await fs.writeFile(project+'/.agents/agents.json',JSON.stringify(config));
 const remote=await manager.start({manager:'agents',project,name:'remote',reason:'Test configured HTTP forwarding'});assert.equal(auth,'Bearer fixture-service-secret');assert.ok(!JSON.stringify(seen).includes('fixture-service-secret'));
 assert.equal((await remote.peer.request('tools/call',{name:'echo',arguments:{}})).content[0].text,'forwarded');remote.peer.close();
 const calls=[];const smithery=new SmitheryPeer(async args=>{calls.push(args);return args[1]==='list'?{tools:[{name:'echo',description:'fixture',inputSchema:{type:'object'}}]}:{content:[{type:'text',text:'smithery fixture'}]};},'existing-connection','existing-namespace');await smithery.connect();assert.equal((await smithery.request('tools/call',{name:'echo',arguments:{value:1}})).content[0].text,'smithery fixture');assert.ok(calls.every(a=>a.includes('existing-namespace')));
 await assert.rejects(smithery.request('tools/call',{name:'--remove',arguments:{}}),/Unknown/);smithery.close();await assert.rejects(smithery.request('tools/list'),/stopped/);
 console.log('PASS: configured loopback HTTP and credential forwarding; unconfigured public path still rejects private endpoints; Smithery schema/call forwarding, pinned namespace, unknown-tool rejection and stop.');
}finally{manager.close();if(server)await new Promise(r=>server.close(r));for(const p of[project,session,controllerFixture])await fs.rm(p,{recursive:true,force:true});}
