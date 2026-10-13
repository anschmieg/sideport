import AppKit
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

private enum RegressionReport {
  static var failures = 0
  static func fail(_ text: String) {
    failures += 1
    FileHandle.standardError.write(Data(("CHECK FAILED: " + text + "\n").utf8))
  }
}
private func assertTrue(
  _ value: Bool, _ label: String = "", file: StaticString = #fileID, line: UInt = #line
) { if !value { RegressionReport.fail("\(file):\(line) \(label)") } }
private func assertFalse(
  _ value: Bool, _ label: String = "", file: StaticString = #fileID, line: UInt = #line
) { assertTrue(!value, label, file: file, line: line) }
private func assertEqual<T: Equatable>(
  _ left: T, _ right: T, file: StaticString = #fileID, line: UInt = #line
) { assertTrue(left == right, "Expected equality", file: file, line: line) }
private func assertNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) {
  assertTrue(value == nil, "Expected nil", file: file, line: line)
}
private func assertLessThan<T: Comparable>(
  _ left: T, _ right: T, file: StaticString = #fileID, line: UInt = #line
) { assertTrue(left < right, "Exceeded bound", file: file, line: line) }
private func assertAtMost<T: Comparable>(
  _ left: T, _ right: T, file: StaticString = #fileID, line: UInt = #line
) { assertTrue(left <= right, "Exceeded bound", file: file, line: line) }
private func assertRefused<T>(
  _ operation: @autoclosure () throws -> T, file: StaticString = #fileID, line: UInt = #line
) {
  do {
    _ = try operation()
    RegressionReport.fail("\(file):\(line) Expected refusal")
  } catch {}
}

final class SecurityTests {
  func testGitHubPolicy() throws {
    assertFalse(try GitHubPlan(["pr", "list"]).approval)
    assertFalse(try GitHubPlan(["issue", "comment", "1", "--body", "hello"]).approval)
    assertTrue(try GitHubPlan(["repo", "delete", "owner/repo"]).approval)
    assertTrue(try GitHubPlan(["api", "graphql"]).approval)
    assertTrue(try GitHubPlan(["api", "repos/owner/repo", "-X", "DELETE"]).approval)
    for args in [
      ["auth", "token"], ["auth", "status", "--show-token"], ["api", "https://evil.example"],
      ["pr", "view", "--web"], ["extension", "exec", "anything"],
      ["pr", "create", "--title", "title", "--body", "body"],
    ] { assertRefused(try GitHubPlan(args)) }
  }
  func testPushPolicy() throws {
    assertFalse(
      try GitHubPlan(["git", "push", "--dry-run", "origin", "HEAD:refs/heads/work"]).approval)
    assertTrue(try GitHubPlan(["git", "push", "origin", "HEAD:refs/heads/main"]).approval)
    assertTrue(
      try GitHubPlan(["git", "push", "--force", "origin", "HEAD:refs/heads/work"]).approval)
    for args in [
      ["git", "push", "origin"], ["git", "push", "--all", "origin", "HEAD:refs/heads/work"],
      ["git", "push", "https://github.com/o/r", "HEAD:refs/heads/work"],
      ["git", "push", "origin", "HEAD:refs/heads/../main"],
    ] { assertRefused(try GitHubPlan(args)) }
  }
  func testSimpleGitHubDoesNotEvaluateShell() throws {
    assertEqual(
      try GitHubPlan.simple("gh pr comment 1 --body 'hello there'"),
      ["pr", "comment", "1", "--body", "hello there"])
    assertNil(try GitHubPlan.simple("cargo check"))
    for value in [
      "gh auth status; cat key", "gh pr list | cat", "gh api $(cat key)",
      "gh pr list\nrm -rf project",
    ] { assertRefused(try GitHubPlan.simple(value)) }
  }
  func testUncertainReviewAlwaysAsks() throws {
    func answer(_ choice: String, _ confidence: Double, _ probabilities: [String: Double])
      -> JSONObject
    {
      [
        "answers": [
          "execution": [
            "type": "choice", "choice": choice, "confidence": confidence,
            "probabilities": probabilities,
          ]
        ]
      ]
    }
    assertEqual(
      try CommandSafety.decision(
        answer("approve", 1, ["approve": 0.7, "reject": 0.1, "user": 0.2]), threshold: 0.9)[
          "decision"] as? String, "user")
    assertEqual(
      try CommandSafety.decision(
        answer("reject", 0.5, ["approve": 0, "reject": 0.99, "user": 0.01]), threshold: 0.9)[
          "decision"] as? String, "user")
    assertEqual(
      try CommandSafety.decision(
        answer("approve", 0.99, ["approve": 0.99, "reject": 0, "user": 0.01]), threshold: 0.9)[
          "decision"] as? String, "approve")
    assertRefused(
      try CommandSafety.decision(
        answer("approve", 1, ["approve": 0.1, "reject": 0.9, "user": 0]), threshold: 0.9))
  }
  func testRemoteSafety() throws {
    for address in [
      "127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1",
      "198.18.0.1", "::1", "::ffff:127.0.0.1", "fc00::1", "2001:db8::1",
    ] { assertFalse(RemoteEndpoint.publicAddress(address), address) }
    assertTrue(RemoteEndpoint.publicAddress("8.8.8.8"))
    assertTrue(RemoteEndpoint.publicAddress("2606:4700:4700::1111"))
    for url in [
      "http://example.com/mcp", "https://user:password@example.com/mcp",
      "https://example.com/mcp?token=x", "https://example.com:8443/mcp",
      "https://example.com/mcp#fragment",
    ] { assertRefused(try RemoteEndpoint(url)) }
    assertRefused(try RemoteEndpoint("https://127.0.0.1/mcp").resolve())
  }
  func testPackageAdmission() throws {
    assertEqual(
      try NativeProviders.packageSpec("@example/server", "1.2.3"), "@example/server@1.2.3")
    for pair in [
      ("package", "latest"), ("https://evil.example/pkg", "1.2.3"), ("../package", "1.2.3"),
      ("package", "^1.2.3"),
    ] { assertRefused(try NativeProviders.packageSpec(pair.0, pair.1)) }
    assertRefused(
      try NativeProviders.validateTools([
        ["name": "same", "inputSchema": ["type": "object"]],
        ["name": "same", "inputSchema": ["type": "object"]],
      ]))
  }
  func testBoundedProcessOutputAndTimeout() async throws {
    let runner = ChildSupervisor()
    let env = ["PATH": "/usr/bin:/bin"]
    let success = try await runner.run(
      "/bin/bash", ["-c", "printf ok"], environment: env, cwd: "/private/tmp")
    assertEqual(success.code, 0)
    assertEqual(String(decoding: success.stdout, as: UTF8.self), "ok")
    assertEqual(runner.count, 0)
    let started = Date()
    let timeout = try await runner.run(
      "/bin/bash", ["-c", "sleep 20"], environment: env, cwd: "/private/tmp", timeout: 0.2)
    assertTrue(timeout.stopped)
    assertLessThan(Date().timeIntervalSince(started), 3)
    assertEqual(runner.count, 0)
    let flood = try await runner.run(
      "/usr/bin/yes", [], environment: env, cwd: "/private/tmp", timeout: 2, limit: 1024)
    assertTrue(flood.stopped)
    assertAtMost(flood.stdout.count + flood.stderr.count, 1024)
  }
  func testShutdownRefusesLateExecution() async throws {
    let supervisor = ChildSupervisor()
    supervisor.shutdown()
    do {
      _ = try await supervisor.run("/usr/bin/true", [], environment: [:], cwd: "/private/tmp")
      RegressionReport.fail("Closed execution controller admitted a new process")
    } catch { assertTrue(error.localizedDescription.contains("closed")) }
    assertEqual(supervisor.count, 0)
  }
  func testShortRPCMessages() async throws {
    let python = ["/opt/homebrew/bin/python3", "/usr/bin/python3"].first(
      where: FileManager.default.isExecutableFile)!
    let code =
      "import sys,json\nfor line in sys.stdin:\n m=json.loads(line); print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':{'supportedVersions':['2026-07-28'],'tools':[]}}),flush=True)"
    let supervisor = ChildSupervisor()
    let peer = try StdioPeer(
      supervisor, python, ["-u", "-c", code], environment: ["PATH": "/usr/bin:/bin"],
      cwd: "/private/tmp")
    defer { peer.close() }
    try await peer.connect()
    assertEqual(peer.version, "2026-07-28")
    let response = try await peer.request("tools/list", [:], timeout: 2)
    assertEqual((response["tools"] as? [Any])?.count, 0)
  }
  func testDetachedProcessCleanup() async throws {
    let python = ["/opt/homebrew/bin/python3", "/usr/bin/python3"].first(
      where: FileManager.default.isExecutableFile)!
    let code =
      "import os,time; p=os.fork(); os.setsid() if p==0 else None; print(os.getpid(),flush=True) if p==0 else None; time.sleep(20 if p==0 else 0.25)"
    let runner = ChildSupervisor()
    let start = Date()
    let output = try await runner.run(
      python, ["-c", code], environment: ["PATH": "/usr/bin:/bin"], cwd: "/private/tmp", timeout: 2)
    assertLessThan(Date().timeIntervalSince(start), 3)
    let pid = Int32(
      String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    )
    assertTrue(pid != nil)
    if let pid {
      var info = proc_bsdinfo()
      let count = proc_pidinfo(
        pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
      assertTrue(count == 0 || info.pbi_status == 5, "Detached child must exit")
    }
    assertEqual(runner.count, 0)
  }
  func testFastProcessGroupCleanup() async throws {
    let python = ["/opt/homebrew/bin/python3", "/usr/bin/python3"].first(
      where: FileManager.default.isExecutableFile)!
    let code =
      "import os,time\nr,w=os.pipe(); p=os.fork()\nif p:\n os.close(w);os.read(r,1);os._exit(0)\nos.close(r);print(os.getpid(),flush=True);os.write(w,b'x');time.sleep(20)"
    let runner = ChildSupervisor()
    let output = try await runner.run(
      python, ["-c", code], environment: ["PATH": "/usr/bin:/bin"], cwd: "/private/tmp", timeout: 2)
    let pid = Int32(
      String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    )
    assertTrue(pid != nil)
    if let pid {
      var info = proc_bsdinfo()
      let count = proc_pidinfo(
        pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
      assertTrue(
        count == 0 || info.pbi_status == 5, "Fast orphan in the owned process group must exit")
    }
    assertEqual(runner.count, 0)
  }
  func testControllerGrantsAreDeniedAndCanonical() throws {
    let base = "/private/tmp/sideport-test-" + UUID().uuidString
    let root = base + "/control"
    let session = root + "/work/permission-sessions/test"
    let project = base + "/project"
    try directory(session)
    try directory(project)
    defer { try? FileManager.default.removeItem(atPath: base) }
    let context = try NativeContext(root: root, session: session)
    assertRefused(try context.checkGrant(root))
    assertRefused(try context.checkGrant(base))
    assertRefused(try context.checkGrant(session))
    try privateWrite(
      [["path": project, "kind": "directory", "access": "read"]], session + "/grants.json")
    let grants = try context.grants()
    assertTrue(context.permitted(project + "/file", "read", grants))
    assertFalse(context.permitted(project + "/file", "read_write", grants))
    assertFalse(context.permitted(project + "-other", "read", grants))
  }
  func testDragSchemaForbidsCoordinates() {
    let drag =
      NativeBroker.computerTools.first { $0["name"] as? String == "drag" }!["inputSchema"]
      as! JSONObject
    assertEqual(drag["additionalProperties"] as? Bool, false)
    let properties = drag["properties"] as! JSONObject
    assertNil(properties["from_coords"])
    assertNil(properties["to_coords"])
    assertEqual(Set(drag["required"] as! [String]), Set(["from", "to", "snapshot_id"]))
  }
  func testArchivePreflight() async throws {
    assertEqual(
      try ReleaseArchive.validate(
        "dir/\ndir/tool\n", "drwx 0 root wheel 0 date dir/\n-rwx 0 root wheel 1 date dir/tool\n"),
      ["dir/", "dir/tool"])
    for (names, rows) in [
      ("tool\n", "lrwx tool -> /tmp\n"),
      ("tool\n", "hrwx tool link to other\n"),
      ("tool\n", "prwx tool\n"),
      ("../tool\n", "-rwx tool\n"),
      ("/tool\n", "-rwx tool\n"),
      ("tool\n./tool\n", "-rwx tool\n-rwx ./tool\n"),
      ("tool\n", "-rwx tool\n-rwx hidden\n"),
    ] { assertRefused(try ReleaseArchive.validate(names, rows)) }
    let base = "/private/tmp/sideport-archive-test-" + UUID().uuidString
    try directory(base + "/input")
    try directory(base + "/output")
    defer { try? FileManager.default.removeItem(atPath: base) }
    try Data("benign".utf8).write(to: URL(fileURLWithPath: base + "/input/tool"))
    let runner = ChildSupervisor()
    let env = ["PATH": "/usr/bin:/bin"]
    let compressed = try await runner.run(
      "/usr/bin/tar", ["-czf", base + "/safe.tgz", "tool"], environment: env, cwd: base + "/input")
    assertEqual(compressed.code, 0)
    try await ReleaseArchive.extract(base + "/safe.tgz", to: base + "/output", runner: runner)
    assertEqual(try String(contentsOfFile: base + "/output/tool", encoding: .utf8), "benign")
    try FileManager.default.createSymbolicLink(
      atPath: base + "/input/escape", withDestinationPath: base)
    let malicious = try await runner.run(
      "/usr/bin/tar", ["-czf", base + "/unsafe.tgz", "escape", "tool"], environment: env,
      cwd: base + "/input")
    assertEqual(malicious.code, 0)
    try directory(base + "/untouched")
    do {
      try await ReleaseArchive.extract(
        base + "/unsafe.tgz", to: base + "/untouched", runner: runner)
      RegressionReport.fail("Linked archive must be rejected before extraction")
    } catch {}
    assertEqual(try FileManager.default.contentsOfDirectory(atPath: base + "/untouched"), [])
  }
  func testToolPagination() async throws {
    let python = ["/opt/homebrew/bin/python3", "/usr/bin/python3"].first(
      where: FileManager.default.isExecutableFile)!
    let code =
      "import sys,json\nfor line in sys.stdin:\n m=json.loads(line); p=m.get('params',{}); r={'tools':[{'name':'second' if 'cursor' in p else 'first','inputSchema':{'type':'object'}}]}; r.update({} if 'cursor' in p else {'nextCursor':'page2'}); print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':r}),flush=True)"
    let peer = try StdioPeer(
      ChildSupervisor(), python, ["-u", "-c", code], environment: ["PATH": "/usr/bin:/bin"],
      cwd: "/private/tmp")
    defer { peer.close() }
    assertEqual(try await peer.listTools().map { $0["name"] as! String }, ["first", "second"])
  }
  func testUpdateRollback() async throws {
    let root = "/private/tmp/sideport-update-test-" + UUID().uuidString
    let work = root + "/work"
    let stage = root + "/stage"
    let backup = root + "/backup"
    defer { try? FileManager.default.removeItem(atPath: root) }
    for path in [work + "/mcpproxy-bin", work + "/mcpproxy-pilot", stage + "/mcpproxy-bin", backup]
    { try directory(path) }
    try Data("original-binary".utf8).write(
      to: URL(fileURLWithPath: work + "/mcpproxy-bin/mcpproxy"))
    try Data("original-database".utf8).write(
      to: URL(fileURLWithPath: work + "/mcpproxy-pilot/config.db"))
    try Data("replacement-binary".utf8).write(
      to: URL(fileURLWithPath: stage + "/mcpproxy-bin/mcpproxy"))
    try privateWrite(["tag_name": "old"], work + "/mcpproxy-release.json")
    let updater = DependencyUpdater(root: root)
    do {
      _ = try await updater.replace(
        stage: stage, backup: backup, changed: [(DependencyUpdater.targets[0], ["tag_name": "new"])]
      ) {
        try Data("simulated-migration".utf8).write(
          to: URL(fileURLWithPath: work + "/mcpproxy-pilot/config.db"))
        throw SideportError("Injected compatibility failure")
      }
      RegressionReport.fail("Update must roll back when validation fails")
    } catch {}
    assertEqual(
      try String(contentsOfFile: work + "/mcpproxy-bin/mcpproxy", encoding: .utf8),
      "original-binary")
    assertEqual(
      try String(contentsOfFile: work + "/mcpproxy-pilot/config.db", encoding: .utf8),
      "original-database")
    assertEqual(
      try jsonObject(Data(contentsOf: URL(fileURLWithPath: work + "/mcpproxy-release.json")))[
        "tag_name"] as? String, "old")
  }
  func testDesktopResponseBoundsAndReceipts() throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let drawing = CGContext(
      data: nil, width: 4000, height: 2500, bitsPerComponent: 8,
      bytesPerRow: 4000 * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawing.setFillColor(CGColor(gray: 0.5, alpha: 1))
    drawing.fill(CGRect(x: 0, y: 0, width: 4000, height: 2500))
    let png = NSBitmapImageRep(cgImage: drawing.makeImage()!).representation(
      using: .png, properties: [:])!
    let (jpeg, width, height) = try NativeDesktop.preview(png)
    assertAtMost(jpeg.count, 524288)
    assertAtMost(max(width, height), 2304)
    let outcome = DesktopActionOutcome.dispatchedUnverified(
      delivery: .init(mechanism: .globalEvents, mode: .foreground), evidence: .deliveryAccepted,
      unitCount: .one)
    let result = NativeDesktop.actionResult(outcome, operation: "press")
    let receipt = try jsonObject(
      Data(((result["content"] as! [JSONObject])[0]["text"] as! String).utf8))
    assertEqual(receipt["completed"] as? Bool, false)
    assertEqual(receipt["status"] as? String, "dispatched_unverified")
    assertTrue(receipt["outcome"] is JSONObject)
  }
  @MainActor
  func testComputerCompatibility() async throws {
    let name = NSPasteboard.Name("sideport-audit-" + UUID().uuidString)
    let board = NSPasteboard(name: name)
    let desktop = NativeDesktop(pasteboard: board)
    defer {
      desktop.close()
      board.clearContents()
      board.releaseGlobally()
    }
    let bytes = Data([0, 255, 10, 0, 200])
    _ = try await desktop.call(
      "clipboard",
      ["action": "set", "data_base64": bytes.base64EncodedString(), "uti": "public.data"])
    _ = try await desktop.call("clipboard", ["action": "save", "slot": "binary"])
    _ = try await desktop.call("clipboard", ["action": "set", "text": "changed"])
    _ = try await desktop.call("clipboard", ["action": "restore", "slot": "binary"])
    assertEqual(board.data(forType: .init("public.data")), bytes)
    let read = try await desktop.call("clipboard", ["action": "get", "prefer": "public.data"])
    let metadata = try jsonObject(
      Data(((read["content"] as! [JSONObject])[0]["text"] as! String).utf8))
    assertEqual(metadata["data_base64"] as? String, bytes.base64EncodedString())
    do {
      _ = try await desktop.call("clipboard", ["action": "save", "slot": "ambiguous.name"])
      RegressionReport.fail("Unsafe slot alias accepted")
    } catch {}
    let launch = try NativeDesktop.launchRequest([
      "app": "TextEdit", "urls": ["https://example.com"], "new_instance": true, "activate": false,
    ])
    assertTrue(launch.createsNewInstance)
    assertFalse(launch.activates)
    assertEqual(launch.openURLs.count, 1)
    assertRefused(try NativeDesktop.launchRequest(["url": "javascript:alert(1)"]))
    let before = DetectedElement(
      id: "old", type: .button, label: "Alpha", bounds: CGRect(x: 1, y: 1, width: 20, height: 20))
    let moved = DetectedElement(
      id: "new", type: .button, label: "Alpha", bounds: CGRect(x: 50, y: 50, width: 20, height: 20))
    assertEqual(try NativeDesktop.refreshed(before, from: [moved]).id, "new")
    assertRefused(try NativeDesktop.refreshed(before, from: []))
    assertRefused(try NativeDesktop.refreshed(before, from: [moved, moved]))
    assertRefused(
      try NativeDesktop.region(["x": 0, "y": 0, "width": Double.infinity, "height": 10]))
    let tool: JSONObject = [
      "name": "ping", "description": "Fixture",
      "inputSchema": ["type": "object", "properties": [:]],
    ]
    assertEqual(try ManagedServers.toolListing([tool]).count, 1)
    assertEqual(try ManagedServers.toolListing(["tools": [tool]]).count, 1)
    assertRefused(try ManagedServers.toolListing(["result": [tool]]))
    assertRefused(try ManagedServers.identifier("https://example.com/mcp"))
    assertRefused(try ManagedServers.identifier("namespace/../private"))
    for value: Any in [
      [["id": "fixture"]], ["connections": [["connectionId": "fixture"]]],
      ["servers": [["name": "fixture"]]],
    ] { assertEqual(try ManagedServers.connectionListing(value).count, 1) }
    assertEqual(try RemoteEndpoint("http://[::1]/mcp", managed: true).host, "::1")
    assertRefused(try RemoteEndpoint("https://[::1]/mcp").resolve())
  }
  func testPrivateJobManifestExcludesCredentials() throws {
    let root = "/private/tmp/sideport-secret-test-" + UUID().uuidString
    try directory(root)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let job = try OwnedExecution.prepare(
      root + "/work/nono-bin/nono", ["run"],
      environment: [
        "SIDEPORT_HOME": root, "SIDEPORT_PRIVATE_TEST": "SYNTHETIC-PRIVATE-CREDENTIAL",
      ], cwd: root)!
    let value = try String(contentsOfFile: job.1[1] + "/request.json", encoding: .utf8)
    assertFalse(value.contains("SYNTHETIC-PRIVATE-CREDENTIAL"))
    let parsed = try jsonObject(Data(value.utf8))
    assertEqual(parsed["secret_keys"] as? [String], ["SIDEPORT_PRIVATE_TEST"])
    assertNil((parsed["environment"] as? JSONObject)?["SIDEPORT_PRIVATE_TEST"])
  }
  func testLegacyRememberedLocationFormat() throws {
    let base = "/private/tmp/sideport-remember-test-" + UUID().uuidString
    let project = base + "/project"
    try directory(project)
    defer { try? FileManager.default.removeItem(atPath: base) }
    let file = URL(fileURLWithPath: base + "/remembered.json")
    let saved = RememberedLocations(file: file, controller: base + "/controller")
    try saved.remember(path: project, kind: "directory", access: "read")
    let state = try jsonObject(Data(contentsOf: file))
    assertEqual(state["version"] as? Int, 1)
    let reopened = RememberedLocations(file: file, controller: base + "/controller")
    assertEqual(try reopened.read().first?.path, project)
    try reopened.remember(path: project, kind: "directory", access: "read_write")
    assertEqual(try saved.read().first?.access, "read_write")
    try FileManager.default.moveItem(atPath: project, toPath: base + "/old-project")
    try directory(project)
    assertEqual(try reopened.read().count, 0)
  }
}

extension SecurityTests {
  static func run() async throws {
    let tests = SecurityTests()
    try tests.testGitHubPolicy()
    try tests.testPushPolicy()
    try tests.testSimpleGitHubDoesNotEvaluateShell()
    try tests.testUncertainReviewAlwaysAsks()
    try tests.testRemoteSafety()
    try tests.testPackageAdmission()
    try await tests.testBoundedProcessOutputAndTimeout()
    try await tests.testShutdownRefusesLateExecution()
    try await tests.testShortRPCMessages()
    try await tests.testDetachedProcessCleanup()
    try await tests.testFastProcessGroupCleanup()
    try tests.testControllerGrantsAreDeniedAndCanonical()
    tests.testDragSchemaForbidsCoordinates()
    try await tests.testArchivePreflight()
    try await tests.testToolPagination()
    try await tests.testUpdateRollback()
    try tests.testDesktopResponseBoundsAndReceipts()
    try tests.testLegacyRememberedLocationFormat()
    try await tests.testComputerCompatibility()
    try tests.testPrivateJobManifestExcludesCredentials()
    guard RegressionReport.failures == 0 else {
      throw SideportError("Native regression checks failed")
    }
    print("Native regression checks passed: 20 groups")
  }
}
