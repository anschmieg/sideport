// Default development support. No credentials or arbitrary home/project grants.
import fs from 'node:fs/promises';
import { rmSync } from 'node:fs';
import path from 'node:path';
import tls from 'node:tls';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { root, home, checkGrant } from './policy.mjs';

const installations = [
  '/opt/homebrew/include', '/opt/homebrew/libexec', '/opt/homebrew/Frameworks',
  '/usr/local/include', '/usr/local/libexec', '/usr/local/opt', '/usr/local/Cellar', '/usr/local/Frameworks', '/usr/local/go', '/usr/local/n',
  '/opt/R', '/opt/X11', '/Library/Frameworks/Python.framework', '/Library/Java/JavaVirtualMachines',
  home + '/.local/share/fnm', home + '/.local/share/zigup', home + '/.local/share/mise/downloads', home + '/.deno/bin', home + '/.julia/juliaup', home + '/.dotnet', home + '/Library/Android/sdk',
  '/opt/homebrew/bin', '/opt/homebrew/sbin', '/opt/homebrew/Cellar', '/opt/homebrew/opt', '/opt/homebrew/lib', '/opt/homebrew/share',
  '/usr/local/bin', '/usr/local/sbin', '/usr/local/lib', '/usr/local/share',
  '/Library/Developer/CommandLineTools', '/Applications/Xcode.app/Contents/Developer',
  home + '/.local/pkgs', home + '/.pkgx', home + '/.local/share/mise/installs', home + '/.local/share/uv/python', home + '/.cargo/bin', home + '/.rustup', home + '/.bun/bin', home + '/.local/bin',
  '/private/var/select', home + '/.nvm/versions', home + '/.volta/tools', home + '/.asdf/installs', home + '/.pyenv/versions', home + '/.sdkman/candidates', home + '/Library/pnpm'
];
const caches = [
  home + '/Library/Caches/Homebrew', home + '/Library/Caches/Coursier', home + '/.cache/coursier', home + '/.sbt/boot', home + '/.ivy2/cache',
  home + '/.nuget/packages', home + '/.pub-cache', home + '/.cache/dart', home + '/.cache/deno', home + '/Library/Caches/deno',
  home + '/.cache/ccache', home + '/.cache/sccache', home + '/Library/Caches/ccache', home + '/Library/Caches/sccache',
  home + '/.cache/zig', home + '/Library/Caches/zig', home + '/.cache/nix',
  home + '/.cache/puppeteer', home + '/Library/Caches/ms-playwright', home + '/Library/Caches/ms-playwright-mcp',
  home + '/.julia/packages', home + '/.julia/artifacts', home + '/.julia/compiled', home + '/.julia/registries', home + '/.julia/scratchspaces',
  home + '/.cache/huggingface/hub', home + '/.cache/huggingface/assets',
  home + '/Library/Caches/org.swift.swiftpm', home + '/.cache/org.swift.swiftpm',
  home + '/Library/Developer/Xcode/Archives', home + '/Library/Developer/Xcode/iOS DeviceSupport',
  home + '/.npm', home + '/.bun/install/cache', home + '/.cargo/registry', home + '/.cargo/git',
  home + '/go/pkg/mod', home + '/Library/Caches/go-build',
  home + '/Library/Caches/pip', home + '/Library/Caches/uv', home + '/.cache/pip', home + '/.cache/uv',
  home + '/Library/Caches/node-gyp', home + '/.cache/node-gyp',
  home + '/Library/Caches/Yarn', home + '/.cache/yarn', home + '/Library/pnpm/store', home + '/.local/share/pnpm/store',
  home + '/.gradle/caches', home + '/.gradle/wrapper', home + '/.m2/repository',
  home + '/Library/Developer/Xcode/DerivedData', home + '/Library/Developer/Xcode/ModuleCache.noindex'
];
export async function buildRuntime() {
  const entries = new Map();
  async function add(value, access, type = 'directory') {
    try {
      const actual = await fs.realpath(value);
      checkGrant(actual);
      if ((await fs.stat(actual)).isDirectory() !== (type === 'directory')) return undefined;
      if (entries.get(actual)?.access !== 'readwrite') entries.set(actual, { path: actual, access, type });
      if (value !== actual && entries.get(value)?.access !== 'readwrite') entries.set(value, { path: value, access, type });
      return actual;
    } catch (error) { if (!['ENOENT', 'ENOTDIR'].includes(error.code)) throw error; return undefined; }
  }
  for (const location of installations) await add(location, 'read');
  for (const location of caches) await add(location, 'readwrite');
  // Public macOS runtime data, never the whole /private or /var tree.
  for (const location of ['/private/etc/ssl', '/private/etc/paths', '/private/etc/paths.d', '/private/etc/localtime', '/private/etc/hosts', '/private/etc/resolv.conf', '/private/var/run/resolv.conf', '/private/etc/services', '/etc/resolv.conf', '/var/run/resolv.conf', '/etc/hosts', '/private/etc/nsswitch.conf']) {
    try { await add(location, 'read', (await fs.stat(location)).isDirectory() ? 'directory' : 'file'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  const temporary = await fs.mkdtemp('/private/tmp/sideport-');
  await fs.chmod(temporary, 0o700);
  await add(temporary, 'readwrite');
  // Apple tools use the OS per-user temporary folder, even when TMPDIR is set.
  const { stdout: userTemporary } = await promisify(execFile)('/usr/bin/getconf', ['DARWIN_USER_TEMP_DIR'], { timeout: 5000 });
  const userTemp = await fs.realpath(userTemporary.trim());
  if (!userTemp.startsWith('/private/var/folders/') || !userTemp.endsWith('/T')) throw new Error('Unexpected macOS temporary directory');
  await add(userTemp, 'readwrite');
  const fallback = async name => {
    const location = path.join(temporary, name); await fs.mkdir(location, { mode: 0o700 }); return location;
  };
  const existing = async (location, name) => await add(location, 'readwrite') || await fallback(name);
  const cargoHome = await fallback('cargo');
  for (const name of ['registry', 'git']) {
    const cache = await add(path.join(home, '.cargo', name), 'readwrite');
    if (cache) await fs.symlink(cache, path.join(cargoHome, name));
  }
  const npmUser = path.join(temporary, 'npm-user.conf');
  const npmGlobal = path.join(temporary, 'npm-global.conf');
  await fs.writeFile(npmUser, ''); await fs.writeFile(npmGlobal, '');
  const trust = path.join(temporary, 'public-trust.pem');
  await fs.writeFile(trust, [...new Set([...tls.getCACertificates('bundled'), ...tls.getCACertificates('system')])].join('\n'));
  const environment = {
    NODE_EXTRA_CA_CERTS: trust, SSL_CERT_FILE: trust, REQUESTS_CA_BUNDLE: trust, CURL_CA_BUNDLE: trust, CARGO_HTTP_CAINFO: trust, GIT_SSL_CAINFO: trust,
    PATH: root + '/work/node/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:' + home + '/.cargo/bin:' + home + '/.bun/bin:' + home + '/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
    HOME: home, TMPDIR: temporary + '/', TMP: temporary, TEMP: temporary,
    CARGO_HOME: cargoHome,
    NPM_CONFIG_CACHE: await existing(home + '/.npm', 'npm-cache'),
    NPM_CONFIG_USERCONFIG: npmUser, NPM_CONFIG_GLOBALCONFIG: npmGlobal,
    BUN_INSTALL_CACHE_DIR: await existing(home + '/.bun/install/cache', 'bun-cache'),
    GOCACHE: await existing(home + '/Library/Caches/go-build', 'go-build'),
    GOMODCACHE: await existing(home + '/go/pkg/mod', 'go-mod'),
    PIP_CACHE_DIR: await existing(home + '/Library/Caches/pip', 'pip-cache'),
    UV_CACHE_DIR: await existing(home + '/Library/Caches/uv', 'uv-cache'),
    XDG_CACHE_HOME: await fallback('xdg-cache'),
    GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', OPENSSL_CONF: '/dev/null'
  };
  for (const selected of ['/var/db/xcode_select_link', '/Library/Developer/CommandLineTools', '/Applications/Xcode.app/Contents/Developer']) {
    const actual = await add(selected, 'read');
    if (!actual) continue;
    environment.DEVELOPER_DIR = actual;
    const sdk = await add(path.join(actual, 'SDKs/MacOSX.sdk'), 'read') || await add(path.join(actual, 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'), 'read');
    if (sdk) environment.SDKROOT = sdk;
    environment.PATH = path.join(actual, 'usr/bin') + ':' + environment.PATH;
    break;
  }
  return { grants: [...entries.values()], environment, close() { rmSync(temporary, { recursive: true, force: true }); } };
}
