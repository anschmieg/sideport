// Host-side nono credential capture. Never used as an MCP tool or shell environment injector.
import fs from 'node:fs/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
const executable=await fs.realpath(process.argv[2]||'');
if(!/^\/(?:opt\/homebrew|usr\/local)\/(?:Cellar\/gh\/[^/]+\/bin|bin)\/gh$/.test(executable))throw Error('Untrusted GitHub CLI path');
const {stdout}=await promisify(execFile)(executable,['auth','token','--hostname','github.com'],{env:{HOME:process.env.HOME,PATH:'/usr/bin:/bin',GH_CONFIG_DIR:process.env.HOME+'/.config/gh'},timeout:10000,maxBuffer:16384});
const token=stdout.trim();if(!/^[A-Za-z0-9_]+$/.test(token)||token.length<20)throw Error('GitHub credential unavailable');
process.stdout.write('x-access-token:'+token);
