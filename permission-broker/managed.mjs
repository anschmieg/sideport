// Manager credentials stay in the local controller, never in discovery results.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn} from 'node:child_process';
import {root, home, workspace, canonical, grants, permitted} from './policy.mjs';
import {StdioPeer} from './rpc.mjs';
import {RemotePeer, remoteURL} from './remote.mjs';
import {buildRuntime} from './build-runtime.mjs';
const identifier = value => { if(typeof value!=='string'||!value.length||value.length>200||value.startsWith('-')||!/^[\w./:@-]+$/.test(value))throw new Error('Invalid managed server identifier');return value; };
const plain = value => value && typeof value==='object' && !Array.isArray(value);
function merge(a,b){const result={...a};for(const [k,v]of Object.entries(b||{})){if(['__proto__','constructor','prototype'].includes(k))throw new Error('Invalid configuration key');result[k]=plain(v)&&plain(result[k])?merge(result[k],v):v;}return result;}
async function readJSON(file,optional=false){try{const bytes=await fs.readFile(file);if(bytes.length>2*1024*1024)throw new Error('Manager config is too large');return JSON.parse(bytes);}catch(e){if(optional&&e.code==='ENOENT')return {};throw new Error('Manager configuration is missing or invalid');}}
function expand(value,project,environment){if(typeof value!=='string'||value.length>16384||/[\x00\r\n]/.test(value))throw new Error('Invalid configured value');return value.replace(/\$\{([^}]+)\}/g,(_all,key)=>{if(key==='PROJECT_ROOT')return project;const [name,fallback]=key.split(':-');const result=environment[name]??fallback;if(result===undefined)throw new Error('A configured environment variable is missing');return result;});}
function schemas(tools){if(!Array.isArray(tools)||tools.length>1000)throw new Error('Invalid managed tool listing');const seen=new Set();return tools.map(t=>{identifier(t.name);if(seen.has(t.name)||!plain(t.inputSchema)||t.inputSchema.type!=='object')throw new Error('Invalid managed tool schema');seen.add(t.name);return {name:t.name,description:typeof t.description==='string'?t.description.slice(0,10000):'',inputSchema:t.inputSchema,...t.outputSchema?{outputSchema:t.outputSchema}:{},annotations:t.annotations||{destructiveHint:true,openWorldHint:true}};});}
export class SmitheryPeer {
 constructor(run,connection,namespace){this.run=run;this.connection=identifier(connection);this.namespace=identifier(namespace);this.protocol='smithery-cli';this.closed=false;}
 async connect(){this.tools=schemas((await this.run(['tool','list',this.connection,'--namespace',this.namespace,'--flat','--limit','1000'])).tools);}
 async request(method,params={}){
  if(this.closed)throw new Error('Managed provider is stopped');
  if(method==='tools/list')return {tools:this.tools};
  if(method!=='tools/call'||!this.tools.some(t=>t.name===params.name))throw new Error('Unknown managed tool');
  const value=await this.run(['tool','call',this.connection,identifier(params.name),JSON.stringify(params.arguments||{}),'--namespace',this.namespace]);
  const result=value?.result??value;
  return Array.isArray(result?.content)?result:{content:[{type:'text',text:JSON.stringify(result)}]};
 }
 close(){this.closed=true;}
}
export function managedManager(session,approve,children,track){
 let smitheryPath;
 const cliChildren=new Set();
 const peers=new Set();
 async function cliPath(){if(smitheryPath)return smitheryPath;for(const file of ['/opt/homebrew/bin/smithery','/usr/local/bin/smithery',home+'/.local/bin/smithery']){try{await fs.access(file);smitheryPath=await fs.realpath(file);return smitheryPath;}catch{}}throw new Error('Smithery CLI is not installed. Install and log in locally first.');}
 async function run(args,json=true,owned){
  const executable=await cliPath();
  return await new Promise((resolve,reject)=>{
   const child=spawn(process.execPath,[executable,...json?['--json']:[],...args],{env:{HOME:home,PATH:root+'/work/node/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'},detached:true,stdio:['ignore','pipe','pipe']});
   cliChildren.add(child);children.add(child);owned?.add(child);let stdout='',size=0;
   const kill=()=>{try{process.kill(-child.pid,'SIGKILL');}catch{}};
   const timer=setTimeout(kill,30000);
   child.stdout.on('data',b=>{size+=b.length;if(size>4*1024*1024)kill();else stdout+=b;});child.stderr.on('data',()=>{});
   child.on('error',()=>{clearTimeout(timer);children.delete(child);cliChildren.delete(child);owned?.delete(child);reject(new Error('Smithery CLI could not start'));});
   child.on('close',code=>{clearTimeout(timer);children.delete(child);cliChildren.delete(child);owned?.delete(child);if(code!==0)return reject(new Error('Smithery request failed. Check the connection and login locally; no authentication is started automatically.'));try{const result=json?JSON.parse(stdout):stdout.trim();if(result?.error||result?.connectionIssues?.length)throw new Error();resolve(result);}catch{reject(new Error('Smithery returned an invalid response or requires authentication'));}});
  });
 }
 async function namespace(value){return identifier(value||await run(['namespace','show'],false));}
 async function agents(project){
  const directory=project?await canonical(project,true):home;
  if(project&&!permitted(directory,'read',await grants(session)))throw new Error('Approve this project folder before reading its agents configuration');
  const config=await readJSON(directory+'/.agents/agents.json');
  const local=await readJSON(directory+'/.agents/local.json',true);
  const definitions=config.mcp?.servers;if(!plain(definitions))throw new Error('Unsupported agents-dev configuration');
  const profile=config.activeProfile?config.profiles?.[config.activeProfile]:undefined;
  if(config.activeProfile&&(!profile||!Array.isArray(profile.servers)))throw new Error('The active agents profile is missing or invalid');
  const selected=profile?new Set(profile.servers):undefined;
  const resolved=Object.fromEntries(Object.entries(definitions).map(([name,s])=>{const merged=merge(s,local.mcpServers?.[name]);if(selected&&!selected.has(name))merged.enabled=false;return [name,merged];}));
  return {directory,definitions:resolved,local};
 }
 async function list(args){
  if(args.manager==='agents'){
   const {definitions}=await agents(args.project);
   return Object.entries(definitions).map(([name,s])=>({name,manager:'agents',transport:s.transport||'stdio',enabled:s.enabled!==false}));
  }
  if(args.manager!=='smithery')throw new Error('Unknown manager');
  const ns=await namespace(args.namespace);const result=await run(['mcp','list','--namespace',ns,'--limit','1000']);
  const rows=Array.isArray(result)?result:result.connections??result.servers;
  if(!Array.isArray(rows))throw new Error('Unsupported Smithery connection listing');
  return {namespace:ns,servers:rows.map(s=>({name:s.connectionId??s.id??s.name,manager:'smithery',status:typeof s.status==='string'?s.status:s.status?.state??'unknown'}))};
 }
 async function start(args){
  identifier(args.name);
  let peer,details,build,file,allowedTools,disabledTools;
  try {
  if(args.manager==='smithery'){
   const ns=await namespace(args.namespace);
   details={manager:'Smithery',name:args.name,mode:'service',target:ns,credentials:'Existing Smithery login',scope:'The permissions of this existing Smithery connection. Sideport’s file sandbox does not restrict the remote service.'};
   if(!await approve('managed_server',details,args.reason))return {denied:true};
   const owned=new Set();
   // Commands are short-lived, but stopping this forwarding session also cancels a pending command.
   const boundRun=command=>run(command,true,owned);
   peer=new SmitheryPeer(boundRun,args.name,ns);const close=peer.close.bind(peer);peer.close=()=>{close();for(const c of owned){try{process.kill(-c.pid,'SIGKILL');}catch{}}peers.delete(peer);};
  }else if(args.manager==='agents'){
   const {directory,definitions,local}=await agents(args.project);const definition=definitions[args.name];
   if(!definition||definition.enabled===false)throw new Error('Managed server is missing or disabled');
   const s=merge(definition,local.mcpServers?.[args.name]);
   if(s.oauth||s.headersHelper||s.envFile||s.bearerTokenEnvVar)throw new Error('This server requires an authentication helper that this adapter does not support. Use an existing Smithery connection or static configured headers instead.');
   allowedTools=s.tools;disabledTools=s.disabledTools;
   if((allowedTools&&!Array.isArray(allowedTools))||(disabledTools&&!Array.isArray(disabledTools)))throw new Error('Invalid configured tool filter');
   const env={...process.env,...s.env};
   const envValues=Object.fromEntries(Object.entries(s.env||{}).map(([k,v])=>{if(!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)||/^(DYLD_|LD_|SIDEPORT_|MAC_CHATGPT_)/.test(k))throw new Error('Unsafe configured environment variable');return [k,expand(v,directory,env)];}));
   if(s.transport==='http'||s.transport==='streamable-http'||s.url){
    const url=remoteURL(expand(s.url,directory,env),true);
    const headers=Object.fromEntries(Object.entries(s.headers||{}).map(([k,v])=>{if(!/^[\w-]+$/.test(k)||/^(host|content-length|transfer-encoding|connection|proxy-authorization)$/i.test(k))throw new Error('Unsafe configured header');return [k,expand(v,directory,env)];}));
    details={manager:'agents-dev',name:args.name,mode:'service',target:url.origin,credentials:Object.keys(headers).length?'Configured service headers':'None',scope:'This existing service has its own permissions. Sideport’s local file sandbox does not restrict the service.'};
    if(!await approve('managed_server',details,args.reason))return {denied:true};
    peer=new RemotePeer(url.href,{managed:true,headers});
   }else if(s.transport==='stdio'||!s.transport){
    build=await buildRuntime();
    const command=expand(s.command,directory,env);let executable;
    for(const candidate of command.includes('/')?[path.resolve(directory,command)]:build.environment.PATH.split(':').map(p=>path.join(p,command))){try{executable=await fs.realpath(candidate);await fs.access(executable,fs.constants.X_OK);break;}catch{executable=undefined;}}
    if(!executable){build.close();throw new Error('Configured command is not installed');}
    const serverArgs=(s.args||[]).map(v=>expand(v,directory,env));if(serverArgs.length>128)throw new Error('Too many configured arguments');
    const cwd=s.cwd?await canonical(expand(s.cwd,directory,env),true):workspace;
    const approved=await grants(session);if(!permitted(cwd,'read',approved))throw new Error('Approve the configured working folder before starting this server');
    details={manager:'agents-dev',name:args.name,mode:'sandbox',target:path.basename(executable),credentials:Object.keys(envValues).join(', ')||'None',scope:'Approved file locations and standard development caches. Network access is enabled. The server can change approved files; its internal commands are not screened individually.'};
    if(!await approve('managed_server',details,args.reason)){build.close();return {denied:true};}
    const manifest={version:'0.1.0',filesystem:{deny:[root,home+'/.ssh',home+'/Library/Keychains',home+'/.aws'].map(path=>({path})),grants:[...['/bin','/usr/bin','/usr/lib','/usr/share','/System/Library','/System/Cryptexes',root+'/work/node'].map(path=>({path,type:'directory',access:'read'})),...build.grants,...approved.map(g=>({path:g.path,type:g.kind,access:g.access==='read_write'?'readwrite':'read'})),{path:executable,type:'file',access:'read'},...['/dev/null','/dev/urandom','/dev/random'].map(path=>({path,type:'file',access:'readwrite'}))]},network:{mode:'unrestricted',dns:true},process:{signal_mode:'allow_same_sandbox',process_info_mode:'isolated',ipc_mode:'shared_memory_only'},rollback:{enabled:false}};
    // The runtime is readable, but controller configuration, tokens and approval files stay inaccessible.
    manifest.filesystem.deny=[directory+'/.agents/local.json',root+'/work/mcpproxy-pilot',root+'/work/permission-sessions',root+'/work/approval-reviewer.key',root+'/work/tunnel-runtime.key',root+'/work/mcpproxy-runtime.key',root+'/work/sideport-signing',home+'/.ssh',home+'/Library/Keychains',home+'/.aws',home+'/.agents'].map(path=>({path}));
    const profile={meta:{name:'Sideport managed server'},groups:{exclude:['system_read_macos','system_write_macos','user_caches_macos','node_runtime','bun_runtime','git_config','go_runtime','go_runtime_macos','homebrew_macos','java_runtime','mise_manager','nix_runtime','python_runtime','rust_runtime','user_tools','claude_code_macos','codex_macos','vscode_macos']},filesystem:{allow:[],read:[],allow_file:[],read_file:[],deny:manifest.filesystem.deny.map(d=>d.path)},network:{block:false},security:{signal_mode:'allow_same_sandbox',process_info_mode:'isolated',ipc_mode:'shared_memory_only',capability_elevation:false}};
    for(const grant of manifest.filesystem.grants){if(/[\*?\[\]{}]/.test(grant.path))throw new Error('A sandbox path contains unsupported wildcard characters');const key=(grant.access==='readwrite'?'allow':'read')+(grant.type==='file'?'_file':'');profile.filesystem[key].push(grant.path);}
    file=session+'/'+crypto.randomUUID()+'.managed-sandbox.json';await fs.writeFile(file,JSON.stringify(profile),{mode:0o600});
    peer=new StdioPeer(root+'/work/nono-bin/nono',['run','--silent','--profile',file,'--no-rollback','--allow-cwd','--',executable,...serverArgs],{cwd,env:{...build.environment,...envValues,XDG_CONFIG_HOME:root+'/work/nono-config',XDG_STATE_HOME:root+'/work/nono-state',XDG_CACHE_HOME:root+'/work/nono-cache'}});track(peer);
   }else throw new Error('Only stdio and HTTP managed servers are supported');
  }else throw new Error('Unknown manager');
  try{
   peers.add(peer);await peer.connect();const listing=schemas((await peer.request('tools/list')).tools);
   const tools=listing.filter(t=>(!allowedTools||allowedTools.includes(t.name))&&(!disabledTools||!disabledTools.includes(t.name)));
   const close=peer.close.bind(peer);peer.close=()=>{close();peers.delete(peer);build?.close();if(file)fs.rm(file,{force:true}).catch(()=>{});};
   return {peer,tools,spec:args.manager+':'+args.name,details};
  }catch(error){peer.close();peers.delete(peer);build?.close();if(file)await fs.rm(file,{force:true});throw new Error('Managed server could not connect. Check its local configuration and authentication.');}
  } finally { if (!peer) { build?.close(); if(file) await fs.rm(file,{force:true}); } }
 }
 return {list,start,close(){for(const p of peers)p.close();for(const c of cliChildren){try{process.kill(-c.pid,'SIGKILL');}catch{}}}};
}
