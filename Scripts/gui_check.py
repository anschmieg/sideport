#!/usr/bin/env python3
"""Run only a disposable signed-app GUI fixture; retain its concise report."""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import fcntl
import stat

p=argparse.ArgumentParser()
p.add_argument('--app',type=pathlib.Path,required=True)
p.add_argument('--report',type=pathlib.Path,required=True)
p.add_argument('--interactive',action='store_true',help='Required: run only with the person present to handle any macOS screen-access prompt')
p.add_argument('--request-permissions',action='store_true',help='Explicitly request missing native permissions once; default only checks existing permission')
a=p.parse_args()
if not a.interactive:
    p.error('GUI auditing requires --interactive and a person present at the Mac; it may show a native screen-access prompt')
lease_fd=os.open('/private/tmp/sideport-gui-audit.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
lease_info=os.fstat(lease_fd)
if lease_info.st_uid!=os.getuid() or not stat.S_ISREG(lease_info.st_mode) or lease_info.st_nlink!=1:
    os.close(lease_fd)
    raise SystemExit('Unsafe GUI audit lock; no UI actions were started')
lease=os.fdopen(lease_fd,'a')
try:
    fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit('Another Sideport GUI audit is already running; concurrent screen-access tests are refused')
audit_home=pathlib.Path('/private/tmp/sideport-gui-audit-'+str(os.getuid()))
audit_home.mkdir(mode=0o700,exist_ok=True)
home_info=audit_home.lstat()
if home_info.st_uid!=os.getuid() or not stat.S_ISDIR(home_info.st_mode) or home_info.st_mode&0o077:
    raise SystemExit('Unsafe GUI audit directory; no UI actions were started')
audit_app=audit_home/'Sideport.app'
if audit_app.is_symlink():
    raise SystemExit('Unsafe GUI audit app link; no UI actions were started')
if audit_app.exists():shutil.rmtree(audit_app)
shutil.copytree(a.app,audit_app)
a.app=audit_app
root=pathlib.Path(tempfile.mkdtemp(prefix='sideport-gui-controller-',dir='/private/tmp'))
log=root/'gui-report.txt'
try:
    environment=dict(os.environ,SIDEPORT_HOME=str(root),SIDEPORT_RESOURCES=str(a.app/'Contents/Resources'))
    result=subprocess.run([str(a.app/'Contents/MacOS/Sideport'),'--bundle-check'],env=environment,capture_output=True,text=True,timeout=30)
    if result.returncode: raise RuntimeError(result.stderr)
    modes=['--gui-check']+(['--gui-request-permissions'] if a.request_permissions else [])
    subprocess.run(['/usr/bin/open','-n','-W',str(a.app),'--env','SIDEPORT_HOME='+str(root),'--env','SIDEPORT_RESOURCES='+str(a.app/'Contents/Resources'),'-o',str(log),'--stderr',str(log),'--args',*modes],capture_output=True,text=True,timeout=150,check=True)
    text=log.read_text() if log.exists() else 'GUI app did not produce a report'
    a.report.write_text(text)
    print(text[-5000:])
    if 'PASS: kernel refusal of screen capture and Accessibility' not in text: raise RuntimeError('GUI validation failed; see '+str(a.report))
finally:
    shutil.rmtree(root,ignore_errors=True)
