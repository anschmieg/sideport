import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { Client } from '../baseline/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js';
import { StdioClientTransport } from '../baseline/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js';
import { root, workspace } from './policy.mjs';
const directories = await fs.readdir(root + '/work/permission-sessions');
const session = root + '/work/permission-sessions/' + directories.at(-1);
const transport = new StdioClientTransport({ command: process.execPath, args: [root + '/work/permission-broker/server.mjs'], env: { SIDEPORT_HOME: root, HOME: process.env.HOME, PATH: root + '/work/node/bin:/usr/bin:/bin', MAC_CHATGPT_APPROVAL_DIR: session } });
const client = new Client({ name: 'local-permission-check', version: '1' });
await client.connect(transport);
async function call(name, args) {
  return await client.callTool({ name, arguments: args }, undefined, { timeout: 110000 });
}
const fixture = workspace + '/permission-test-' + Date.now();
const outside = await fs.mkdtemp('/private/tmp/mac-permission-test-');
await fs.writeFile(outside + '/sentinel', 'outside synthetic sentinel');
try {
  const write = await call('write_file', { path: fixture, content: 'inside synthetic sentinel' });
  assert.ok(!write.isError, JSON.stringify(write));
  const read = await call('read_file', { path: fixture });
  assert.ok(!read.isError && read.content[0].text.includes('inside synthetic sentinel'), JSON.stringify(read));
  const denied = await call('read_file', { path: outside + '/sentinel' });
  assert.ok(denied.isError && denied.content[0].text.includes('access_denied'));
  const shell = await call('run_shell', { cwd: workspace, command: `/bin/cat '${outside}/sentinel'` });
  assert.ok(shell.isError && /Operation not permitted|Permission denied/.test(shell.content[0].text), JSON.stringify(shell));
  const symlink = await call('run_shell', { cwd: workspace, command: `/bin/ln -s '${outside}/sentinel' '${fixture}.link'; /bin/cat '${fixture}.link'` });
  assert.ok(symlink.isError && /Operation not permitted|Permission denied/.test(symlink.content[0].text), JSON.stringify(symlink));
  const nested = await call('run_shell', { cwd: workspace, command: `/bin/bash -c "/bin/cat '${outside}/sentinel'"` });
  assert.ok(nested.isError);
  const network = await call('run_shell', { cwd: workspace, command: '/usr/bin/curl --max-time 3 http://127.0.0.1:18089/healthz' });
  assert.ok(network.isError && /Operation not permitted|Permission denied|Couldn't connect|Could not connect/.test(network.content[0].text), JSON.stringify(network));
  const forbidden = await call('request_access', { path: root, access: 'read_write', reason: 'Synthetic controller protection test' });
  assert.ok(forbidden.isError && forbidden.content[0].text.includes('controller'));
  console.log('PASS: allowed read/write; denied location; kernel denial; symlink; child process; blocked network; protected controller.');
  if (process.argv.includes('--prompt')) {
    console.log('PROMPT LOCATION: ' + outside);
    const response = await call('request_access', { path: outside, access: 'read', reason: 'Read a synthetic test file to verify the local permission prompt.' });
    console.log('PROMPT RESULT: ' + JSON.stringify(response));
    const after = await call('read_file', { path: outside + '/sentinel' });
    const approved = response.content[0].text.includes('"status":"approved"');
    assert.equal(!after.isError, approved, JSON.stringify(after));
    if (approved) {
      const deniedWrite = await call('write_file', { path: outside + '/sentinel', content: 'must not overwrite' });
      assert.ok(deniedWrite.isError && deniedWrite.content[0].text.includes('access_denied'));
      const deniedShellWrite = await call('run_shell', { cwd: workspace, command: `printf forbidden > '${outside}/sentinel'` });
      assert.ok(deniedShellWrite.isError);
      assert.equal(await fs.readFile(outside + '/sentinel', 'utf8'), 'outside synthetic sentinel');
      if (process.argv.includes('--extra-grants')) {
        const fileGrant = await call('request_access', { path: outside + '/sentinel', access: 'read_write', reason: 'Verify a grant to one synthetic file does not allow writing its neighbors.' });
        assert.ok(fileGrant.content[0].text.includes('"status":"approved"'));
        const writeFile = await call('write_file', { path: outside + '/sentinel', content: 'approved file only' });
        assert.ok(!writeFile.isError, JSON.stringify(writeFile));
        const neighbor = await call('run_shell', { cwd: workspace, command: `printf forbidden > '${outside}/neighbor'` });
        assert.ok(neighbor.isError);
      }
      console.log('PASS: read-only approval does not permit writes.');
    }
    console.log('PASS: prompt decision applied to fresh sandbox.');
  }
} finally {
  await call('run_shell', { cwd: workspace, command: `/bin/rm -f '${fixture}' '${fixture}.link'` });
  await fs.rm(outside, { recursive: true, force: true });
  await client.close();
}
