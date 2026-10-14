#!/usr/bin/env python3
"""Build a local signed Sideport app without packaging controller state or JS runtimes."""
import argparse
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
from signing import unlock

REPO = pathlib.Path(__file__).resolve().parents[1]
VERSION = "0.3.4"
p = argparse.ArgumentParser()
p.add_argument("--dependencies", type=pathlib.Path, required=True, help="Existing trusted Sideport work directory")
p.add_argument("--tunnel-runtime", type=pathlib.Path, required=True, help="Verified official runtime-only tunnel release directory")
p.add_argument("--signing", type=pathlib.Path, help="Private local signing identity JSON; never included in output")
p.add_argument("--output", type=pathlib.Path, required=True)
p.add_argument("--audit-only", action="store_true", help="Build/sign/test a private audit app; never export a release ZIP")
args = p.parse_args()
readiness = json.loads((REPO / "docs/audits/release-readiness.json").read_text())
if readiness["blockers"] and not args.audit_only:
    raise SystemExit("Release packaging is held: " + "; ".join(readiness["blockers"]) + " See " + readiness["report"])

def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, timeout=600, **kwargs)
    if result.returncode:
        raise RuntimeError((result.stdout + result.stderr)[-4000:])
    return result.stdout

run(["/usr/bin/xcrun", "swift", "build", "--build-system", "native", "-c", "release"], cwd=REPO)
run([str(REPO / ".build/release/Sideport"), "--regression-tests"], cwd=REPO)
stage = pathlib.Path(tempfile.mkdtemp(prefix="sideport-native-package-", dir="/private/tmp"))
app = stage / "Sideport.app"
contents = app / "Contents"
resources = contents / "Resources"
(contents / "MacOS").mkdir(parents=True)
resources.mkdir()
shutil.copy2(REPO / ".build/release/Sideport", contents / "MacOS/Sideport")
for asset in ["Sideport.icns", "Tools.json", "BuildLocations.json", "config-template.json", "Getting started.md", "connection-setup.md"]:
    source = REPO / "docs/getting-started.md" if asset == "Getting started.md" else REPO / "docs/connection-setup.md" if asset == "connection-setup.md" else REPO / "Resources" / asset
    shutil.copy2(source, resources / asset)
work = resources / "Runtime/work"
work.mkdir(parents=True)
for directory, binary in [("mcpproxy-bin", "mcpproxy"), ("nono-bin", "nono"), ("permission-broker", "dcg")]:
    destination = work / directory
    destination.mkdir()
    source = args.dependencies / directory
    if not any(item.is_file() and any(term in item.name.lower() for term in ["license", "notice", "copying"]) for item in source.iterdir()):
        raise RuntimeError("Upstream runtime license/notice missing: " + directory)
    shutil.copy2(source / binary, destination / binary)
    for item in source.iterdir():
        if item.is_file() and any(term in item.name.lower() for term in ["license", "notice", "copying", "spdx"]):
            shutil.copy2(item, destination / item.name)
(work / "tunnel-client").mkdir()
if not any(item.is_file() and "license" in item.name.lower() for item in args.tunnel_runtime.iterdir()):
    raise RuntimeError("Official runtime-only tunnel license bundle missing")
shutil.copy2(args.tunnel_runtime / "tunnel-client-runtime", work / "tunnel-client/tunnel-client")
for item in args.tunnel_runtime.iterdir():
    if item.is_file() and item.name != "tunnel-client-runtime":
        shutil.copy2(item, work / "tunnel-client" / item.name)
for metadata in ["mcpproxy-release.json", "nono-release.json", "tunnel-release.json", "dcg-release.json"]:
    source = args.dependencies / metadata
    if not source.exists() and metadata == "dcg-release.json":
        source = REPO.parent / "work/sideport-0.1.2/dcg-release.json"
    shutil.copy2(source, work / metadata)
licenses = resources / "Licenses"
licenses.mkdir()
shutil.copy2(REPO / "LICENSE", licenses / "Sideport.txt")
for name in ["Peekaboo", "AXorcist", "Commander", "swift-log", "swift-algorithms", "swift-numerics"]:
    checkout = REPO / ".build/checkouts" / name
    candidates = [checkout / "LICENSE", checkout / "LICENSE.txt"]
    source = next((x for x in candidates if x.is_file()), None)
    if source:
        shutil.copy2(source, licenses / (name + ".txt"))
info = {"CFBundleName": "Sideport", "CFBundleDisplayName": "Sideport", "CFBundleExecutable": "Sideport",
        "CFBundleIdentifier": "local.adrian.mac-chatgpt.mcpproxy", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": VERSION, "CFBundleVersion": "14", "CFBundleIconFile": "Sideport",
        "LSUIElement": True, "LSMinimumSystemVersion": "15.0",
        "NSAppleEventsUsageDescription": "Sideport lets approved remote agents interact with apps on this Mac."}
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
for binary in [contents / "MacOS/Sideport", *(work / d / b for d, b in [("mcpproxy-bin", "mcpproxy"), ("nono-bin", "nono"), ("permission-broker", "dcg"), ("tunnel-client", "tunnel-client")])]:
    binary.chmod(0o755)
for path in app.rglob("*"):
    if path.is_file():
        path.chmod(path.stat().st_mode | 0o200)
run(["/usr/bin/xattr", "-cr", str(app)])
for binary in work.glob("*/*"):
    if binary.read_bytes()[:4].hex() in {"cffaedfe", "cafebabe", "feedfacf", "bebafeca"}:
        run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "restrict,runtime", "--timestamp=none", str(binary)])
if args.signing:
    identity = json.loads(args.signing.read_text())
    try:
        unlock(identity)
        run(["/usr/bin/codesign", "--force", "--sign", identity["identity"], "--keychain", identity["keychain"],
             "--requirements", "=" + identity["requirement"], "--options", "restrict,runtime", "--timestamp=none", str(app)])
    except RuntimeError as error:
        raise RuntimeError(str(error).replace(identity["password"], "[redacted]")) from None
else:
    run(["/usr/bin/codesign", "--force", "--sign", "-", "--options", "restrict,runtime", "--timestamp=none", str(app)])
run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(app)])
state = stage / "isolated-state"
env = dict(os.environ, SIDEPORT_HOME=str(state))
run([str(contents / "MacOS/Sideport"), "--bundle-check"], env=env)
run([str(contents / "MacOS/Sideport"), "--self-check"], env=env)
run([str(contents / "MacOS/Sideport"), "--off-check"], env=env)
for path in app.rglob("*"):
    if path.name in {"node", "npm", "cloudflared", "peekaboo", "tunnel-runtime.key", "identity.json"} or path.suffix == ".mjs":
        raise RuntimeError("Unexpected runtime or private state in app: " + path.name)
args.output.parent.mkdir(parents=True, exist_ok=True)
if args.audit_only:
    report = {"version": VERSION, "app": str(app), "release_status": readiness["status"],
              "blockers": readiness["blockers"], "zip": None}
    args.output.with_suffix(".build.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(0)
run(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent", str(app), str(args.output)])
files = [x for x in app.rglob("*") if x.is_file()]
report = {"version": VERSION, "app": str(app), "zip": str(args.output),
          "installed_bytes": sum(x.stat().st_size for x in files), "zip_bytes": args.output.stat().st_size,
          "binaries": {x.name: x.stat().st_size for x in files if os.access(x, os.X_OK)},
          "sha256": hashlib.sha256(args.output.read_bytes()).hexdigest()}
args.output.with_suffix(".build.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
