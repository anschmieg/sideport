// Runs only inside the OS sandbox; never receives credentials or approval state.
import fs from 'node:fs/promises';
const [operation, path, data] = process.argv.slice(2);
if (operation === 'read') {
  const handle = await fs.open(path, 'r');
  try {
    const buffer = Buffer.alloc(1024 * 1024);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    console.log(buffer.subarray(0, bytesRead).toString('utf8'));
  } finally { await handle.close(); }
} else if (operation === 'write') {
  await fs.writeFile(path, Buffer.from(data, 'base64'));
  console.log('File written.');
} else if (operation === 'list') {
  console.log(JSON.stringify((await fs.readdir(path, { withFileTypes: true }))
    .slice(0, 2000).map(entry => ({ name: entry.name, directory: entry.isDirectory() }))));
} else { throw new Error('Unknown operation'); }
