import Darwin
import Foundation
import PeekabooAutomationKit

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
    try await tests.testShortRPCMessages()
    try await tests.testDetachedProcessCleanup()
    try tests.testControllerGrantsAreDeniedAndCanonical()
    tests.testDragSchemaForbidsCoordinates()
    guard RegressionReport.failures == 0 else {
      throw SideportError("Native regression checks failed")
    }
    print("Native regression checks passed: 11 groups")
  }
}
