#!/usr/bin/env python3
"""Exercise the signed native app in isolated state; never use the live gateway or tunnel."""
import argparse
import json
import os
import pathlib
import select
import shutil
import socket
import shlex
import threading
import signal
import subprocess
import tempfile
import time
import uuid
import urllib.request
import urllib.error

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=pathlib.Path, required=True)
parser.add_argument("--executable", type=pathlib.Path, help="Test a freshly built executable with the app’s resources")
parser.add_argument("--dependencies", type=pathlib.Path, required=True)
parser.add_argument("--npm", action="store_true", help="Audit and run the exact-version reference filesystem server")
parser.add_argument("--audit-detach", action="store_true", help="Probe deliberate double-fork detachment; always clean up the fixture")
parser.add_argument("--download-runtime", action="store_true", help="Test fresh optional Node acquisition instead of borrowing the legacy runtime")
parser.add_argument("--smithery", action="store_true", help="Read existing Smithery connections and forwarded tool schemas; no remote tool is executed")
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
detachment_exposed = False

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
    escaped = project / "escaped.txt"
    escaped_text = "\\" * 524288
    assert content(broker.call("write_file", {"path": str(escaped), "content": escaped_text}))["written_bytes"] == len(escaped_text)
    assert content(broker.call("read_file", {"path": str(escaped)}))["content"] == escaped_text
    prefix_file = project / "over-limit.txt"
    prefix_file.write_text("x" * 1100000)
    prefix = content(broker.call("read_file", {"path": str(prefix_file)}))
    assert len(prefix["content"]) == 1048576 and prefix["truncated"] is True
    assert any(entry["name"] == "large.txt" and not entry["directory"] for entry in content(broker.call("list_directory", {"path": str(project)}))["entries"])
    assert broker.call("read_file", {"path": str(sentinel)})["isError"]
    symlink = project / "secret-link"
    symlink.symlink_to(sentinel)
    assert broker.call("read_file", {"path": str(symlink)})["isError"]
    shell = content(broker.call("run_shell", {"cwd": str(project), "command": "printf shell-ok"}))
    assert shell["stdout"] == "shell-ok", shell
    denied = broker.call("run_shell", {"cwd": str(project), "command": "cat " + str(sentinel)})
    assert denied.get("isError") and "SYNTHETIC-CONTROLLER-SENTINEL" not in json.dumps(denied)
    # A broad approved parent must not make the broker’s own executable writable.
    write(session / "grants.json", [{"path": str(project), "kind": "directory", "access": "read_write"},
                                    {"path": str(exe.parent if args.executable else args.app.parent), "kind": "directory", "access": "read_write"}])
    assert broker.call("write_file", {"path": str(exe), "content": "BROKER-REPLACEMENT"})["isError"]
    frozen = list((root / "work/host-tools").glob("*/gh"))
    if frozen:
        rejected = broker.call("run_shell", {"cwd": str(project), "command": "printf BAD > " + shlex.quote(str(frozen[0]))})
        assert rejected["isError"], rejected
    write(session / "grants.json", [{"path": str(project), "kind": "directory", "access": "read_write"}])
    alias = project / "hardlink"
    os.link(destination, alias)
    assert broker.call("write_file", {"path": str(alias), "content": "REPLACEMENT"})["isError"]
    assert destination.read_text() == payload
    alias.unlink()
    # Read-only sandbox probes for Unix sockets, including sockets in approved scope.
    socket_path = str(project / "admin-probe.sock")
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(socket_path)
    listener.listen(1)
    listener.settimeout(1)
    def serve_probe():
        try:
            conn, _ = listener.accept()
            with conn: conn.sendall(b"SYNTHETIC-ADMIN-SOCKET")
        except (TimeoutError, OSError): pass
    thread = threading.Thread(target=serve_probe, daemon=True)
    thread.start()
    probe = project / "socket-probe.py"
    probe.write_text("import socket\ns=socket.socket(socket.AF_UNIX);s.connect(" + repr(socket_path) + ");print(s.recv(100).decode())\n")
    rejected = broker.call("run_shell", {"cwd": str(project), "command": shlex.quote(shutil.which("python3")) + " " + shlex.quote(str(probe))})
    thread.join(timeout=2)
    listener.close()
    assert "exit_code" in json.loads(rejected["content"][0]["text"]), "Socket probe must reach the kernel sandbox"
    assert rejected["isError"] and "SYNTHETIC-ADMIN-SOCKET" not in json.dumps(rejected), rejected
    stolen_link = project / "controller-hardlink"
    link_attempt = broker.call("run_shell", {"cwd": str(project), "command": "ln " + shlex.quote(str(sentinel)) + " " + shlex.quote(str(stolen_link))})
    assert "exit_code" in json.loads(link_attempt["content"][0]["text"]), "Hard-link probe must reach the kernel sandbox"
    if stolen_link.exists():
        exposure = broker.call("read_file", {"path": str(stolen_link)})
        assert "SYNTHETIC-CONTROLLER-SENTINEL" not in json.dumps(exposure), "Controller credential escaped via a hard link"
        stolen_link.unlink()
    else:
        assert link_attempt.get("isError"), "Controller hard-link creation should be denied"
    print("PASS: immutable controller/helper code, hard-linked write refusal and kernel Unix-socket isolation", flush=True)

    assert broker.call("computer_action", {"tool": "see", "arguments": {}})["isError"]
    assert broker.call("request_remote_server", {"url": "https://127.0.0.1/mcp", "reason": "Synthetic test"})["isError"]
    print("PASS: July discovery, 16 tools, complete UTF-8 writes, symlink/controller isolation, shell and computer approval gate", flush=True)

    if args.audit_detach:
        from ownership_checks import exercise
        exercise(Broker, root, project, session, write, content, shutil.which("python3"))

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
        if not args.download_runtime:
            (root / "work/node").symlink_to(args.dependencies / "node", target_is_directory=True)
        admitted = content(broker.call("request_server", {"package": "@modelcontextprotocol/server-filesystem", "version": "2026.8.31", "args": [str(project)], "reason": "Synthetic isolated filesystem-provider check"}, "npm_server"))
        assert any(tool["name"]=="list_allowed_directories" for tool in admitted["tools"])
        listing = broker.call("call_server_tool", {"id": admitted["id"], "tool": "list_allowed_directories", "arguments": {}})
        assert not listing.get("isError") and str(project) in json.dumps(listing), listing
        restricted = broker.call("call_server_tool", {"id": admitted["id"], "tool": "read_file", "arguments": {"path": str(sentinel)}})
        assert restricted.get("isError") and "SYNTHETIC-CONTROLLER-SENTINEL" not in json.dumps(restricted), restricted
        assert content(broker.call("stop_server", {"id": admitted["id"]}))["status"]=="stopped"
        # Expired cached audits must be refreshed without reinstalling the package.
        marker = next((root / "work/provider-cache").glob("*/approved-install.json"))
        cached = json.loads(marker.read_text())
        cached["audited"] = "2000-01-01T00:00:00Z"
        write(marker, cached)
        admitted = content(broker.call("request_server", {"package": "@modelcontextprotocol/server-filesystem", "version": "2026.8.31", "args": [str(project)], "reason": "Synthetic cached-advisory refresh check"}, "npm_server"))
        assert json.loads(marker.read_text())["audited"] != "2000-01-01T00:00:00Z"
        assert content(broker.call("stop_server", {"id": admitted["id"]}))["status"] == "stopped"
        print("PASS: audited exact-version npm provider, legacy MCP fallback, approved-folder use and controller refusal", flush=True)

    if args.smithery:
        listing = content(broker.call("managed_servers", {"manager":"smithery"}))
        connections = listing["servers"]
        print("PASS: live Smithery connection discovery (" + str(len(connections)) + " connections)", flush=True)
        if connections:
            admitted = content(broker.call("request_managed_server", {"manager":"smithery", "name":connections[0]["name"], "namespace":listing["namespace"], "reason":"Read-only forwarding verification; list schemas only"}, "managed_server"))
            assert isinstance(admitted["tools"], list)
            assert content(broker.call("stop_server", {"id":admitted["id"]}))["status"] == "stopped"
            print("PASS: live Smithery forwarding and tool schema discovery (no remote tool executed)", flush=True)

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
    run([str(exe), "--credential"], env=env)
    scoped = (root / "work/mcpproxy-runtime.key").read_text().strip()
    # Presence is driven by an authenticated external MCP session, not the
    # upstream broker's initialize request or the gateway's health endpoint.
    endpoint = "http://127.0.0.1:" + str(port)
    session_headers = {"X-API-Key": scoped, "Accept": "application/json, text/event-stream",
                       "Content-Type": "application/json", "MCP-Protocol-Version": "2025-11-25"}
    def external_rpc(packet):
        request = urllib.request.Request(endpoint + "/mcp", data=json.dumps(packet).encode(), headers=session_headers)
        with urllib.request.urlopen(request, timeout=15) as response:
            sid = response.headers.get("Mcp-Session-Id")
            if sid:
                session_headers["Mcp-Session-Id"] = sid
            raw = response.read().decode()
            if not raw:
                return {}
            if raw.startswith("event:") or raw.startswith("data:"):
                raw = next(line[5:].strip() for line in raw.splitlines() if line.startswith("data:"))
            return json.loads(raw)
    initialized = external_rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "Sideport indicator fixture", "version": "1"}}})
    assert "result" in initialized, "External MCP initialization failed"
    external_rpc({"jsonrpc": "2.0", "method": "notifications/initialized"})
    listed = external_rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    assert any(tool["name"]=="call_tool_read" for tool in listed["result"]["tools"]), "Read tool missing from configured gateway surface"
    deadline = time.monotonic()+20
    sequence = 3
    while True:
        called = external_rpc({"jsonrpc": "2.0", "id": sequence, "method": "tools/call", "params": {"name": "call_tool_read", "arguments": {"name": "permissions:allowed_locations", "args": {}}}})
        sequence += 1
        if not called.get("error") and not called.get("result", {}).get("isError"):
            break
        if time.monotonic()>=deadline:
            break
        time.sleep(0.5)
    assert not called.get("error") and not called.get("result", {}).get("isError"), "External tool call failed: " + json.dumps(called).replace(scoped, "[redacted]").replace(config["api_key"], "[redacted]")[:2000]
    admin_headers = {"X-API-Key": config["api_key"]}
    def active_sessions():
        request = urllib.request.Request(endpoint + "/api/v1/sessions?status=active&token=mac-chatgpt-session&limit=100", headers=admin_headers)
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.loads(response.read())["data"]["sessions"]
    sessions = active_sessions()
    assert any(row.get("client_name")=="Sideport indicator fixture" and row.get("token_name")=="mac-chatgpt-session" for row in sessions), "External session missing from presence API"
    request = urllib.request.Request(endpoint + "/mcp", method="DELETE", headers=session_headers)
    with urllib.request.urlopen(request, timeout=5) as response:
        assert response.status in (200,202,204)
    deadline = time.monotonic()+5
    while time.monotonic()<deadline and any(row.get("client_name")=="Sideport indicator fixture" for row in active_sessions()):
        time.sleep(0.1)
    assert not any(row.get("client_name")=="Sideport indicator fixture" for row in active_sessions()), "Closed session still counted as connected"
    print("PASS: authenticated MCP client presence and transport-close clearing; readiness does not imply a connected agent",flush=True)
    def denied_rest(route, method="GET", token=None):
        headers = {"Authorization": "Bearer " + token} if token else {}
        request = urllib.request.Request("http://127.0.0.1:" + str(port) + route,
                                         data=b"{}" if method=="POST" else None, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                status = response.status
        except urllib.error.HTTPError as error:
            status = error.code
        assert status in (401,403), "Privileged gateway route accepted an unprivileged request: " + str(status)
    denied_rest("/api/v1/config")
    denied_rest("/api/v1/servers/permissions/restart", method="POST", token=scoped)
    assert json.loads(config_path.read_text())["enable_socket"] is False
    assert json.loads(config_path.read_text())["enable_code_execution"] is False
    second = subprocess.run([str(exe), "--toggle-smoke-test-local"], env=env, capture_output=True, text=True, timeout=15)
    assert "SMOKE FAILED" in second.stderr and "using this controller" in second.stderr, "Second app instance must refuse the active controller"
    print("PASS: unauthenticated admin refusal, scoped-token mutation refusal, disabled admin socket/code execution and exclusive controller ownership", flush=True)
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
    if detachment_exposed:
        raise RuntimeError("Release blocker: detached agent-started code survived command completion")
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
