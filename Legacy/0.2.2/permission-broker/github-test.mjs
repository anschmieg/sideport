import assert from 'node:assert/strict';
import {githubPlan,simpleGitHub,pushPlan} from './github.mjs';
for(const args of [['auth','token'],['auth','status','--show-token'],['auth','status','-t'],['extension','exec','bad'],['alias','set','bad','!sh'],['pr','list','--hostname=evil.example'],['pr','view','--web'],['issue','edit','--editor'],['api','https://evil.example/user']])assert.throws(()=>githubPlan(args),undefined,args.join(' '));
for(const args of [['repo','delete','anschmieg/test','--yes'],['pr','merge','1'],['issue','delete','1'],['api','repos/a/b','--method','DELETE'],['api','repos/a/b','-XDELETE'],['api','graphql','-f','query=mutation { deleteRepository }']])assert.equal(githubPlan(args).approval,true,args.join(' '));
for(const args of [['auth','status'],['api','user'],['pr','list'],['issue','comment','1','--body','Hello'],['pr','create','--head','patch','--title','Fix','--body','Details']])assert.equal(githubPlan(args).approval,false,args.join(' '));
assert.throws(()=>githubPlan(['pr','create','--title','Missing explicit head']));
assert.deepEqual(simpleGitHub('gh issue comment 1 --body "literal words"'),['issue','comment','1','--body','literal words']);
for(const command of ['gh api user; echo bad','gh api "$(env)"','gh pr list | cat','gh api user > file','gh api `env`','gh api "$HOME"'])assert.throws(()=>simpleGitHub(command));
assert.equal(simpleGitHub('echo gh'),null);
console.log('PASS: credential-export, extension, host override and interactive launch blocks; mandatory destructive/unknown-write approval; literal-only shell forwarding; ordinary GitHub development commands.');

assert.equal(pushPlan(['git','push','origin','HEAD:refs/heads/patch']).approval,false);
for(const a of [['git','push','--force','origin','HEAD:refs/heads/patch'],['git','push','origin',':refs/heads/patch'],['git','push','origin','HEAD:refs/heads/main']])assert.equal(pushPlan(a).approval,true);
for(const a of [['git','push','origin'],['git','push','--mirror','origin','HEAD:refs/heads/patch'],['git','push','-c','core.hooksPath=evil','origin','HEAD:refs/heads/patch']])assert.throws(()=>pushPlan(a));
console.log('PASS: explicit GitHub branch pushes; force/delete/protected branches require approval; hooks/config/implicit refspec overrides blocked.');
