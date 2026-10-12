import fs from 'node:fs/promises';
export async function replaceVerified({ base, stage, backup, swaps }, validate) {
  for (const swap of swaps) {
    if (!['baseline', 'mcpproxy-bin', 'nono-bin', 'tunnel-client', 'mcpproxy-pilot'].includes(swap.dir)) throw new Error('Invalid dependency target');
    if (swap.metadata && !['mcpproxy-release.json', 'nono-release.json', 'tunnel-release.json'].includes(swap.metadata)) throw new Error('Invalid release metadata target');
  }
  await fs.rm(backup, { recursive: true, force: true }); await fs.mkdir(backup, { mode: 0o700 });
  const applied = [];
  try {
    for (const swap of swaps) if (swap.metadata) await fs.copyFile(base + swap.metadata, backup + '/' + swap.metadata);
    for (const swap of swaps) {
      await fs.rename(base + swap.dir, backup + '/' + swap.dir);
      applied.push(swap);
      await fs.rename(stage + '/' + swap.dir, base + swap.dir);
    }
    await validate();
    for (const swap of swaps) if (swap.metadata) await fs.writeFile(base + swap.metadata, JSON.stringify(swap.release));
    await fs.writeFile(backup + '/manifest.json', JSON.stringify(applied));
  } catch (error) {
    const failures = [];
    for (const swap of applied.reverse()) {
      try {
        await fs.rm(base + swap.dir, { recursive: true, force: true });
        await fs.rename(backup + '/' + swap.dir, base + swap.dir);
        if (swap.metadata) await fs.copyFile(backup + '/' + swap.metadata, base + swap.metadata);
      } catch (failure) { failures.push(failure.message); }
    }
    if (failures.length) throw new Error('Update and rollback failed. Backups remain at ' + backup + ': ' + failures.join('; '));
    throw new Error('Update failed; previous dependencies restored. ' + error.message);
  }
}
