import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {root,home} from './policy.mjs';
import {approvalQueue} from './approval.mjs';
const excluded=['system_read_macos','system_write_macos','user_caches_macos','node_runtime','bun_runtime','git_config','go_runtime','go_runtime_macos','homebrew_macos','java_runtime','mise_manager','nix_runtime','python_runtime','rust_runtime','user_tools','claude_code_macos','codex_macos','vscode_macos'];
const reads=new Set(['auth status','pr list','pr view','pr diff','pr checks','pr status','issue list','issue view','issue status','repo view','repo list','run list','run view','workflow list','workflow view','release list','release view','search repos','search issues','search prs','search commits','search code','status']);
const writes=new Set(['pr create','pr comment','pr edit','pr ready','issue create','issue comment','issue edit']);
export function githubPlan(args){
 if(!Array.isArray(args)||!args.length||args.length>128||args.some(a=>typeof a!=='string'||a.length>16000||/[\x00\r]/.test(a)))throw Error('Invalid GitHub arguments');
 if(args[0]==='git') return pushPlan(args);
 const pair=args.slice(0,2).join(' ');
 if(args[0].startsWith('-')||['auth token','auth login','auth logout','auth refresh','auth switch','auth setup-git'].includes(pair)||['alias','extension','config','copilot','codespace','ssh-key','gpg-key','secret','variable'].includes(args[0]))throw Error('This command is not exposed through authenticated GitHub access');
 for(const a of args)if(/^(?:--hostname|--host|--web|--editor|--verbose|--show-token|--browser|--git-protocol|--insecure-storage)(?:=|$)/.test(a)||a==='-w'||a==='-e'||a==='-t'&&pair==='auth status'||/^https?:\/\//i.test(a)&&args[0]==='api')throw Error('Host overrides, credential output, debug and interactive launch flags are blocked');
 if(args[0]==='api'){
  const ep=args.find((a,i)=>i>0&&!a.startsWith('-'));
  if(!ep||ep.includes('..')||/[\\\x00-\x20]/.test(ep)||ep.includes('://'))throw Error('Use a relative GitHub API endpoint');
  const field=args.some(a=>/^(?:-[fF]|--(?:raw-field|field|input))(?:=|$|.)/.test(a));
  let method=field?'POST':'GET';
  for(let i=1;i<args.length;i++){if(args[i]==='-X'||args[i]==='--method'){method=(args[i+1]||'').toUpperCase();i++;}else if(args[i].startsWith('--method='))method=args[i].slice(9).toUpperCase();else if(args[i].startsWith('-X'))method=args[i].slice(2).toUpperCase();}
  const mutations=!['GET','HEAD'].includes(method);
  return {approval:mutations||ep.replace(/^\//,'')==='graphql',graphql:ep.replace(/^\//,'')==='graphql',pair};
 }
 if(pair==='pr create'&&(!args.some(a=>a==='--head'||a.startsWith('--head='))||!args.some(a=>a==='--title'||a.startsWith('--title='))||!args.some(a=>a==='--body'||a.startsWith('--body=')||a==='--body-file'||a.startsWith('--body-file='))))throw Error('Use explicit --head, --title and --body/--body-file for pr create; Sideport will not push a branch or launch an editor implicitly');
 return {approval:!reads.has(pair)&&!reads.has(args[0])&&!writes.has(pair),graphql:args[0]!=='api',pair};
}
export function pushPlan(args){
 if(args[1]!=='push')throw Error('The git adapter supports explicit HTTPS pushes only');
 const flags=new Set(['--dry-run','--porcelain','--force','-f','--force-with-lease','--delete','-d']);
 const positional=[];let risky=false;
 for(const a of args.slice(2)){if(a.startsWith('-')){if(!flags.has(a))throw Error('Unsupported git push flag');if(['--force','-f','--force-with-lease','--delete','-d'].includes(a))risky=true;}else positional.push(a);}
 if(positional.length!==2||!/^[-A-Za-z0-9_.]+$/.test(positional[0])||positional[0].startsWith('-'))throw Error('Use git push REMOTE EXPLICIT_REFSPEC');
 const ref=positional[1];if((args.includes('--delete')||args.includes('-d'))&&!ref.startsWith(':'))throw Error('Deletion requires an explicit :refs/heads/branch refspec');if(!/^\+?(?:HEAD|[A-Za-z0-9_][A-Za-z0-9_./-]*)?:refs\/heads\/[A-Za-z0-9_][A-Za-z0-9_./-]*$/.test(ref)||ref.includes('..')||ref.includes('//')||ref.endsWith('/')||ref.endsWith('.lock'))throw Error('Push only an explicit source:refs/heads/branch refspec');
 if(ref.startsWith('+')||ref.startsWith(':')||/(?:^|:)refs\/heads\/(?:main|master|release|production)$/.test(ref))risky=true;
 return {approval:risky,graphql:false,pair:'git push',git:true,remote:positional[0],refspec:ref,flags:args.slice(2).filter(a=>a.startsWith('-'))};
}
export function simpleGitHub(command){
 if(!/^\s*(?:gh|\/opt\/homebrew\/bin\/gh|\/usr\/local\/bin\/gh)(?:\s|$)/.test(command))return null;
 const words=[];let word='',quote='',active=false;
 for(const c of command.trim()){
  if(quote){if(c===quote)quote='';else if(c==='\\'||c==='`'||c==='$')throw Error('Use run_github with an argument array for shell expansions');else word+=c;active=true;}
  else if(c==='"'||c==="'"){quote=c;active=true;}
  else if(/\s/.test(c)){if(active){words.push(word);word='';active=false;}}
  else if(/[;&|<>$`\\()\n]/.test(c))throw Error('Use run_github for authenticated commands; shell composition and expansions are not forwarded');
  else{word+=c;active=true;}
 }
 if(quote)throw Error('Unterminated GitHub argument quote');if(active)words.push(word);return words.slice(1);
}
export function githubManager(session,build,children,inspectRemote){
 const approve=approvalQueue(session);
 return async(args,cwd,approved)=>{
  const plan=githubPlan(args.args);
  if(plan.approval){
   if(!args.approval_reason)return {content:[{type:'text',text:JSON.stringify({status:'approval_required',hint:'Retry with approval_reason to ask the person at this Mac to approve this exact GitHub command once. Unknown writes and destructive operations always need a human decision.'})}],isError:true};
   if(!await approve('shell_command',{command:(plan.git?'':'gh ')+args.args.map(a=>JSON.stringify(a)).join(' '),cwd,risk:'This GitHub operation is outside the automatically allowed development actions. It may delete or change remote data.',rule:'github.remote_change'},args.approval_reason))return {content:[{type:'text',text:'GitHub operation denied'}],isError:true};
  }
  const timeout=args.timeout_seconds??30;if(!Number.isInteger(timeout)||timeout<1||timeout>300)throw Error('Timeout must be 1–300 seconds');
  let gh;for(const candidate of ['/opt/homebrew/bin/gh','/usr/local/bin/gh']){try{gh=await fs.realpath(candidate);break;}catch{}}
  if(!gh||!/^\/(?:opt\/homebrew|usr\/local)\/(?:Cellar\/gh\/[^/]+\/bin|bin)\/gh$/.test(gh))throw Error('Install GitHub CLI from Homebrew first');
  let executable=gh,executionArgs=args.args;
  let gitURL,gitInfo;
  if(plan.git){
   executable=build.environment.DEVELOPER_DIR+'/usr/bin/git';await fs.access(executable,fs.constants.X_OK);
   if(!inspectRemote)throw Error('Sandboxed Git remote inspection unavailable');
   gitInfo=await inspectRemote(executable,plan.remote,cwd,approved,plan.refspec);
   gitURL=gitInfo.url.trim();if(!/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?$/.test(gitURL)||gitURL.includes('..'))throw Error('Authenticated pushes require a configured HTTPS github.com remote without embedded credentials');
  }
  const scratch=await fs.mkdtemp(build.environment.TMPDIR+'/github-');const profileFile=session+'/'+crypto.randomUUID()+'.github-profile.json';
  try{
   const config=scratch+'/gh';await fs.mkdir(config,{mode:0o700});await fs.writeFile(config+'/hosts.yml','',{mode:0o600});
   const allow=[{method:'GET',path:'/**'},{method:'HEAD',path:'/**'}];
   if(plan.graphql)allow.push({method:'POST',path:'/graphql'});
   if(writes.has(plan.pair))for(const p of ['/repos/*/*/issues','/repos/*/*/issues/*','/repos/*/*/issues/*/comments','/repos/*/*/pulls','/repos/*/*/pulls/*','/repos/*/*/pulls/*/comments'])for(const method of ['POST','PATCH'])allow.push({method,path:p});
   if(plan.approval)allow.push({method:'*',path:'/**'});
   const profile={meta:{name:'Sideport authenticated GitHub'},groups:{exclude:excluded},filesystem:{read:[],read_file:['/dev/urandom','/dev/random'],allow_file:['/dev/null'],allow:[scratch],deny:[root+'/work/permission-sessions',root+'/work/mcpproxy-pilot',root+'/work/sideport-signing',root+'/work/approval-reviewer.key',root+'/work/tunnel-runtime.key',root+'/work/mcpproxy-runtime.key',home+'/.config/gh',home+'/Library/Keychains',home+'/.ssh',home+'/.aws']},network:{tls_intercept:{ca_lifecycle:'trusted',ca_validity:'24h',leaf_validity:'15m'},credentials:['github'],custom_credentials:{github:{upstream:'https://api.github.com',credential_key:'cmd://github',env_var:'GH_TOKEN',credential_format:'Bearer {}',endpoint_policy:{default:{decision:'deny'},allow}}}},credential_capture:{github:{command:[gh,'auth','token','--hostname','github.com'],timeout_secs:10,cache_ttl_secs:0}},environment:{allow_vars:['HOME','PATH','LANG','GH_TOKEN','HTTP_PROXY','HTTPS_PROXY','NO_PROXY','http_proxy','https_proxy','no_proxy','NONO_PROXY_TOKEN','SSL_CERT_FILE','NODE_EXTRA_CA_CERTS'],set_vars:{GH_CONFIG_DIR:config,GH_HOST:'github.com',GH_PROMPT_DISABLED:'1',GH_NO_UPDATE_NOTIFIER:'1',GH_PAGER:'cat',GIT_CONFIG_GLOBAL:'/dev/null',GIT_CONFIG_NOSYSTEM:'1'}},security:{signal_mode:'allow_same_sandbox',process_info_mode:'isolated',ipc_mode:'shared_memory_only',capability_elevation:false}};
   for(const entry of [...build.grants,...approved.map(g=>({path:g.path,type:g.kind}))]){if(/[?*\[\]{}]/.test(entry.path))throw Error('GitHub sandbox paths cannot contain profile glob characters');profile.filesystem[entry.type==='file'?'read_file':'read'].push(entry.path);}
   profile.filesystem.read.push('/bin','/usr/bin','/usr/lib','/usr/share','/System/Library','/System/Cryptexes',path.dirname(gh));
   if(plan.git){
    profile.network.credentials=['github_git'];
    profile.network.custom_credentials={github_git:{upstream:'https://github.com',credential_key:'cmd://github',env_var:'SIDEPORT_GIT_TOKEN',inject_header:'Authorization',credential_format:'Basic {}',inject_mode:'basic_auth',endpoint_policy:{default:{decision:'deny'},allow:[{method:'GET',path:new URL(gitURL).pathname.replace(/\.git$/,'')+'.git/info/refs'},{method:'POST',path:new URL(gitURL).pathname.replace(/\.git$/,'')+'.git/git-receive-pack'}]}}};
    profile.credential_capture.github.command=[process.execPath,path.join(path.dirname(fileURLToPath(import.meta.url)),'github-credential.mjs'),gh];
    profile.environment.allow_vars.push('SIDEPORT_GIT_TOKEN');
    const helper='!f() { printf \"username=x-access-token\\npassword=%s\\n\" \"$SIDEPORT_GIT_TOKEN\"; }; f';
    const bare=scratch+'/push.git';await fs.mkdir(bare+'/refs/heads',{recursive:true,mode:0o700});await fs.mkdir(bare+'/objects/info',{recursive:true,mode:0o700});
    await fs.writeFile(bare+'/config','[core]\n repositoryformatversion = 0\n bare = true\n',{mode:0o600});await fs.writeFile(bare+'/HEAD','ref: refs/heads/sideport-push\n',{mode:0o600});
    let refspec=plan.refspec;
    if(!refspec.startsWith(':')){
     if(!/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(gitInfo.commit)||typeof gitInfo.objects!=='string'||!gitInfo.objects.startsWith('/')||/[\r\n]/.test(gitInfo.objects))throw Error('Invalid sandboxed Git object lookup');
     await fs.writeFile(bare+'/objects/info/alternates',gitInfo.objects+'\n',{mode:0o600});await fs.writeFile(bare+'/refs/heads/sideport-push',gitInfo.commit+'\n',{mode:0o600});
     refspec=(refspec.startsWith('+')?'+':'')+'refs/heads/sideport-push:'+refspec.split(':')[1];
    }
    executionArgs=['--git-dir='+bare,'-c','core.hooksPath=/dev/null','-c','credential.helper=','-c','credential.https://github.com.helper='+helper,'-c','protocol.allow=never','-c','protocol.https.allow=always','push',...plan.flags.filter(f=>!['--delete','-d'].includes(f)),gitURL,refspec];
   }
   await fs.writeFile(profileFile,JSON.stringify(profile),{mode:0o600,flag:'wx'});
   return await new Promise((resolve,reject)=>{
    const child=spawn(root+'/work/nono-bin/nono',['run','--silent','--profile',profileFile,'--no-rollback','--',executable,...executionArgs],{cwd,detached:true,env:{HOME:home,PATH:'/opt/homebrew/bin:/usr/bin:/bin',GH_CONFIG_DIR:home+'/.config/gh',XDG_CONFIG_HOME:root+'/work/nono-config',XDG_STATE_HOME:root+'/work/nono-state',XDG_CACHE_HOME:root+'/work/nono-cache'},stdio:['ignore','pipe','pipe']});children.add(child);
    let stdout='',stderr='',size=0;const kill=()=>{try{process.kill(-child.pid,'SIGKILL');}catch{}};const timer=setTimeout(kill,timeout*1000);
    for(const [stream,error] of [[child.stdout,false],[child.stderr,true]])stream.on('data',b=>{size+=b.length;if(size>1048576)kill();else if(error)stderr+=b;else stdout+=b;});
    child.on('error',e=>{clearTimeout(timer);children.delete(child);reject(Error('GitHub process could not start: '+e.code));});
    child.on('close',code=>{clearTimeout(timer);kill();children.delete(child);const redact=s=>s.replace(/(?:gh[opusr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)/g,'[credential redacted]');resolve({content:[{type:'text',text:JSON.stringify({exit_code:code,stdout:redact(stdout),stderr:redact(stderr)})}],isError:code!==0});});
   });
  }finally{await fs.rm(profileFile,{force:true});await fs.rm(scratch,{recursive:true,force:true});}
 };
}
