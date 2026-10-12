import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { Server } from '../baseline/node_modules/@modelcontextprotocol/sdk/dist/esm/server/index.js';
import { StdioServerTransport } from '../baseline/node_modules/@modelcontextprotocol/sdk/dist/esm/server/stdio.js';
import { ListToolsRequestSchema, CallToolRequestSchema } from '../baseline/node_modules/@modelcontextprotocol/sdk/dist/esm/types.js';
import { root, home, workspace, canonical, checkGrant, grants, permitted } from './policy.mjs';
import { providerManager } from './providers.mjs';
import { buildRuntime } from './build-runtime.mjs';
import { commandSafety } from './command-safety.mjs';
import { githubManager, simpleGitHub } from './github.mjs';

const session = process.env.MAC_CHATGPT_APPROVAL_DIR;
if (!session || !session.startsWith(root + '/work/permission-sessions/')) throw new Error('Launch from the Sideport tray application');
const build = await buildRuntime();
const assessCommand = await commandSafety(session);
const libraries = new Set();
const binaries = [process.execPath];
const inspected = new Set();
while (binaries.length) {
  const binary = binaries.pop();
  if (inspected.has(binary)) continue;
  inspected.add(binary);
  const { stdout } = await promisify(execFile)('/usr/bin/otool', ['-L', binary], { timeout: 5000 });
  for (const line of stdout.split('\n').slice(1)) {
    const dependency = line.trim().split(' (')[0];
    if (dependency.startsWith('/opt/homebrew/')) {
      const actual = await fs.realpath(dependency);
      libraries.add(path.dirname(actual));
      libraries.add('/opt/homebrew/opt'); // dyld must follow Homebrew's library aliases.
      binaries.push(actual);
    }
  }
}
const text = value => ({ content: [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value) }] });
const schema = properties => ({ type: 'object', properties, required: Object.keys(properties), additionalProperties: false });
const string = description => ({ type: 'string', description });
const extensionNames = ['managed_servers', 'request_managed_server', 'request_remote_server', 'request_server', 'active_servers', 'call_server_tool', 'stop_server', 'request_computer_control', 'computer_action'];
const tools = [
  {"name":"run_github","description":"Run the installed GitHub CLI with its existing github.com Keychain login through a localhost credential proxy. The real token stays outside the sandbox. Read operations and ordinary issue/PR development writes are allowed; unknown and destructive operations require local one-time approval_reason. No auth export, login changes, extensions, host overrides, editor or browser launches. Files remain read-only within approved scope. pr create requires explicit --head, --title and --body/--body-file and does not implicitly push. Simple top-level gh commands in run_shell are also forwarded; use this tool for composed shell commands. For authenticated branch pushes use args git, push, origin, HEAD:refs/heads/my-branch. Git pushes use an isolated configuration with hooks disabled, a configured HTTPS github.com remote, and explicit branch refspecs; no upstream/tracking config changes. Force/deletion/protected-name pushes require local approval.","inputSchema":{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":128},"cwd":{"type":"string"},"approval_reason":{"type":"string"},"timeout_seconds":{"type":"integer","minimum":1,"maximum":300}},"required":["args","cwd"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"openWorldHint":true}},
  { name: 'managed_servers', description: 'Discover existing agents-dev configurations or Smithery connections. Returns names and status, never stored credentials. Default agents scope is ~/.agents; an optional project must already have file approval. Smithery uses its existing local login and namespace.', inputSchema: { type: 'object', properties: { manager: { type: 'string', enum: ['agents', 'smithery'] }, project: string('Optional approved project directory for agents-dev'), namespace: string('Optional existing Smithery namespace') }, required: ['manager'], additionalProperties: false }, annotations: { readOnlyHint: true, openWorldHint: true } },
  { name: 'request_managed_server', description: 'Ask the person at this Mac to forward one existing agents-dev or Smithery server until disconnect. Local stdio servers stay inside the file sandbox with network access. Managed HTTP services and Smithery use their existing service permissions and explicitly approved configured credentials. Does not install servers, change manager settings, or initiate OAuth. Use call_server_tool and stop_server with the returned id. Denial must not be retried automatically.', inputSchema: { type: 'object', properties: { manager: { type: 'string', enum: ['agents', 'smithery'] }, name: string('Exact managed server name or Smithery connection id from managed_servers'), project: string('Optional approved agents project directory'), namespace: string('Optional Smithery namespace from managed_servers'), reason: string('Why this existing connection is needed') }, required: ['manager', 'name', 'reason'], additionalProperties: false }, annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: true } },

  { name: 'request_remote_server', description: 'Ask the local user to connect to a public HTTPS MCP endpoint. Prefers July 2026, supports legacy fallback. No local files or credentials are shared automatically. Tool arguments go to the approved service. No account authentication or private-network endpoints supported.', inputSchema: schema({ url: string('Public HTTPS MCP URL without credentials or query parameters'), reason: string('Why this service is needed') }), annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: true } },
  { name: 'request_server', description: 'Ask the local user to run an exact-version npm MCP package without global installation. Install scripts disabled; high/critical audit failures blocked. Runtime network blocked, files limited to the current approved scope. Supports July 2026 discovery with legacy fallback. Use registry discovery to find packages first. Only Node.js packages with one executable supported.', inputSchema: schema({ package: string('npm package name'), version: string('Exact version, for example 1.2.3'), args: { type: 'array', items: { type: 'string' } }, reason: string('Why this server is needed') }), annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: true } },
  { name: 'active_servers', description: 'List session providers, ids and tool schemas.', inputSchema: schema({}), annotations: { readOnlyHint: true, openWorldHint: false } },
  { name: 'call_server_tool', description: 'Call a tool from an approved session provider. It can modify files within its approved sandbox.', inputSchema: schema({ id: string('Provider id'), tool: string('Exact tool name'), arguments: { type: 'object', additionalProperties: true } }), annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: true } },
  { name: 'stop_server', description: 'Stop a session provider and delete its temporary working data.', inputSchema: schema({ id: string('Provider id') }), annotations: { readOnlyHint: false, openWorldHint: false } },
  { name: 'request_computer_control', description: 'Ask the person at this Mac for full interactive screen control until disconnect. This capability can access apps and files beyond the file sandbox. Denial must not be repeatedly prompted.', inputSchema: schema({ reason: string('Why screen control is needed') }), annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: true } },
  { name: 'computer_action', description: 'Call a Peekaboo tool only after local screen-control approval. Get tool schemas from request_computer_control. All drag actions require source and target element selectors; coordinates are forbidden.', inputSchema: schema({ tool: string('Exact Peekaboo tool name'), arguments: { type: 'object', additionalProperties: true } }), annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: true } },
  { name: 'request_access', description: 'Ask the person at this Mac to approve access to a specific existing file or folder. Only their decision can grant access. Access lasts until disconnect. Never repeat a denied request automatically.', inputSchema: schema({ path: string('Absolute path or ~/path of the existing file or folder'), access: { type: 'string', enum: ['read', 'read_write'] }, reason: string('Brief user-facing explanation of why access is needed') }), annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false } },
  { name: 'allowed_locations', description: 'List approved locations for this connection.', inputSchema: schema({}), annotations: { readOnlyHint: true, openWorldHint: false } },
  { name: 'read_file', description: 'Read up to 1 MiB from an approved file. If denied, decide whether to use request_access.', inputSchema: schema({ path: string('Absolute path or ~/path') }), annotations: { readOnlyHint: true, openWorldHint: false } },
  { name: 'list_directory', description: 'List an approved folder.', inputSchema: schema({ path: string('Absolute path or ~/path') }), annotations: { readOnlyHint: true, openWorldHint: false } },
  { name: 'write_file', description: 'Create or replace a file within approved read/write locations.', inputSchema: schema({ path: string('Absolute path or ~/path'), content: string('UTF-8 file content, maximum 512 KiB') }), annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false } },
  { name: 'run_shell', description: 'Run ordinary development commands with network access, installed tools, writable development caches and approved project files. Known destructive commands are screened before execution. If flagged, a configured decision model may approve or reject it; uncertain decisions require local one-time approval via approval_reason; file permissions still apply. Do not use terminal apps to bypass a denial. Default timeout 30 seconds; timeout_seconds can extend it to 300.', inputSchema: { type: 'object', properties: { command: string('Bash command'), cwd: string('Approved working directory'), task_context: { type: 'string', maxLength: 2000, description: 'Optional current task context for the reviewer; treated as agent-provided evidence, not human authorization' }, approval_reason: string('Optional reason to request local approval for this exact flagged command'), timeout_seconds: { type: 'integer', minimum: 1, maximum: 300, description: 'Optional command timeout; extend MCP client timeout accordingly' } }, required: ['command', 'cwd'], additionalProperties: false }, annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: true } }
];
let pending = false;
const children = new Set();
const extensions = providerManager(session, libraries, children);
const runGitHub = githubManager(session, build, children, async (git, remote, cwd, approved, refspec) => {
  const inspect = async args => {
    const result = await execute([git, '-c', 'core.hooksPath=/dev/null', ...args], cwd, approved, 10);
    const payload = JSON.parse(result.content[0].text);
    if (result.isError) throw new Error('Cannot inspect the Git repository within approved files');
    return payload.stdout.trim();
  };
  const url = await inspect(['config', '--local', '--no-includes', '--get', 'remote.' + remote + '.url']);
  if (refspec.startsWith(':')) return {url};
  const source = refspec.replace(/^\+/, '').split(':')[0];
  const commit = await inspect(['rev-parse', '--verify', source + '^{commit}']);
  const objects = await inspect(['rev-parse', '--path-format=absolute', '--git-path', 'objects']);
  return {url, commit, objects};
});
function cleanup() {
  extensions.close();
  build.close();
  for (const child of children) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
}
for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(signal, () => { cleanup(); process.exit(0); });
process.stdin.on('end', () => { cleanup(); process.exit(0); });
async function requestAccess(args) {
  if (pending) throw new Error('Another permission request is pending');
  if (!['read', 'read_write'].includes(args.access) || typeof args.reason !== 'string' || args.reason.length < 1 || args.reason.length > 500 || /[\x00-\x1f\x7f]/.test(args.reason)) throw new Error('Invalid access request');
  const location = await canonical(args.path, true);
  checkGrant(location);
  const kind = (await fs.stat(location)).isDirectory() ? 'directory' : 'file';
  if (permitted(location, args.access, await grants(session))) return text({ status: 'already_allowed', path: location });
  pending = true;
  const id = crypto.randomUUID();
  const request = { id, path: location, kind, access: args.access, reason: args.reason, expires: Date.now() + 90000 };
  const input = path.join(session, id + '.request.json');
  const output = path.join(session, id + '.response.json');
  try {
    await fs.writeFile(input + '.tmp', JSON.stringify(request), { mode: 0o600, flag: 'wx' });
    await fs.rename(input + '.tmp', input);
    while (Date.now() < request.expires) {
      try {
        const answer = JSON.parse(await fs.readFile(output, 'utf8'));
        if (answer.id !== id || answer.path !== location || answer.access !== args.access) throw new Error('Invalid local permission response');
        if (answer.approved && !permitted(location, args.access, await grants(session))) throw new Error('Approval was not applied');
        return text({ status: answer.approved ? 'approved' : 'denied', path: location, access: args.access, expires: 'disconnect' });
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      await new Promise(resolve => setTimeout(resolve, 250));
    }
    return text({ status: 'denied', reason: 'Local approval timed out. Do not repeatedly prompt.' });
  } finally {
    pending = false;
    await Promise.all([fs.rm(input, { force: true }), fs.rm(output, { force: true })]);
  }
}
async function execute(arguments_, cwd, approved, timeout = 30, shell = false) {
  const runtime = ['/bin', '/usr/bin', '/usr/lib', '/usr/share', '/System/Library', '/System/Cryptexes', root + '/work/node', root + '/work/permission-broker', ...libraries];
  const manifest = {
    version: '0.1.0', filesystem: { deny: [ { path: root + '/work/approval-reviewer.key' }, { path: root + '/work/approval-reviewer.json' }, { path: root + '/work/tunnel-runtime.key' }, { path: root + '/work/mcpproxy-runtime.key' }, { path: root + '/work/mcpproxy-pilot' }, { path: root + '/work/permission-sessions' }, ...[home + '/.ssh', home + '/Library/Keychains', home + '/.aws', home + '/.config/gcloud', home + '/.npmrc', home + '/.cargo/credentials', home + '/.cargo/credentials.toml'].map(path => ({ path }))], grants: [
      ...runtime.map(path => ({ path, access: 'read', type: 'directory' })),
      ...['/dev/null', '/dev/urandom', '/dev/random'].map(path => ({ path, access: 'readwrite', type: 'file' })),
      ...build.grants,
      ...approved.map(grant => ({ path: grant.path, access: grant.access === 'read_write' ? 'readwrite' : 'read', type: grant.kind }))
    ] }, network: { mode: shell ? 'unrestricted' : 'blocked', dns: shell },
    process: { signal_mode: 'allow_same_sandbox', process_info_mode: 'isolated', ipc_mode: 'shared_memory_only' },
    rollback: { enabled: false }
  };
  const manifestPath = path.join(session, crypto.randomUUID() + '.sandbox.json');
  await fs.writeFile(manifestPath, JSON.stringify(manifest), { flag: 'wx', mode: 0o600 });
  const flags = ['run', '--silent', '--config', manifestPath, '--', '/usr/bin/env', ...Object.entries(build.environment).map(([key, value]) => key + '=' + value), ...arguments_];
  try { return await new Promise((resolve, reject) => {
    const child = spawn(root + '/work/nono-bin/nono', flags, { cwd, detached: true, env: {
      ...build.environment,
      OPENSSL_CONF: '/dev/null',
      XDG_STATE_HOME: root + '/work/nono-state', XDG_CONFIG_HOME: root + '/work/nono-config', XDG_CACHE_HOME: root + '/work/nono-cache'
    }, stdio: ['ignore', 'pipe', 'pipe'] });
    children.add(child);
    let stdout = '', stderr = '', size = 0, stopped = false;
    const kill = () => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} };
    const timer = setTimeout(() => { stopped = true; kill(); }, timeout * 1000);
    for (const [stream, output] of [[child.stdout, false], [child.stderr, true]]) stream.on('data', chunk => {
      size += chunk.length;
      if (size > 1024 * 1024) { stopped = true; kill(); return; }
      if (output) stderr += chunk; else stdout += chunk;
    });
    child.on('error', error => { clearTimeout(timer); children.delete(child); reject(error); });
    child.on('close', code => {
      clearTimeout(timer); kill(); // Also remove any background descendants.
      children.delete(child);
      resolve({ content: [{ type: 'text', text: JSON.stringify({ exit_code: code, stdout, stderr, stopped, hint: 'Use run_shell for commands. For a denied file location, decide whether to request_access. Normal shell network access is available. For a flagged command, retry with approval_reason only if necessary; a local decision is required. Do not open Ghostty, Terminal or another app to bypass these restrictions. Screen-control approval is not permission to bypass shell restrictions.' }) }], isError: code !== 0 || stopped });
    });
  }); } finally { await fs.rm(manifestPath, { force: true }); }
}
const server = new Server({ name: 'mac-local-permissions', version: '1.0.0' }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));
server.setRequestHandler(CallToolRequestSchema, async request => {
  try {
    const { name, arguments: args = {} } = request.params;
    if (name === 'request_access') { const result = await requestAccess(args); assessCommand.record({ tool: name, path: args.path, access: args.access, outcome: JSON.parse(result.content[0].text).status }); return result; }
    if (extensionNames.includes(name)) return await extensions.call(name, args);
    const approved = await grants(session);
    if (name === 'allowed_locations') return text([...approved, ...build.grants.map(grant => ({ path: grant.path, access: grant.access === 'readwrite' ? 'read_write' : 'read', kind: grant.type, scope: 'shell_runtime' }))]);
    if (!tools.some(tool => tool.name === name)) throw new Error('Unknown tool');
    const location = await canonical(['run_shell','run_github'].includes(name) ? args.cwd : args.path);
    const access = name === 'write_file' ? 'read_write' : 'read';
    if (!permitted(location, access, approved)) return { ...text({ status: 'access_denied', path: location, access, hint: 'Decide whether to request_access for this location or use an approved location.' }), isError: true };
    if (name === 'run_github') return await runGitHub(args, location, approved);
    if (name === 'run_shell') {
      if (typeof args.command !== 'string' || args.command.length > 65536) throw new Error('Invalid command');
      const timeout = args.timeout_seconds ?? 30;
      if (!Number.isInteger(timeout) || timeout < 1 || timeout > 300) throw new Error('Timeout must be 1–300 seconds');
      if (args.task_context !== undefined && (typeof args.task_context !== 'string' || args.task_context.length > 2000)) throw new Error('Invalid task context');
      const assessment = await assessCommand(args.command, location, args.approval_reason, { task: args.task_context, scope: approved.map(({path, access}) => ({path, access})) });
      if (!assessment.allowed) return { ...text(assessment), isError: true };
      const githubArgs = simpleGitHub(args.command);
      if (githubArgs) return await runGitHub({args:githubArgs, approval_reason:args.approval_reason, timeout_seconds:timeout}, location, approved);
      const result = await execute(['/bin/bash', '--noprofile', '--norc', '-c', args.command], location, approved, timeout, true);
      assessCommand.record({ tool: name, command: args.command.slice(0, 1000), cwd: location, succeeded: !result.isError });
      const payload = JSON.parse(result.content[0].text);
      if (assessment.review) payload.review = assessment.review;
      return { ...result, content: [{ type: 'text', text: JSON.stringify(payload) }] };
    }
    if (name === 'write_file' && (typeof args.content !== 'string' || Buffer.byteLength(args.content) > 512 * 1024)) throw new Error('Invalid file content');
    assessCommand.record({ tool: name, path: location });
    return await execute([process.execPath, root + '/work/permission-broker/operation.mjs', { read_file: 'read', write_file: 'write', list_directory: 'list' }[name], location, name === 'write_file' ? Buffer.from(args.content).toString('base64') : ''], workspace, approved);
  } catch (error) { return { ...text({ status: 'error', message: error.message }), isError: true }; }
});
await server.connect(new StdioServerTransport());
