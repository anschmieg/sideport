import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import tls from 'node:tls';
import { spawn } from 'node:child_process';
import { root, home, workspace, grants } from './policy.mjs';
import { approvalQueue } from './approval.mjs';
import { StdioPeer } from './rpc.mjs';
import { RemotePeer, remoteURL } from './remote.mjs';
import { managedManager } from './managed.mjs';
import { npmSpec, validateArgs, validateBin, selectorDrag } from './provider-policy.mjs';
const text = value => ({ content: [{ type: 'text', text: JSON.stringify(value) }] });
export function providerManager(session, libraries, children) {
  const approve = approvalQueue(session);
  const providers = new Map();
  let installing = false;
  let admitting = false;
  function track(peer) {
    children.add(peer.child);
    peer.child.once('close', () => children.delete(peer.child));
  }

  const managed = managedManager(session, approve, children, track);
  const runtime = ['/bin', '/usr/bin', '/usr/lib', '/usr/share', '/System/Library', '/System/Cryptexes', root + '/work/node', ...libraries];
  function manifest(approved, extra, network = 'blocked') {
    return { version: '0.1.0', filesystem: { grants: [
      ...runtime.map(path => ({ path, type: 'directory', access: 'read' })),
      ...['/dev/null', '/dev/random', '/dev/urandom'].map(path => ({ path, type: 'file', access: 'readwrite' })),
      ...approved.map(g => ({ path: g.path, type: g.kind, access: g.access === 'read_write' ? 'readwrite' : 'read' })), ...extra
    ] }, network: { mode: network, dns: network !== 'blocked' }, process: { signal_mode: 'allow_same_sandbox', process_info_mode: 'isolated', ipc_mode: 'shared_memory_only' }, rollback: { enabled: false } };
  }
  function env(scratch) {
    return { PATH: root + '/work/node/bin:/opt/homebrew/bin:/usr/bin:/bin', HOME: home, TMPDIR: scratch, OPENSSL_CONF: '/dev/null',
      XDG_CONFIG_HOME: root + '/work/nono-config', XDG_STATE_HOME: root + '/work/nono-state', XDG_CACHE_HOME: root + '/work/nono-cache',
      npm_config_cache: scratch + '/npm-cache', npm_config_userconfig: scratch + '/user.npmrc', npm_config_globalconfig: scratch + '/global.npmrc' };
  }
  async function manifestFile(value) {
    const file = session + '/' + crypto.randomUUID() + '.provider-sandbox.json';
    await fs.writeFile(file, JSON.stringify(value), { mode: 0o600, flag: 'wx' }); return file;
  }
  async function install(cache, scratch, spec) {
    await fs.writeFile(scratch + '/trust.pem', [...new Set([...tls.getCACertificates('bundled'), ...tls.getCACertificates('system')])].join('\n'), { mode: 0o600 });
    const npm = await fs.realpath(root + '/work/node/lib/node_modules/npm/bin/npm-cli.js');
    const dnsFiles = ['/etc/hosts', '/etc/resolv.conf', '/var/run/resolv.conf', '/etc/services'].map(path => ({ path, type: 'file', access: 'read' }));
    const file = await manifestFile(manifest([], [...dnsFiles, { path: path.dirname(path.dirname(npm)), type: 'directory', access: 'read' }, { path: cache, type: 'directory', access: 'readwrite' }, { path: scratch, type: 'directory', access: 'readwrite' }], 'unrestricted'));
    async function run(args) {
      return await new Promise((resolve, reject) => {
        const child = spawn(root + '/work/nono-bin/nono', ['run', '--silent', '--config', file, '--', process.execPath, npm, ...args], { cwd: cache, env: { ...env(scratch), NODE_EXTRA_CA_CERTS: scratch + '/trust.pem' }, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
        children.add(child); let output = '', stderr = '', size = 0;
        const kill = () => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} };
        const timer = setTimeout(kill, 120000);
        child.stdout.on('data', bytes => { size += bytes.length; if (size > 4 * 1024 * 1024) kill(); else output += bytes; });
        child.stderr.on('data', bytes => { size += bytes.length; if (size > 4 * 1024 * 1024) kill(); else stderr += bytes; });
        child.on('error', error => { clearTimeout(timer); children.delete(child); reject(error); });
        child.on('close', code => { clearTimeout(timer); kill(); children.delete(child); resolve({ code, output, stderr }); });
      });
    }
    try {
      const installed = await run(['install', '--ignore-scripts', '--no-fund', '--no-audit', '--save-exact', '--registry=https://registry.npmjs.org', spec]);
      if (installed.code !== 0) throw new Error('Package download failed within the installer sandbox: ' + installed.stderr.slice(-2000));
      const audit = await run(['audit', '--json', '--audit-level=high', '--registry=https://registry.npmjs.org']);
      const report = JSON.parse(audit.output);
      if (report.error || audit.code !== 0 || !report.metadata || report.metadata.vulnerabilities.high || report.metadata.vulnerabilities.critical) throw new Error('Package audit failed or found high/critical advisories; provider was not started');
      await fs.writeFile(cache + '/approved-install.json', JSON.stringify({ spec, audited: new Date().toISOString() }), { mode: 0o600 });
    } finally { await fs.rm(file, { force: true }); }
  }
  async function startNpm(args) {
    if (installing) throw new Error('Another provider is starting');
    const spec = npmSpec(args.package, args.version); validateArgs(args.args);
    if (providers.size >= 5) throw new Error('Five-provider limit reached; stop one before adding another');
    const approved = await grants(session);
    const cacheKey = crypto.createHash('sha256').update(spec).digest('hex');
    const cached = await fs.access(root + '/work/provider-cache/' + cacheKey + '/approved-install.json').then(() => true, () => false);
    const details = { package: args.package, version: args.version, args: args.args, locations: approved, cached, network: 'blocked' };
    if (!(await approve('npm_server', details, args.reason))) return text({ status: 'denied' });
    installing = true;
    const id = crypto.randomUUID();
    const cache = root + '/work/provider-cache/' + crypto.createHash('sha256').update(spec).digest('hex');
    const scratch = await fs.mkdtemp(session + '/provider-');
    let peer, file;
    try {
      await fs.mkdir(cache, { recursive: true, mode: 0o700 });
      try {
        const previous = JSON.parse(await fs.readFile(cache + '/approved-install.json', 'utf8'));
        if (previous.spec !== spec) throw new Error('Cached version mismatch');
      } catch (error) { if (error.code !== 'ENOENT') throw error; await install(cache, scratch, spec); }
      const packageRoot = cache + '/node_modules/' + args.package;
      const metadata = JSON.parse(await fs.readFile(packageRoot + '/package.json', 'utf8'));
      if (metadata.name !== args.package || metadata.version !== args.version) throw new Error('Downloaded package identity mismatch');
      const entries = typeof metadata.bin === 'string' ? [[args.package.split('/').at(-1), metadata.bin]] : Object.entries(metadata.bin || {});
      if (entries.length !== 1) throw new Error('Only packages with one unambiguous executable are supported');
      const executable = validateBin(packageRoot, entries[0][1]);
      const actual = await fs.realpath(executable);
      if (!actual.startsWith(cache + '/')) throw new Error('Executable points outside the package cache');
      if (!/\.(?:[cm]?js)$/.test(actual) && !(await fs.readFile(actual, 'utf8')).startsWith('#!/usr/bin/env node')) throw new Error('Only Node.js MCP packages are supported');
      file = await manifestFile(manifest(approved, [{ path: cache, type: 'directory', access: 'read' }, { path: scratch, type: 'directory', access: 'readwrite' }]));
      peer = new StdioPeer(root + '/work/nono-bin/nono', ['run', '--silent', '--config', file, '--', process.execPath, actual, ...args.args], { env: env(scratch), cwd: workspace });
      track(peer); await peer.connect();
      const listing = await peer.request('tools/list');
      providers.set(id, { peer, file, scratch, spec, tools: listing.tools || [], scopes: approved });
      return text({ status: 'running', id, package: spec, protocol: peer.protocol, tools: listing.tools || [], hint: 'Use call_server_tool with this id. Newly granted file scope requires stopping and requesting the provider again.' });
    } catch (error) {
      peer?.close(); if (peer) children.delete(peer.child);
      if (file) await fs.rm(file, { force: true }); await fs.rm(scratch, { recursive: true, force: true }); throw error;
    } finally { installing = false; }
  }
  async function startRemote(args) {
    const url = remoteURL(args.url).href;
    if (providers.size >= 5) throw new Error('Five-provider limit reached');
    if (!(await approve('remote_server', { endpoint: url, host: new URL(url).host }, args.reason))) return text({ status: 'denied' });
    const peer = new RemotePeer(url);
    try {
      await peer.connect(); const listing = await peer.request('tools/list');
      const id = crypto.randomUUID(); providers.set(id, { peer, spec: url, tools: listing.tools || [] });
      return text({ status: 'running', id, endpoint: url, protocol: peer.protocol, tools: listing.tools || [] });
    } catch (error) { peer.close(); throw error; }
  }
  let computer;
  let computerTools = [];
  const excludedComputerTools = new Set(['agent', 'action', 'browser', 'analyze']);
  function screenTools(listing) {
    return (listing.tools || []).filter(tool => !excludedComputerTools.has(tool.name)).map(tool => {
      if (tool.name !== 'drag') return tool;
      const copy = structuredClone(tool);
      delete copy.inputSchema.properties.from_coords; delete copy.inputSchema.properties.to_coords;
      copy.inputSchema.required = [...new Set([...(copy.inputSchema.required || []), 'from', 'to'])];
      copy.description = 'Drag from one UI element selector to another. Coordinates are forbidden. Use fresh see or inspect_ui selectors and an exact-window snapshot.';
      return copy;
    });
  }
  async function computerControl(reason) {
    if (computer && !computer.closed) return text({ status: 'already_allowed', tools: computerTools, guidance: 'Use screen control for graphical tasks. Run commands through run_shell. Do not use a terminal app to bypass file or network restrictions; report the restriction to the user instead.' });
    if (!(await approve('computer_control', { tool: 'Peekaboo', version: JSON.parse(await fs.readFile(root + '/work/baseline/node_modules/@steipete/peekaboo/package.json', 'utf8')).version }, reason))) return text({ status: 'denied' });
    computer = new StdioPeer(root + '/work/baseline/node_modules/@steipete/peekaboo/peekaboo', ['mcp', 'serve', '--no-remote', '--allow-foreground', '--allow-temporary-clipboard'], { env: { PATH: '/usr/bin:/bin', HOME: home }, cwd: workspace });
    track(computer);
    try { await computer.connect(); computerTools = screenTools(await computer.request('tools/list')); return text({ status: 'approved', tools: computerTools, guidance: 'Use screen control for graphical tasks. Run commands through run_shell. Do not use a terminal app to bypass file or network restrictions; report the restriction to the user instead.' }); }
    catch (error) { computer.close(); children.delete(computer.child); throw error; }
  }
  async function stop(id) {
    const provider = providers.get(id);
    if (!provider) throw new Error('Unknown provider');
    providers.delete(id); provider.peer.close(); if (provider.peer.child) children.delete(provider.peer.child);
    if (provider.file) await fs.rm(provider.file, { force: true }); if (provider.scratch) await fs.rm(provider.scratch, { recursive: true, force: true });
    return text({ status: 'stopped' });
  }
  return {
    async call(name, args) {
      if (name === 'managed_servers') return text(await managed.list(args));
      if (name === 'request_managed_server') {
        if (admitting) throw new Error('Another server request is in progress');
        if (providers.size >= 5) throw new Error('Five-provider limit reached');
        admitting = true;
        try {
          const result = await managed.start(args);
          if (result.denied) return text({ status: 'denied' });
          const id = crypto.randomUUID(); providers.set(id, result);
          return text({ status: 'running', id, manager: args.manager, server: args.name, protocol: result.peer.protocol, tools: result.tools });
        } finally { admitting = false; }
      }
      if (name === 'request_remote_server' || name === 'request_server') {
        if (admitting) throw new Error('Another server request is in progress');
        admitting = true;
        try { return await (name === 'request_server' ? startNpm(args) : startRemote(args)); }
        finally { admitting = false; }
      }
      if (name === 'request_computer_control') return await computerControl(args.reason);
      if (name === 'computer_action') {
        if (!computer || computer.closed) return { ...text({ status: 'access_denied', hint: 'Use request_computer_control if appropriate.' }), isError: true };
        if (typeof args.tool !== 'string' || !computerTools.some(tool => tool.name === args.tool)) throw new Error('Unknown or unsupported computer tool');
        selectorDrag(args.tool, args.arguments);
        return await computer.request('tools/call', { name: args.tool, arguments: args.arguments });
      }
      if (name === 'active_servers') return text([...providers].map(([id, p]) => ({ id, package: p.spec, protocol: p.peer.protocol, tools: p.tools })));
      if (name === 'stop_server') return await stop(args.id);
      if (name === 'call_server_tool') {
        const provider = providers.get(args.id);
        if (!provider || provider.peer.closed) throw new Error('Server is not running');
        if (!provider.tools.some(tool => tool.name === args.tool)) throw new Error('Unknown provider tool');
        return await provider.peer.request('tools/call', { name: args.tool, arguments: args.arguments });
      }
      throw new Error('Unknown extension tool');
    },
    close() { managed.close(); computer?.close(); for (const p of providers.values()) p.peer.close(); }
  };
}
