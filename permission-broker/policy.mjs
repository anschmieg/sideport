import fs from 'node:fs/promises';
import path from 'node:path';
export const root = path.resolve(process.env.SIDEPORT_HOME || path.join(process.env.HOME, 'Library/Application Support/Sideport')); 
export const home = process.env.HOME;
export const workspace = process.env.SIDEPORT_WORKSPACE || `${home}/Documents/ChatGPT Workspace`;
export const inside = (candidate, parent) => candidate === parent || candidate.startsWith(parent + '/');
export async function canonical(value, mustExist = false) {
  if (typeof value !== 'string' || value.length > 4096 || /[\x00-\x1f\x7f]/.test(value)) throw new Error('Invalid path');
  const absolute = path.resolve(value.startsWith('~/') ? home + value.slice(1) : value);
  if (!path.isAbsolute(value) && !value.startsWith('~/')) throw new Error('Use an absolute path or ~/path');
  try { return await fs.realpath(absolute); } catch (error) {
    if (mustExist || error.code !== 'ENOENT') throw error;
    return path.join(await canonical(path.dirname(absolute)), path.basename(absolute));
  }
}
export function checkGrant(location) {
  // Neither an ancestor nor a descendant of controller state may be granted.
  if (inside(location, root) || inside(root, location)) throw new Error('This location contains the connection controller or its credentials. Choose a separate folder.');
}
export async function grants(session) {
  const state = JSON.parse(await fs.readFile(path.join(session, 'grants.json'), 'utf8'));
  if (!Array.isArray(state)) throw new Error('Invalid local permission state');
  const valid = [];
  for (const grant of state) {
    if (!['read', 'read_write'].includes(grant.access) || !['file', 'directory'].includes(grant.kind)) throw new Error('Invalid local grant');
    let actual;
    try { actual = await canonical(grant.path, true); } catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    if (actual !== grant.path) throw new Error('Approved location changed; reconnect before retrying');
    if (((await fs.stat(actual)).isDirectory() ? 'directory' : 'file') !== grant.kind) throw new Error('Approved location type changed');
    checkGrant(actual);
    valid.push(grant);
  }
  return valid;
}
export function permitted(location, access, approved) {
  return approved.some(grant => (grant.kind === 'directory' ? inside(location, grant.path) : location === grant.path)
    && (access === 'read' || grant.access === 'read_write'));
}
