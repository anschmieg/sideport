import path from 'node:path';
export function npmSpec(name, version) {
  if (typeof name !== 'string' || !/^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(name)) throw new Error('Use an npm package name');
  if (typeof version !== 'string' || !/^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$/.test(version)) throw new Error('Use an exact version, not latest or a version range');
  return name + '@' + version;
}
export function validateArgs(args) {
  if (!Array.isArray(args) || args.length > 30 || args.some(value => typeof value !== 'string' || value.length > 4096 || /[\x00-\x1f\x7f]/.test(value))) throw new Error('Invalid server arguments');
  return args;
}
export function validateBin(packageRoot, bin) {
  if (typeof bin !== 'string' || !bin || path.isAbsolute(bin) || bin.split('/').includes('..')) throw new Error('Package executable must remain inside the cached package');
  return path.join(packageRoot, bin);
}
export function selectorDrag(tool, args) {
  if (/drag/i.test(tool)) {
    const keys = Object.keys(args || {});
    if (keys.some(key => /coordinate|coords|startX|startY|endX|endY|^x$|^y$|fromX|fromY|toX|toY/i.test(key))) throw new Error('Drag requires source and target element selectors, never coordinates');
    const source = args.from || args.source || args.from_element || args.source_element || args.fromElement || args.sourceElement;
    const target = args.to || args.target || args.to_element || args.target_element || args.toElement || args.targetElement;
    if (typeof source !== 'string' || typeof target !== 'string' || !source || !target || /\d+\s*,\s*\d+/.test(source + target)) throw new Error('Drag requires source and target element selectors');
  }
}
