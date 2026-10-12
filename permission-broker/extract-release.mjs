import fs from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const run = promisify(execFile);
export async function extractRelease(archive, destination) {
  // macOS bsdtar understands ZIP and tar.gz; refuse every link and special member before extraction.
  const options = { timeout: 30000, maxBuffer: 8 * 1024 * 1024, env: { PATH: '/usr/bin:/bin', LC_ALL: 'C' } };
  const { stdout: names } = await run('/usr/bin/tar', ['-tf', archive], options);
  const entries = names.split('\n').filter(Boolean);
  if (!entries.length || entries.length > 10000) throw new Error('Invalid archive size');
  const seen = new Set();
  for (const name of entries) {
    if (name.startsWith('/') || name.includes('\\') || /[\x00-\x1f\x7f]/.test(name) || name.split('/').includes('..')) throw new Error('Unsafe archive path');
    const normalized = path.posix.normalize(name).replace(/\/$/, '');
    if (seen.has(normalized)) throw new Error('Duplicate archive member'); seen.add(normalized);
  }
  const { stdout: listing } = await run('/usr/bin/tar', ['-tvf', archive], options);
  const rows = listing.split('\n').filter(Boolean);
  if (rows.length !== entries.length || rows.some(row => !['-', 'd'].includes(row[0]))) throw new Error('Archive links and special files are refused');
  const empty = await fs.mkdtemp(path.join(path.dirname(destination), 'extract-'));
  try {
    await run('/usr/bin/tar', ['-xf', archive, '-C', empty, '--no-same-owner', '--no-same-permissions'], options);
    let total = 0;
    async function check(dir) {
      for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
        const file = path.join(dir, entry.name), stat = await fs.lstat(file);
        if (stat.isDirectory()) await check(file);
        else if (stat.isFile()) { total += stat.size; if (total > 1024 * 1024 * 1024) throw new Error('Release is too large'); await fs.chmod(file, stat.mode & 0o111 ? 0o755 : 0o644); }
        else throw new Error('Unexpected extracted file type');
      }
    }
    await check(empty);
    async function copy(source, target) {
      await fs.mkdir(target, { recursive: true });
      for (const item of await fs.readdir(source, { withFileTypes: true })) {
        const from = path.join(source, item.name), to = path.join(target, item.name);
        if (item.isDirectory()) await copy(from, to);
        else { await fs.copyFile(from, to, 1); await fs.chmod(to, (await fs.stat(from)).mode & 0o111 ? 0o755 : 0o644); }
      }
    }
    await copy(empty, destination);
  } finally { await fs.rm(empty, { recursive: true, force: true }); }
}
