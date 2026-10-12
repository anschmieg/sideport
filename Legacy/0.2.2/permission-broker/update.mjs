import { extractRelease } from './extract-release.mjs';
// Local tray maintenance only; never exposed as an MCP tool.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { root, workspace } from './policy.mjs';
import { StdioPeer } from './rpc.mjs';
import { replaceVerified } from './update-transaction.mjs';
const run = promisify(execFile);
const base = root + '/work/';
const targets = [
  { key: 'mcpproxy', repo: 'smart-mcp-proxy/mcpproxy-go', metadata: 'mcpproxy-release.json', dir: 'mcpproxy-bin', pattern: '^mcpproxy-[0-9.]+-darwin-arm64\\.tar\\.gz$', executable: 'mcpproxy' },
  { key: 'nono', repo: 'nolabs-ai/nono', metadata: 'nono-release.json', dir: 'nono-bin', pattern: '^nono-v[0-9.]+-aarch64-apple-darwin\\.tar\\.gz$', executable: 'nono' },
  { key: 'tunnel', repo: 'openai/tunnel-client', metadata: 'tunnel-release.json', dir: 'tunnel-client', pattern: '^tunnel-client-v[0-9.]+-darwin-arm64\\.zip$', runtimePattern: '^tunnel-client-runtime-cloudflared-v[0-9.]+-darwin-arm64\\.zip$', executable: 'tunnel-client' }
];
async function json(url) {
  const response = await fetch(url, { headers: { 'User-Agent': 'Mac-ChatGPT-Updater' }, signal: AbortSignal.timeout(30000) });
  if (!response.ok) throw new Error('Update service unavailable (' + response.status + ')');
  return await response.json();
}
async function plan() {
  const releases = await Promise.all(targets.map(async target => {
    const current = JSON.parse(await fs.readFile(base + target.metadata, 'utf8'));
    const latest = await json('https://api.github.com/repos/' + target.repo + '/releases/latest');
    if (latest.draft || latest.prerelease || !/^v?\d+\.\d+\.\d+$/.test(latest.tag_name)) throw new Error('Unexpected release metadata');
    const asset = latest.assets.find(a => new RegExp(target.pattern).test(a.name));
    const runtime = target.runtimePattern ? latest.assets.find(a => new RegExp(target.runtimePattern).test(a.name)) : undefined;
    for (const selected of [asset, runtime].filter(Boolean)) {
      if (!/^sha256:[a-f0-9]{64}$/.test(selected.digest || '') || !selected.browser_download_url.startsWith('https://github.com/' + target.repo + '/releases/download/')) throw new Error('Release lacks a verified download digest');
    }
    if (!asset || (target.runtimePattern && !runtime)) throw new Error('Compatible Mac release not found');
    return { ...target, current: current.tag_name, next: latest.tag_name, release: latest, asset, runtime };
  }));
  const packages = JSON.parse(await fs.readFile(base + 'baseline/package.json', 'utf8'));
  const name = '@steipete/peekaboo';
  const peekaboo = await json('https://registry.npmjs.org/@steipete%2fpeekaboo/latest');
  if (!/^\d+\.\d+\.\d+$/.test(peekaboo.version)) throw new Error('Unexpected Peekaboo release');
  const result = { created: Date.now(), releases, peekaboo: { current: packages.dependencies[name], next: peekaboo.version } };
  await fs.writeFile(base + 'update-plan.json', JSON.stringify(result), { mode: 0o600 });
  console.log(JSON.stringify({ changes: [...releases.filter(r => r.current !== r.next).map(r => `${r.key}: ${r.current} → ${r.next}`), ...(result.peekaboo.current !== result.peekaboo.next ? [`Peekaboo: ${result.peekaboo.current} → ${result.peekaboo.next}`] : [])] }));
}
async function find(directory, filename) {
  for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
    const location = path.join(directory, entry.name);
    if (entry.isFile() && entry.name === filename) return location;
    if (entry.isDirectory()) { const found = await find(location, filename); if (found) return found; }
  }
}
async function apply() {
  const checked = JSON.parse(await fs.readFile(base + 'update-plan.json', 'utf8'));
  if (Date.now() - checked.created > 600000 || checked.created > Date.now()) throw new Error('Update check expired; check again');
  const stage = await fs.mkdtemp(base + 'update-stage-');
  const backup = base + 'update-backup';
  const swaps = [];
  try {
    for (const target of checked.releases.filter(r => r.current !== r.next)) {
      const known = targets.find(t => t.key === target.key);
      if (!known || known.repo !== target.repo || known.dir !== target.dir) throw new Error('Invalid update plan');
      const output = stage + '/' + known.dir; await fs.mkdir(output);
      for (const asset of [target.asset, target.runtime].filter(Boolean)) {
        if (!/^sha256:[a-f0-9]{64}$/.test(asset.digest) || !asset.browser_download_url.startsWith('https://github.com/' + known.repo + '/releases/download/')) throw new Error('Invalid release download');
        const response = await fetch(asset.browser_download_url, { signal: AbortSignal.timeout(120000) });
        if (!response.ok) throw new Error('Release download failed');
        const bytes = Buffer.from(await response.arrayBuffer());
        if (crypto.createHash('sha256').update(bytes).digest('hex') !== asset.digest.slice(7)) throw new Error('Release checksum mismatch');
        const archive = stage + '/' + asset.name; await fs.writeFile(archive, bytes);
        await extractRelease(archive, output);
      }
      const executable = await find(output, known.executable); if (!executable) throw new Error('Release executable missing');
      if (path.dirname(executable) !== output) await fs.cp(path.dirname(executable), output, { recursive: true });
      await fs.chmod(output + '/' + known.executable, 0o755);
      if (known.key === 'tunnel') { const cloud = await find(output, 'cloudflared'); if (!cloud) throw new Error('Tunnel runtime missing'); if (cloud !== output + '/cloudflared') await fs.copyFile(cloud, output + '/cloudflared'); await fs.chmod(output + '/cloudflared', 0o755); }
      await run(output + '/' + known.executable, ['--version'], { timeout: 15000 });
      swaps.push({ dir: known.dir, metadata: known.metadata, release: target.release });
    }
    if (checked.peekaboo.current !== checked.peekaboo.next) {
      if (!/^\d+\.\d+\.\d+$/.test(checked.peekaboo.next)) throw new Error('Invalid package version');
      const packages = JSON.parse(await fs.readFile(base + 'baseline/package.json', 'utf8'));
      packages.dependencies['@steipete/peekaboo'] = checked.peekaboo.next;
      const output = stage + '/baseline'; await fs.mkdir(output);
      await fs.writeFile(output + '/package.json', JSON.stringify(packages));
      const npm = await fs.realpath(root + '/work/node/lib/node_modules/npm/bin/npm-cli.js');
      const env = { PATH: root + '/work/node/bin:/opt/homebrew/bin:/usr/bin:/bin', HOME: process.env.HOME, npm_config_userconfig: stage + '/empty-user', npm_config_globalconfig: stage + '/empty-global', npm_config_cache: stage + '/npm-cache' };
      await run(process.execPath, [npm, 'install', '--ignore-scripts', '--no-fund', '--no-audit', '--registry=https://registry.npmjs.org'], { cwd: output, env, timeout: 180000 });
      await run(process.execPath, [npm, 'audit', '--audit-level=high', '--registry=https://registry.npmjs.org'], { cwd: output, env, timeout: 60000 });
      const executable = output + '/node_modules/@steipete/peekaboo/peekaboo'; await fs.chmod(executable, 0o755);
      await run(executable, ['permissions', 'status', '--no-remote', '--json'], { timeout: 15000 });
      swaps.push({ dir: 'baseline' });
    }
    if (!swaps.length) { console.log('All dependencies are current.'); return; }
    if (swaps.some(swap => swap.dir === 'mcpproxy-bin')) {
      await fs.cp(base + 'mcpproxy-pilot', stage + '/mcpproxy-pilot', { recursive: true });
      swaps.push({ dir: 'mcpproxy-pilot' });
    }
    await replaceVerified({ base, stage, backup, swaps }, async () => {
      await run(process.execPath, [base + 'permission-broker/managed-test.mjs'], { timeout: 30000 });
      await run(process.execPath, [base + 'permission-broker/github-test.mjs'], { timeout: 30000 });
      await run(process.execPath, [base + 'permission-broker/extensions-test.mjs'], { timeout: 15000 });
      await run(process.execPath, [base + 'permission-broker/provider-smoke.mjs'], { timeout: 180000 });
      await run(process.execPath, [base + 'permission-broker/kernel-provider-test.mjs'], { timeout: 15000 });
      const session = await fs.mkdtemp(base + 'permission-sessions/update-');
      await fs.writeFile(session + '/grants.json', JSON.stringify([{ path: workspace, access: 'read_write', kind: 'directory' }]));
      const peer = new StdioPeer(process.execPath, [base + 'permission-broker/server.mjs'], { env: { SIDEPORT_HOME: root, HOME: process.env.HOME, PATH: root + '/work/node/bin:/usr/bin:/bin', MAC_CHATGPT_APPROVAL_DIR: session } });
      try { await peer.connect(); const tools = await peer.request('tools/list'); if (!tools.tools.some(t => t.name === 'request_server')) throw new Error('Broker compatibility check failed'); } finally { peer.close(); await fs.rm(session, { recursive: true, force: true }); }
      const smoke = await run(process.env.SIDEPORT_APP_EXECUTABLE, ['--smoke-test-local'], { timeout: 40000 });
      if (!smoke.stdout.includes('SMOKE: gateway ready; remote access stayed off') || !smoke.stdout.includes('SMOKE: owned services stopped')) throw new Error('Gateway compatibility check failed');
      await run(base + 'tunnel-client/tunnel-client', ['doctor', '--profile-file', base + 'tunnel-profiles/macbook-mcpproxy.yaml'], { timeout: 30000 });
    });
    console.log('Dependencies updated and compatibility checks passed. Previous versions retained for rollback.');
  } finally { await fs.rm(stage, { recursive: true, force: true }); }
}
try {
  if (process.argv.includes('--apply')) await apply(); else await plan();
} catch (error) { console.error(error.message); process.exitCode = 1; }
