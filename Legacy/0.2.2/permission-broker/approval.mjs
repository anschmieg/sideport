import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
export function approvalQueue(session) {
  let pending = false;
  return async function approve(capability, details, reason) {
    if (pending) throw new Error('Another approval is pending');
    if (typeof reason !== 'string' || !reason.length || reason.length > 500 || /[\x00-\x1f\x7f]/.test(reason)) throw new Error('Invalid reason');
    pending = true;
    const id = crypto.randomUUID();
    const request = { id, capability, details, reason, expires: Date.now() + 90000 };
    const input = path.join(session, id + '.capability.json');
    const output = path.join(session, id + '.decision.json');
    try {
      const serialized = JSON.stringify(request);
      if (Buffer.byteLength(serialized) > 8000) throw new Error('Approval details are too large; use fewer server arguments or approved locations');
      await fs.writeFile(input + '.tmp', serialized, { mode: 0o600, flag: 'wx' });
      await fs.rename(input + '.tmp', input);
      while (Date.now() < request.expires) {
        try {
          const answer = JSON.parse(await fs.readFile(output, 'utf8'));
          if (answer.id !== id || answer.capability !== capability) throw new Error('Invalid local decision');
          return answer.approved === true;
        } catch (error) { if (error.code !== 'ENOENT') throw error; }
        await new Promise(resolve => setTimeout(resolve, 250));
      }
      return false;
    } finally {
      pending = false;
      await Promise.all([fs.rm(input, { force: true }), fs.rm(output, { force: true })]);
    }
  };
}
