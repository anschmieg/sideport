"""Adversarial checks imported by integration.py; every process uses private fixture state."""
import json
import os
import pathlib
import shlex
import signal
import subprocess
import threading
import time
import uuid


def exercise(broker_factory, root, project, session, write, content, python):
    fixtures = []
    brokers = []
    workers = []

    def fixture(name, duration=0):
        script = project / (name + '.py')
        pidfile, heartbeat = project / (name + '.pid'), project / (name + '.beat')
        script.write_text('''import os,time,pathlib
p=os.fork()
if p:
 for _ in range(500):
  if pathlib.Path(%r).exists(): break
  time.sleep(.01)
 time.sleep(%r)
 os._exit(0)
os.setsid()
if os.fork(): os._exit(0)
pathlib.Path(%r).write_text(str(os.getpid()))
for n in range(400):
 pathlib.Path(%r).write_text(str(n)); time.sleep(.05)
''' % (str(pidfile), duration, str(pidfile), str(heartbeat)))
        fixtures.append((script, pidfile, heartbeat))
        return script, pidfile, heartbeat

    def command(broker, script, timeout=30):
        return broker.call('run_shell', {'cwd': str(project), 'command': shlex.quote(python) + ' ' + shlex.quote(str(script)), 'timeout_seconds': timeout})

    def running(broker, script, timeout=30):
        outcome = []
        def work():
            try: outcome.append(command(broker, script, timeout))
            except Exception as error: outcome.append(error)
        worker = threading.Thread(target=work, daemon=True)
        worker.start()
        workers.append(worker)
        return worker, outcome

    def await_started(pidfile, heartbeat):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if pidfile.exists() and heartbeat.exists(): return
            time.sleep(.02)
        raise AssertionError('Adversarial fixture must actually start')

    def stopped(heartbeat):
        time.sleep(.2)
        before = heartbeat.read_text()
        time.sleep(.3)
        assert heartbeat.read_text() == before, 'Detached fixture retained access after cleanup'

    def new_broker():
        scope = root / 'work/permission-sessions' / str(uuid.uuid4())
        scope.mkdir(mode=0o700)
        write(scope / 'grants.json', [{'path': str(project), 'kind': 'directory', 'access': 'read_write'}])
        broker = broker_factory(scope)
        brokers.append(broker)
        return broker

    def job_for(broker):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            for request in (root / 'work/owned-execution').glob('*/request.json'):
                try:
                    value = json.loads(request.read_text())
                    ready = json.loads(request.with_name('ready.json').read_text())
                    if value['origin'][5] == broker.proc.pid: return request, value, ready
                except (OSError, KeyError, ValueError): pass
            time.sleep(.02)
        raise AssertionError('Private job receipt not found')

    try:
        b = new_broker()
        script, pidfile, heartbeat = fixture('complete')
        result = content(command(b, script))
        assert result['exit_code'] == 0 and not result['stopped']
        await_started(pidfile, heartbeat)
        stopped(heartbeat)

        script, pidfile, heartbeat = fixture('timeout', 20)
        result = json.loads(command(b, script, 2)['content'][0]['text'])
        assert result['stopped'], result
        await_started(pidfile, heartbeat)
        stopped(heartbeat)

        # Kill one broker while another security session keeps working.
        first, second = new_broker(), new_broker()
        one, p1, beat1 = fixture('crash-first', 20)
        two, p2, beat2 = fixture('crash-second', 20)
        running(first, one); running(second, two)
        await_started(p1, beat1); await_started(p2, beat2)
        first.proc.kill(); first.proc.wait(timeout=10)
        stopped(beat1)
        before = beat2.read_text(); time.sleep(.2)
        assert beat2.read_text() != before, 'Cleanup killed an unrelated owned session'
        second.proc.stdin.close(); second.proc.wait(timeout=10)
        stopped(beat2)

        # The controller cleans up if its custodian unexpectedly dies.
        crash = new_broker()
        script, pidfile, heartbeat = fixture('custodian-crash', 20)
        worker, _ = running(crash, script)
        await_started(pidfile, heartbeat)
        request, _, receipt = job_for(crash)
        cmd = subprocess.run(['/bin/ps', '-p', str(receipt['pid']), '-o', 'command='], capture_output=True, text=True).stdout
        assert '--job-guard ' + str(request.parent) in cmd
        os.kill(receipt['pid'], signal.SIGKILL)
        worker.join(timeout=10)
        assert not worker.is_alive(), 'Custodian death left the controller waiting'
        stopped(heartbeat)

        # A custodian survives the controller's force-quit and cleans up itself.
        crash = new_broker()
        script, pidfile, heartbeat = fixture('controller-crash', 20)
        worker, _ = running(crash, script)
        await_started(pidfile, heartbeat)
        request, value, _ = job_for(crash)
        owner = value['owner'][5]
        cmd = subprocess.run(['/bin/ps', '-p', str(owner), '-o', 'command='], capture_output=True, text=True).stdout
        assert '--job-client ' + str(request.parent) in cmd
        os.kill(owner, signal.SIGKILL)
        worker.join(timeout=10)
        stopped(heartbeat)

        # A nested security session or launchd job would break ownership. Exercise
        # the actual OS APIs from downloaded-code-equivalent sandboxed code.
        escape = project / 'session-escape.c'
        executable = project / 'session-escape'
        marker = project / 'escape-marker'
        label = 'local.sideport.escape.' + str(uuid.uuid4())
        escape.write_text(r'''#include <Security/AuthSession.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;
extern int audit_session_port(unsigned, mach_port_t*);
unsigned session(void){audit_token_t t;mach_msg_type_number_t n=sizeof(t)/sizeof(natural_t);task_info(mach_task_self(),TASK_AUDIT_TOKEN,(task_info_t)&t,&n);return t.val[6];}
int main(int argc,char**argv){unsigned before=session();OSStatus create=SessionCreate(0,0);unsigned after=session();mach_port_t foreign=0;int join=audit_session_port(atoi(argv[1]),&foreign);int denied=errno;
char*args[]={"/bin/launchctl","submit","-l",argv[2],"--","/usr/bin/touch",argv[3],NULL};pid_t child;int status=-1;if(!posix_spawn(&child,args[0],NULL,NULL,args,environ))waitpid(child,&status,0);
printf("{\"before\":%u,\"after\":%u,\"create\":%d,\"foreign\":%d,\"errno\":%d,\"job\":%d}\n",before,after,create,join,denied,status);return 0;}
''')
        subprocess.run(['/usr/bin/cc', str(escape), '-framework', 'Security', '-o', str(executable)], check=True, capture_output=True, timeout=30)
        # Capture a foreign ASID from the host without querying another user's state.
        host_script = project / 'host-session.py'
        host_script.write_text('''import ctypes,json
m=ctypes.CDLL('/usr/lib/libSystem.B.dylib');t=(ctypes.c_uint*8)();n=ctypes.c_uint(8);m.task_info(m.mach_task_self(),15,t,ctypes.byref(n));print(t[6])
''')
        host_asid = subprocess.check_output([python, str(host_script)], text=True).strip()
        b = new_broker()
        out = content(b.call('run_shell', {'cwd':str(project), 'command':shlex.quote(str(executable))+' '+host_asid+' '+shlex.quote(label)+' '+shlex.quote(str(marker))}))
        decision = json.loads(out['stdout'])
        assert decision['before'] == decision['after'] and decision['create'] != 0, decision
        assert decision['foreign'] == -1 and decision['errno'] != 0, decision
        time.sleep(.3)
        assert decision['job'] != 0 and not marker.exists(), 'Sandboxed code escaped through launchd'
        subprocess.run(['/bin/launchctl', 'remove', label], capture_output=True)
        # A downloaded child must not kill all of its trusted cleanup watchers.
        # SIGCONT is harmless to the host positive-control sleeper. A sibling
        # created in the sandbox must remain signalable for ordinary tool use.
        protected = subprocess.Popen(['/bin/sleep', '20'])
        signal_probe = project / 'signal-probe.py'
        signal_probe.write_text('''import os,signal,subprocess,json,sys
host=False
try: os.kill(int(sys.argv[1]),signal.SIGCONT);host=True
except PermissionError: pass
child=subprocess.Popen(['/bin/sleep','20'])
os.kill(child.pid,signal.SIGTERM);child.wait(timeout=5)
print(json.dumps({'host_signal':host,'child_signal':child.returncode==-signal.SIGTERM}))
''')
        try:
            os.kill(protected.pid, signal.SIGCONT)
            out=content(b.call('run_shell',{'cwd':str(project),'command':shlex.quote(python)+' '+shlex.quote(str(signal_probe))+' '+str(protected.pid)}))
            decision=json.loads(out['stdout'])
            assert decision == {'host_signal':False,'child_signal':True}, decision
        finally:
            protected.terminate();protected.wait(timeout=5)
        print('PASS: double-fork completion, timeout, broker crash/EOF, controller/custodian crashes, concurrent-session isolation and security-session/job escape refusal', flush=True)
        print('PASS: sandbox signals refused to trusted host processes and allowed to sandbox children',flush=True)
    finally:
        if 'label' in locals(): subprocess.run(['/bin/launchctl', 'remove', label], capture_output=True)
        for broker in brokers:
            if broker.proc.poll() is None:
                broker.proc.terminate()
                try: broker.proc.wait(timeout=10)
                except subprocess.TimeoutExpired: broker.proc.kill(); broker.proc.wait(timeout=10)
        for script, pidfile, _ in fixtures:
            if pidfile.exists():
                pid = int(pidfile.read_text())
                name = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout
                if str(script) in name:
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
        for worker in workers: worker.join(timeout=1)
