#!/usr/bin/env python3
"""Exercise the signed native app in isolated state; never use the live gateway or tunnel."""
import argparse
import json
import os
import pathlib
import select
import shutil
import socket
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=pathlib.Path, required=True)
parser.add_argument("--executable", type=pathlib.Path, help="Test a freshly built executable with the app’s resources")
parser.add_argument("--dependencies", type=pathlib.Path, required=True)
parser.add_argument("--npm", action="store_true", help="Audit and run the exact-version reference filesystem server")
parser.add_argument("--github", action="store_true", help="Read-only account lookup and authenticated push dry-run")
args = parser.parse_args()
exe = args.executable or args.app / "Contents/MacOS/Sideport"
base = pathlib.Path(tempfile.mkdtemp(prefix="sideport-integration-", dir="/private/tmp"))
root, project = base / "controller", base / "project"
project.mkdir()
if args.executable:
    runtime = base / "native-runtime"
    runtime.mkdir()
    shutil.copy2(args.executable, runtime / "Sideport")
    exe = runtime / "Sideport"
env = dict(os.environ, SIDEPORT_HOME=str(root), SIDEPORT_WORKSPACE=str(project), SIDEPORT_APP_EXECUTABLE=str(exe), SIDEPORT_RESOURCES=str(args.app / "Contents/Resources"))
processes = []

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))
    path.chmod(0o600)

def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, timeout=90, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stderr[-2500:] or result.stdout[-2500:])
    return result.stdout + result.stderr

class Broker:
    def __init__(self, session):
        self.session = session
        self.proc = subprocess.Popen([str(exe), "--broker"], env=dict(env, MAC_CHATGPT_APPROVAL_DIR=str(session)),
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        processes.append(self.proc)
        self.next_id = 0
    def request(self, method, params, approval=None, timeout=60):
        self.next_id += 1
        packet = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}
        self.proc.stdin.write(json.dumps(packet) + "\n")
        self.proc.stdin.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if approval:
                for request in self.session.glob("*.capability.json"):
                    value = json.loads(request.read_text())
                    assert value["capability"] == approval, "Unexpected synthetic approval"
                    write(request.with_name(value["id"] + ".decision.json"), {"id": value["id"], "capability": approval, "approved": True})
            if select.select([self.proc.stdout], [], [], 0.05)[0]:
                line = self.proc.stdout.readline()
                assert line, "Broker stopped unexpectedly"
                response = json.loads(line)
                assert response["id"] == self.next_id, "MCP response id mismatch"
                assert "error" not in response, response.get("error")
                return response["result"]
        raise RuntimeError("Native broker timed out")
    def call(self, name, arguments, approval=None):
        return self.request("tools/call", {"name": name, "arguments": arguments}, approval, timeout=300 if name=="request_server" else 60)
    def stop(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)

def content(result):
    assert not result.get("isError"), result
    return json.loads(result["content"][0]["text"])

try:
    run([str(exe), "--bundle-check"], env=env)
    session = root / "work/permission-sessions" / str(uuid.uuid4())
    session.mkdir(mode=0o700)
    write(session / "grants.json", [{"path": str(project), "kind": "directory", "access": "read_write"}])
    sentinel = root / "work/controller-test.key"
    sentinel.write_text("SYNTHETIC-CONTROLLER-SENTINEL")
    broker = Broker(session)
    assert "2026-07-28" in broker.request("server/discover", {})["supportedVersions"]
    assert len(broker.request("tools/list", {})["tools"]) == 16
    assert content(broker.call("allowed_locations", {}))[0]["path"] == str(project)
    payload = "完整 file write\n" * 12000
    destination = project / "large.txt"
    assert content(broker.call("write_file", {"path": str(destination), "content": payload}))["written_bytes"] == len(payload.encode())
    assert content(broker.call("read_file", {"path": str(destination)}))["content"] == payload
    assert broker.call("read_file", {"path": str(sentinel)})["isError"]
    symlink = project / "secret-link"
    symlink.symlink_to(sentinel)
    assert broker.call("read_file", {"path": str(symlink)})["isError"]
    shell = content(broker.call("run_shell", {"cwd": str(project), "command": "printf shell-ok"}))
    assert shell["stdout"] == "shell-ok", shell
    denied = broker.call("run_shell", {"cwd": str(project), "command": "cat " + str(sentinel)})
    assert denied.get("isError") and "SYNTHETIC-CONTROLLER-SENTINEL" not in json.dumps(denied)
    assert broker.call("computer_action", {"tool": "see", "arguments": {}})["isError"]
    assert broker.call("request_remote_server", {"url": "https://127.0.0.1/mcp", "reason": "Synthetic test"})["isError"]
    print("PASS: July discovery, 16 tools, complete UTF-8 writes, symlink/controller isolation, shell and computer approval gate", flush=True)

    provider_script = project / "provider.py"
    provider_script.write_text('''import sys,json
for line in sys.stdin:
 m=json.loads(line)
 if "id" not in m: continue
 if m["method"]=="server/discover": r={"supportedVersions":["2026-07-28"]}
 elif m["method"]=="tools/list": r={"tools":[{"name":"ping","description":"Fixture","inputSchema":{"type":"object","properties":{}}}]}
 else: r={"content":[{"type":"text","text":"fixture-ok"}]}
 print(json.dumps({"jsonrpc":"2.0","id":m["id"],"result":r}),flush=True)
''')
    python = shutil.which("python3")
    write(project / ".agents/agents.json", {"mcp": {"servers": {"fixture": {"command": python, "args": [str(provider_script)], "cwd": str(project)}}}})
    write(project / ".agents/local.json", {"mcpServers": {"fixture": {"env": {"TEST_ONLY_SECRET": "SYNTHETIC-MANAGER-SECRET"}}}})
    listed = content(broker.call("managed_servers", {"manager": "agents", "project": str(project)}))
    assert listed[0]["name"] == "fixture" and "SYNTHETIC-MANAGER-SECRET" not in json.dumps(listed)
    admitted = content(broker.call("request_managed_server", {"manager": "agents", "name": "fixture", "project": str(project), "reason": "Synthetic isolated forwarding check"}, "managed_server"))
    result = broker.call("call_server_tool", {"id": admitted["id"], "tool": "ping", "arguments": {}})
    assert result["content"][0]["text"] == "fixture-ok", result
    assert content(broker.call("stop_server", {"id": admitted["id"]}))["status"] == "stopped"
    print("PASS: native agents-dev forwarding, redacted discovery, tool calls and provider shutdown", flush=True)

    if args.npm:
        # The optional runtime is borrowed only for this isolated test, never packaged.
        (root / "work/node").symlink_to(args.dependencies / "node", target_is_directory=True)
        admitted = content(broker.call("request_server", {"package": "@modelcontextprotocol/server-filesystem", "version": "2026.8.31", "args": [str(project)], "reason": "Synthetic isolated filesystem-provider check"}, "npm_server"))
        assert any(tool["name"]=="list_allowed_directories" for tool in admitted["tools"])
        listing = broker.call("call_server_tool", {"id": admitted["id"], "tool": "list_allowed_directories", "arguments": {}})
        assert not listing.get("isError") and str(project) in json.dumps(listing), listing
        restricted = broker.call("call_server_tool", {"id": admitted["id"], "tool": "read_file", "arguments": {"path": str(sentinel)}})
        assert restricted.get("isError") and "SYNTHETIC-CONTROLLER-SENTINEL" not in json.dumps(restricted), restricted
        assert content(broker.call("stop_server", {"id": admitted["id"]}))["status"]=="stopped"
        print("PASS: audited exact-version npm provider, legacy MCP fallback, approved-folder use and controller refusal", flush=True)

    if args.github:
        read = content(broker.call("run_github", {"cwd": str(project), "args": ["api", "user", "--jq", ".login"]}))
        assert read["stdout"].strip() == "anschmieg", read
        assert broker.call("run_github", {"cwd": str(project), "args": ["auth", "token"]})["isError"]
        restricted = broker.call("run_github", {"cwd": str(project), "args": ["api", "user", "--method", "GET", "--input", str(sentinel)]})
        assert restricted.get("isError") and "SYNTHETIC-CONTROLLER-SENTINEL" not in json.dumps(restricted)
        repositories = content(broker.call("run_github", {"cwd": str(project), "args": ["api", "user/repos?type=owner&per_page=100", "--jq", '.[] | select(.owner.login == "anschmieg" and .permissions.push == true) | .full_name']}))
        owned = repositories["stdout"].strip().splitlines()[0]
        assert owned.startswith("anschmieg/") and all(c.isalnum() or c in "/._-" for c in owned)
        git_env = dict(env, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="Sideport fixture", GIT_AUTHOR_EMAIL="test@localhost", GIT_COMMITTER_NAME="Sideport fixture", GIT_COMMITTER_EMAIL="test@localhost")
        for command in [["init", "--quiet"], ["commit", "--quiet", "--allow-empty", "-m", "Local fixture"], ["remote", "add", "origin", "https://github.com/" + owned + ".git"]]:
            run(["/usr/bin/git"] + command, cwd=project, env=git_env)
        push = content(broker.call("run_github", {"cwd": str(project), "args": ["git", "push", "--dry-run", "origin", "HEAD:refs/heads/sideport-native-auth-check-do-not-create"]}))
        assert push["exit_code"] == 0, push
        print("PASS: Keychain GitHub account read, token-export refusal, controller-key isolation and HTTPS push dry-run; no remote writes", flush=True)
    broker.stop()

    config_path = root / "work/mcpproxy-pilot/config.json"
    config = json.loads(config_path.read_text())
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    config["listen"] = "127.0.0.1:" + str(port)
    write(config_path, config)
    (root / "work/tunnel-runtime.key").write_text("SYNTHETIC-NOT-A-CREDENTIAL")
    output = run([str(exe), "--toggle-smoke-test-local"], env=env)
    assert "switch actions connected and disconnected" in output, output
    assert not (root / "work/mcpproxy-runtime.key").exists()
    cancelled = run([str(exe), "--cancel-connect-smoke-local"], env=env)
    assert "switch actions connected and disconnected" in cancelled, cancelled
    assert not (root / "work/mcpproxy-runtime.key").exists()
    forced = subprocess.Popen([str(exe), "--permission-test-local"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    processes.append(forced)
    deadline = time.monotonic()+20
    while time.monotonic()<deadline:
        try:
            connection=socket.create_connection(("127.0.0.1",port),timeout=0.2)
            connection.close()
            break
        except OSError:
            time.sleep(0.1)
    else:
        raise RuntimeError("Guarded local service did not start")
    (root / "work/mcpproxy-runtime.key").write_text("SYNTHETIC-FORCE-QUIT-CREDENTIAL")
    forced.kill()
    forced.wait(timeout=10)
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        try:
            connection=socket.create_connection(("127.0.0.1",port),timeout=0.2)
            connection.close()
            still_open=True
        except OSError:
            still_open=False
        if not still_open and not (root / "work/mcpproxy-runtime.key").exists():
            break
        time.sleep(0.1)
    assert not still_open and not (root / "work/mcpproxy-runtime.key").exists(), "Force-quit must close the service and remove its credential"
    print("PASS: force-quit closes owned service and removes connection credential",flush=True)
    print("PASS: native tray switch connects and disconnects isolated gateway; no tunnel started, permissions/timers cleared", flush=True)
finally:
    for process in processes:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
    shutil.rmtree(base, ignore_errors=True)
