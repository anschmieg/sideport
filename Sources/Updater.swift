import AppKit
import CryptoKit
import Darwin
import Foundation

struct DependencyUpdater {
  struct Target {
    let key: String
    let repository: String
    let metadata: String
    let directory: String
    let executable: String
    let pattern: String
  }
  static let targets = [
    Target(
      key: "MCPProxy", repository: "smart-mcp-proxy/mcpproxy-go", metadata: "mcpproxy-release.json",
      directory: "mcpproxy-bin", executable: "mcpproxy",
      pattern: #"^mcpproxy-[0-9.]+-darwin-arm64\.tar\.gz$"#),
    Target(
      key: "nono", repository: "nolabs-ai/nono", metadata: "nono-release.json",
      directory: "nono-bin", executable: "nono",
      pattern: #"^nono-v[0-9.]+-aarch64-apple-darwin\.tar\.gz$"#),
    Target(
      key: "OpenAI tunnel", repository: "openai/tunnel-client", metadata: "tunnel-release.json",
      directory: "tunnel-client", executable: "tunnel-client",
      pattern: #"^tunnel-client-runtime-v[0-9.]+-darwin-arm64\.zip$"#),
    Target(
      key: "DCG", repository: "Dicklesworthstone/destructive_command_guard",
      metadata: "dcg-release.json", directory: "permission-broker", executable: "dcg",
      pattern: #"^dcg-aarch64-apple-darwin\.tar\.xz$"#),
  ]
  let root: String
  var work: String { root + "/work" }
  static func paths(_ enumerator: FileManager.DirectoryEnumerator) -> [String] {
    enumerator.allObjects.compactMap { $0 as? String }
  }
  static func validAsset(_ asset: JSONObject, _ target: Target) throws {
    guard let name = asset["name"] as? String, GitHubPlan.matches(name, target.pattern),
      let digest = asset["digest"] as? String,
      GitHubPlan.matches(digest, #"^sha256:[a-f0-9]{64}$"#),
      let source = asset["browser_download_url"] as? String,
      source.hasPrefix("https://github.com/" + target.repository + "/releases/download/"),
      let url = URL(string: source), url.user == nil, url.password == nil, url.query == nil,
      url.fragment == nil
    else { throw SideportError("Release lacks a compatible asset and verified checksum") }
  }
  func plan() async throws -> JSONObject {
    var releases: [JSONObject] = []
    var changes: [String] = []
    for target in Self.targets {
      let current = try jsonObject(
        Data(contentsOf: URL(fileURLWithPath: work + "/" + target.metadata)))
      let (latest, _) = try await httpJSON(
        URL(string: "https://api.github.com/repos/" + target.repository + "/releases/latest")!,
        headers: ["User-Agent": "Sideport"], timeout: 30)
      guard latest["draft"] as? Bool == false, latest["prerelease"] as? Bool == false,
        let tag = latest["tag_name"] as? String, GitHubPlan.matches(tag, #"^v?\d+\.\d+\.\d+$"#),
        let assets = latest["assets"] as? [JSONObject],
        let asset = assets.first(where: {
          GitHubPlan.matches($0["name"] as? String ?? "", target.pattern)
        })
      else { throw SideportError("Compatible stable release missing for \(target.key)") }
      try Self.validAsset(asset, target)
      let previous = current["tag_name"] as? String ?? "unknown"
      if previous != tag { changes.append(target.key + ": " + previous + " → " + tag) }
      releases.append([
        "key": target.key, "current": previous, "next": tag, "release": latest, "asset": asset,
      ])
    }
    try privateWrite(
      ["created": Date().timeIntervalSince1970, "releases": releases], work + "/update-plan.json")
    return [
      "changes": changes, "note": "Peekaboo is compiled into Sideport and updates with the app.",
    ]
  }
  func apply() async throws -> JSONObject {
    let lease = try ControllerLease(root)
    defer { withExtendedLifetime(lease) {} }
    guard !FileManager.default.fileExists(atPath: work + "/mcpproxy-runtime.key") else {
      throw SideportError("Disconnect before updating")
    }
    let plan = try jsonObject(Data(contentsOf: URL(fileURLWithPath: work + "/update-plan.json")))
    guard let created = plan["created"] as? Double,
      (0..<600).contains(Date().timeIntervalSince1970 - created),
      let releases = plan["releases"] as? [JSONObject], releases.count == Self.targets.count
    else { throw SideportError("Update check expired; check again") }
    let fd = open(work + "/dependency-update.lock", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw SideportError("Another update is running") }
    defer {
      Darwin.close(fd)
      try? FileManager.default.removeItem(atPath: work + "/dependency-update.lock")
    }
    let stage = work + "/update-stage-" + UUID().uuidString
    let backup = work + "/update-backup"
    try directory(stage)
    try directory(backup)
    defer { try? FileManager.default.removeItem(atPath: stage) }
    let runner = ChildSupervisor()
    let env = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
    var changed: [(Target, JSONObject)] = []
    for target in Self.targets {
      guard let item = releases.first(where: { $0["key"] as? String == target.key }),
        let release = item["release"] as? JSONObject, let asset = item["asset"] as? JSONObject
      else { throw SideportError("Invalid update plan") }
      if item["current"] as? String == item["next"] as? String { continue }
      try Self.validAsset(asset, target)
      let name = asset["name"] as! String
      let url = asset["browser_download_url"] as! String
      let archive = stage + "/" + name
      let output = stage + "/" + target.directory
      try directory(output)
      let download = try await runner.run(
        "/usr/bin/curl",
        [
          "--disable", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
          "--proto-redir", "=https", "--max-time", "120", "--max-filesize", "150000000", "--output",
          archive, url,
        ], environment: env, cwd: stage, timeout: 125)
      guard download.code == 0, !download.stopped else {
        throw SideportError("Release download failed")
      }
      let bytes = try Data(contentsOf: URL(fileURLWithPath: archive), options: .mappedIfSafe)
      guard bytes.count <= 150_000_000,
        SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined()
          == String((asset["digest"] as! String).dropFirst(7))
      else { throw SideportError("Release checksum mismatch") }
      try await ReleaseArchive.extract(archive, to: output, runner: runner)
      guard let enumerator = FileManager.default.enumerator(atPath: output) else {
        throw SideportError("Invalid release archive")
      }
      var executable: String?
      for path in Self.paths(enumerator) {
        let full = output + "/" + path
        let attributes = try FileManager.default.attributesOfItem(atPath: full)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
          throw SideportError("Release contains a symbolic link")
        }
        if URL(fileURLWithPath: path).lastPathComponent == target.executable,
          attributes[.type] as? FileAttributeType == .typeRegular
        {
          guard executable == nil else { throw SideportError("Ambiguous release executable") }
          executable = full
        }
      }
      guard let executable else { throw SideportError("Release executable missing") }
      let destination = output + "/" + target.executable
      if executable != destination {
        try FileManager.default.copyItem(atPath: executable, toPath: destination)
      }
      chmod(destination, 0o755)
      if target.key == "nono" {
        let signed = try await runner.run(
          "/usr/bin/codesign",
          [
            "--force", "--sign", "-", "--options", "restrict,runtime", "--timestamp=none",
            destination,
          ],
          environment: env, cwd: stage)
        guard signed.code == 0, ProcessProtection.credentialSafe(destination) else {
          throw SideportError("Updated proxy could not protect its credential environment")
        }
      }
      let check = try await runner.run(
        destination, ["--version"], environment: env, cwd: stage, timeout: 15)
      guard check.code == 0, !check.stopped else {
        throw SideportError("Release executable failed validation")
      }
      changed.append((target, release))
    }
    return try await replace(stage: stage, backup: backup, changed: changed) {
      try await NativeSelfCheck.run(root)
    }
  }
  func replace(
    stage: String, backup: String, changed: [(Target, JSONObject)],
    validate: () async throws -> Void
  ) async throws -> JSONObject {
    // Preserve the original gateway database when upgrading MCPProxy. The
    // compatibility check migrates a private clone, never the live database.
    let upgradingGateway = changed.contains { $0.0.directory == "mcpproxy-bin" }
    if upgradingGateway {
      try FileManager.default.copyItem(
        atPath: work + "/mcpproxy-pilot", toPath: stage + "/mcpproxy-pilot")
    }
    var directories = changed.map { $0.0.directory }
    if upgradingGateway { directories.append("mcpproxy-pilot") }
    var swapped: [String] = []
    var originalMetadata: [String: Data] = [:]
    do {
      for (target, _) in changed {
        originalMetadata[target.metadata] = try Data(
          contentsOf: URL(fileURLWithPath: work + "/" + target.metadata))
      }
      for item in directories {
        let current = work + "/" + item
        let previous = backup + "/" + item
        try? FileManager.default.removeItem(atPath: previous)
        try FileManager.default.moveItem(atPath: current, toPath: previous)
        swapped.append(item)
        try FileManager.default.moveItem(atPath: stage + "/" + item, toPath: current)
      }
      try await validate()
      for (target, release) in changed { try privateWrite(release, work + "/" + target.metadata) }
      return [
        "status": "updated", "components": changed.map { $0.0.key },
        "note": "Compatibility checks passed. Connections remain off.",
      ]
    } catch {
      var failures: [String] = []
      for item in swapped.reversed() {
        do {
          if FileManager.default.fileExists(atPath: work + "/" + item) {
            try FileManager.default.removeItem(atPath: work + "/" + item)
          }
          try FileManager.default.moveItem(atPath: backup + "/" + item, toPath: work + "/" + item)
        } catch { failures.append(item) }
      }
      for (name, data) in originalMetadata {
        do {
          try data.write(to: URL(fileURLWithPath: work + "/" + name), options: .atomic)
          chmod(work + "/" + name, 0o600)
        } catch { failures.append(name) }
      }
      if !failures.isEmpty {
        throw SideportError(
          "Update and rollback failed for " + failures.joined(separator: ", ")
            + ". Backups remain at " + backup)
      }
      throw SideportError(
        "Update failed compatibility checks; previous dependencies restored: "
          + error.localizedDescription)
    }
  }
}
enum NativeSelfCheck {
  static func reservePort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw SideportError("Cannot allocate test port") }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
    }
    guard result == 0 else { throw SideportError("Cannot bind test port") }
    let read = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard read == 0 else { throw SideportError("Cannot inspect test port") }
    return UInt16(bigEndian: address.sin_port)
  }
  static func run(_ source: String) async throws {
    let temp = "/private/tmp/sideport-check-" + UUID().uuidString
    let root = temp + "/controller"
    let session = root + "/work/permission-sessions/check"
    let project = temp + "/project"
    try directory(session)
    try directory(project)
    defer { try? FileManager.default.removeItem(atPath: temp) }
    for name in ["nono-bin", "permission-broker", "mcpproxy-bin", "tunnel-client"] {
      try FileManager.default.copyItem(
        atPath: source + "/work/" + name, toPath: root + "/work/" + name)
    }
    try privateWrite(
      [["path": project, "kind": "directory", "access": "read_write"]], session + "/grants.json")
    try Data("private".utf8).write(to: URL(fileURLWithPath: root + "/work/controller-test.key"))
    let context = try NativeContext(root: root, session: session)
    let supervisor = ChildSupervisor()
    let runtime = try RuntimeSupport(context, supervisor)
    let approvals = LocalApprovals(context)
    let safety = try CommandSafety(context, supervisor, approvals)
    defer {
      runtime.close()
      supervisor.stopAll()
    }
    let allowed = try await safety.assess(
      "printf hello", cwd: project, reason: nil, task: nil, scope: context.grants())
    guard allowed["allowed"] as? Bool == true else {
      throw SideportError("Routine command guard check failed")
    }
    let destructive = try await safety.assess(
      "rm -rf /", cwd: project, reason: nil, task: nil, scope: context.grants())
    guard destructive["allowed"] as? Bool != true else {
      throw SideportError("Destructive command guard check failed")
    }
    let success = try await runtime.execute(
      "/bin/bash", ["--noprofile", "--norc", "-c", "printf sandbox-ok"], cwd: project,
      approved: context.grants())
    guard success.code == 0, String(decoding: success.stdout, as: UTF8.self) == "sandbox-ok" else {
      throw SideportError("Native sandbox execution failed")
    }
    let denied = try await runtime.execute(
      "/bin/cat", [root + "/work/controller-test.key"], cwd: project, approved: context.grants())
    guard denied.code != 0, !String(decoding: denied.stdout, as: UTF8.self).contains("private")
    else { throw SideportError("Controller isolation failed") }
    // Use a private named pasteboard: the user's clipboard is never read or changed.
    let boardName = "sideport-audit-" + UUID().uuidString
    let board = NSPasteboard(name: NSPasteboard.Name(boardName))
    board.clearContents()
    guard board.setString("SYNTHETIC-PRIVATE-PASTEBOARD", forType: .string) else {
      throw SideportError("Cannot create private clipboard probe")
    }
    defer {
      board.clearContents()
      board.releaseGlobally()
    }
    var controlProfile = try runtime.profile(context.grants())
    controlProfile["unsafe_macos_seatbelt_rules"] = runtime.codeWriteRules.filter {
      !$0.contains("mach-lookup")
    }
    let controlClipboard = try await runtime.launchProfile(
      controlProfile, context.executable, ["--clipboard-probe", boardName], cwd: project)
    guard
      String(decoding: controlClipboard.stdout, as: UTF8.self).contains(
        "SYNTHETIC-PRIVATE-PASTEBOARD")
    else {
      throw SideportError(
        "Private clipboard control probe could not validate IPC isolation (exit \(controlClipboard.code)): "
          + String(decoding: controlClipboard.stderr.prefix(1500), as: UTF8.self))
    }
    let clipboard = try await runtime.execute(
      context.executable, ["--clipboard-probe", boardName], cwd: project, approved: context.grants()
    )
    guard
      !String(decoding: clipboard.stdout + clipboard.stderr, as: UTF8.self).contains(
        "SYNTHETIC-PRIVATE-PASTEBOARD")
    else {
      throw SideportError("Shell must not bypass computer-control approval through clipboard IPC")
    }
    var credentials = try runtime.profile([])
    credentials["network"] = [
      "tls_intercept": ["ca_lifecycle": "session"], "credentials": ["fixture"],
      "custom_credentials": [
        "fixture": [
          "upstream": "https://example.com", "credential_key": "env://SIDEPORT_PRIVATE_TEST",
          "env_var": "GH_TOKEN", "credential_format": "Bearer {}",
        ]
      ],
    ]
    credentials["environment"] = ["allow_vars": ["HOME", "PATH", "GH_TOKEN"]]
    let isolatedCredential = try await runtime.launchProfile(
      credentials, context.executable, ["--private-env-probe"], cwd: project,
      environment: ["SIDEPORT_PRIVATE_TEST": "SYNTHETIC-PRIVATE-CREDENTIAL"])
    guard isolatedCredential.code == 0,
      try jsonObject(isolatedCredential.stdout)["secret_in_environment"] as? Bool == false,
      try jsonObject(isolatedCredential.stdout)["secret_in_parent_environment"] as? Bool == false
    else { throw SideportError("Proxy credentials leaked into the sandboxed environment") }
    let host = try BackgroundService(
      supervisor, context.executable, ["--host-env-fixture"],
      environment: ["SIDEPORT_PRIVATE_TEST": "SYNTHETIC-PRIVATE-CREDENTIAL"], cwd: project)
    defer { host.close() }
    let positive = try await supervisor.run(
      context.executable, ["--process-env-probe", "self"],
      environment: ["SIDEPORT_PRIVATE_TEST": "SYNTHETIC-PRIVATE-CREDENTIAL"], cwd: project)
    guard positive.code == 0,
      try jsonObject(positive.stdout)["synthetic_present"] as? Bool == true
    else { throw SideportError("Host environment isolation probe lacks a positive control") }
    let negative = try await runtime.execute(
      context.executable, ["--process-env-probe", String(host.pid)], cwd: project,
      approved: context.grants())
    guard negative.code == 0, try jsonObject(negative.stdout)["synthetic_present"] as? Bool == false
    else {
      throw SideportError(
        "Sandboxed code could read a protected host process's credential environment")
    }
    // Query only a nonexistent random service, with authentication UI disabled.
    // No real Keychain item or password is requested by this probe.
    let keychainService = UUID().uuidString
    let hostKeychain = try await supervisor.run(
      context.executable, ["--keychain-probe", keychainService],
      environment: ["HOME": context.home], cwd: project)
    guard hostKeychain.code == 0,
      try jsonObject(hostKeychain.stdout)["status"] as? Int == -25300
    else { throw SideportError("Keychain isolation probe lacks a working host control") }
    let childKeychain = try await runtime.execute(
      context.executable, ["--keychain-probe", keychainService], cwd: project,
      approved: context.grants())
    guard
      childKeychain.code != 0
        || (try? jsonObject(childKeychain.stdout))?["status"] as? Int != -25300
    else {
      throw SideportError("Sandboxed code could query the login Keychain service")
    }
    // Resolving a service does not request recording or capture any pixels.
    let captureService = "com.apple.replayd"
    let hostService = try await supervisor.run(
      context.executable, ["--service-probe", captureService], environment: [:], cwd: project)
    guard hostService.code == 0, try jsonObject(hostService.stdout)["available"] as? Bool == true
    else {
      throw SideportError("Screen-service lookup probe lacks a working host control")
    }
    let childService = try await runtime.execute(
      context.executable, ["--service-probe", captureService], cwd: project,
      approved: context.grants())
    guard
      childService.code != 0
        || (try? jsonObject(childService.stdout))?["available"] as? Bool != true
    else {
      throw SideportError("Sandboxed code could resolve the screen-capture service")
    }
    let configPath = root + "/work/mcpproxy-pilot/config.json"
    try directory(root + "/work/mcpproxy-pilot")
    for item in ["config.db", ".token_key", "instance-id"] {
      let existing = source + "/work/mcpproxy-pilot/" + item
      if FileManager.default.fileExists(atPath: existing) {
        try FileManager.default.copyItem(
          atPath: existing, toPath: root + "/work/mcpproxy-pilot/" + item)
      }
    }
    var config = try jsonObject(
      Data(contentsOf: NativeResources.directory.appendingPathComponent("config-template.json")))
    let port = try reservePort()
    config["listen"] = "127.0.0.1:" + String(port)
    config["api_key"] = UUID().uuidString + UUID().uuidString
    config["data_dir"] = root + "/work/mcpproxy-pilot"
    let environment = [
      "HOME": context.home, "PATH": "/usr/bin:/bin", "SIDEPORT_HOME": root,
      "MAC_CHATGPT_APPROVAL_DIR": session, "SIDEPORT_APP_EXECUTABLE": context.executable,
      "SIDEPORT_WORKSPACE": project, "SIDEPORT_RESOURCES": NativeResources.directory.path,
      "HEADLESS": "true", "MCPPROXY_TELEMETRY": "false",
    ]
    config["mcpServers"] =
      [
        [
          "name": "permissions", "command": context.executable, "args": ["--broker"],
          "env": environment, "protocol": "stdio", "enabled": true, "quarantined": false,
          "trust_mode": "manual",
        ]
      ] as [JSONObject]
    try privateWrite(config, configPath)
    let service = try BackgroundService(
      supervisor, root + "/work/mcpproxy-bin/mcpproxy",
      [
        "serve", "--config", configPath, "--data-dir", root + "/work/mcpproxy-pilot", "--log-level",
        "warn",
      ], environment: environment, cwd: root)
    defer { service.close() }
    let gateway = try GatewayAdmin(root)
    var loaded = false
    for _ in 0..<40 {
      if let listing = try? await gateway.api("GET", "/api/v1/servers/permissions/tools"),
        ((listing["data"] as? JSONObject)?["tools"] as? [JSONObject])?.count == 16
      {
        loaded = true
        break
      }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    guard loaded else { throw SideportError("Gateway could not discover native tools") }
    try await gateway.credential(revoke: false)
    guard FileManager.default.fileExists(atPath: root + "/work/mcpproxy-runtime.key") else {
      throw SideportError("Scoped credential check failed")
    }
    try await gateway.credential(revoke: true)
    guard !FileManager.default.fileExists(atPath: root + "/work/mcpproxy-runtime.key") else {
      throw SideportError("Scoped credential revocation failed")
    }
    let tunnel = try await supervisor.run(
      root + "/work/tunnel-client/tunnel-client", ["run", "--help"], environment: environment,
      cwd: root,
      timeout: 10)
    let help = String(decoding: tunnel.stdout + tunnel.stderr, as: UTF8.self)
    guard tunnel.code == 0, help.contains("--profile-file"), help.contains("--health.url-file")
    else { throw SideportError("Tunnel profile interface is incompatible") }

  }
}
