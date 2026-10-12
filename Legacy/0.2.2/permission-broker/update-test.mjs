import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
import { replaceVerified } from './update-transaction.mjs';
import { root } from './policy.mjs';
for (const mode of ['success', 'failed-check', 'missing-stage']) {
  const fixture = await fs.mkdtemp(root + '/work/update-test-');
  const base = fixture + '/live/', stage = fixture + '/stage', backup = fixture + '/backup';
  const swaps = [{ dir: 'mcpproxy-bin', metadata: 'mcpproxy-release.json', release: { tag_name: 'new' } }, { dir: 'nono-bin' }];
  try {
    await fs.mkdir(base); await fs.mkdir(stage);
    await fs.writeFile(base + 'mcpproxy-release.json', JSON.stringify({ tag_name: 'old' }));
    for (const swap of swaps) {
      await fs.mkdir(base + swap.dir); await fs.writeFile(base + swap.dir + '/version', 'old');
      if (!(mode === 'missing-stage' && swap.dir === 'nono-bin')) { await fs.mkdir(stage + '/' + swap.dir); await fs.writeFile(stage + '/' + swap.dir + '/version', 'new'); }
    }
    const operation = () => replaceVerified({ base, stage, backup, swaps }, async () => {
      assert.equal(await fs.readFile(base + 'mcpproxy-bin/version', 'utf8'), 'new');
      if (mode === 'failed-check') throw new Error('Synthetic compatibility failure');
    });
    if (mode === 'success') {
      await operation(); assert.equal(await fs.readFile(backup + '/mcpproxy-bin/version', 'utf8'), 'old');
      assert.equal(JSON.parse(await fs.readFile(base + 'mcpproxy-release.json', 'utf8')).tag_name, 'new');
    } else {
      await assert.rejects(operation, /previous dependencies restored/);
      for (const swap of swaps) assert.equal(await fs.readFile(base + swap.dir + '/version', 'utf8'), 'old');
      assert.equal(JSON.parse(await fs.readFile(base + 'mcpproxy-release.json', 'utf8')).tag_name, 'old');
    }
  } finally { await fs.rm(fixture, { recursive: true, force: true }); }
}
console.log('PASS: verified update, compatibility-failure rollback and partial-swap rollback preserve dependency files and metadata.');
