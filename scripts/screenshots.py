#!/usr/bin/env python3
"""Render Sideport's own native views with synthetic data, without screen capture."""
import argparse
import os
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--executable', type=pathlib.Path, default=repo / '.build/release/Sideport')
parser.add_argument('--output', type=pathlib.Path, default=repo / 'docs/images')
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='sideport-docs-', dir='/private/tmp') as root:
    env = dict(os.environ, SIDEPORT_HOME=root, SIDEPORT_RESOURCES=str(repo / 'Resources'))
    subprocess.run([str(args.executable.resolve()), '--documentation-preview', str(args.output.resolve())], env=env, check=True, timeout=30)
for name in ['connection-off.png', 'connection-active.png', 'folder-approval.png', 'desktop-control.png']:
    path = args.output / name
    if not path.is_file() or path.read_bytes()[:8] != b'\x89PNG\r\n\x1a\n':
        raise RuntimeError('Missing native screenshot: ' + name)
print('Documentation screenshots ready:', args.output)
