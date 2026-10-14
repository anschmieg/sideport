import CryptoKit
import Darwin
import Foundation
import Security

actor NativeProviders {
  struct Provider {
    let peer: ToolPeer
    let tools: [JSONObject]
    let spec: String
    let scratch: String?
    let profile: String?
  }
  let runtime: RuntimeSupport
  let approvals: LocalApprovals
  let node: OptionalNode
  let managed: ManagedServers
  var providers: [String: Provider] = [:]
  var admitting = false
  var closed = false
  init(_ runtime: RuntimeSupport, _ approvals: LocalApprovals) {
    self.runtime = runtime
    self.approvals = approvals
    let optional = OptionalNode(runtime.context, runtime.supervisor)
    node = optional
    managed = ManagedServers(runtime, approvals, optional)
  }
  static func validateTools(_ value: Any?) throws -> [JSONObject] {
    guard let tools = value as? [JSONObject], tools.count <= 1000 else {
      throw SideportError("Invalid provider tool listing")
    }
    var names = Set<String>()
    for tool in tools {
      guard let name = tool["name"] as? String, !name.isEmpty, name.utf8.count <= 200,
        names.insert(name).inserted,
        (tool["inputSchema"] as? JSONObject)?["type"] as? String == "object"
      else { throw SideportError("Invalid or duplicate provider tool schema") }
    }
    return tools
  }
  static func packageSpec(_ package: String, _ version: String) throws -> String {
    guard
      package.range(
        of: #"^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression)
        != nil, package.utf8.count <= 214,
      version.range(
        of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?$"#,
        options: .regularExpression) != nil, version.utf8.count <= 100
    else { throw SideportError("Use an npm package name and exact version") }
    return package + "@" + version
  }
  static func arguments(_ value: Any?) throws -> [String] {
    guard let args = value as? [String], args.count <= 128,
      args.allSatisfy({ $0.utf8.count <= 16384 && !$0.contains("\0") })
    else { throw SideportError("Invalid provider arguments") }
    return args
  }
  func startRemote(_ args: JSONObject) async throws -> JSONObject {
    let endpoint = try RemoteEndpoint(NativeDesktop.string(args, "url"))
    _ = try endpoint.resolve()
    guard
      try await approvals.capability(
        "remote_server", ["endpoint": endpoint.url.absoluteString, "host": endpoint.host],
        NativeDesktop.string(args, "reason", maximum: 500))
    else { return textResult(["status": "denied"]) }
    let peer = try RemotePeer(
      endpoint.url.absoluteString, supervisor: runtime.supervisor, scratch: runtime.scratch)
    return try await admit(peer, spec: endpoint.url.absoluteString)
  }
  func admit(
    _ peer: ToolPeer, spec: String, scratch: String? = nil, profile: String? = nil,
    allowed: [String]? = nil, disabled: [String]? = nil
  ) async throws -> JSONObject {
    do {
      try await peer.connect()
      let tools = try await peer.listTools().filter { tool in
        let name = tool["name"] as! String
        return (allowed == nil || allowed!.contains(name)) && !(disabled?.contains(name) ?? false)
      }
      guard !closed else { throw SideportError("Connection closed during server startup") }
      let id = UUID().uuidString
      providers[id] = Provider(
        peer: peer, tools: tools, spec: spec, scratch: scratch, profile: profile)
      return textResult([
        "status": "running", "id": id, "package": spec, "protocol": peer.version, "tools": tools,
        "hint": "New file grants require stopping and requesting this provider again",
      ])
    } catch {
      peer.close()
      if let profile { try? FileManager.default.removeItem(atPath: profile) }
      if let scratch { try? FileManager.default.removeItem(atPath: scratch) }
      throw error
    }
  }
  func startNpm(_ args: JSONObject) async throws -> JSONObject {
    let package = try NativeDesktop.string(args, "package", maximum: 214)
    let version = try NativeDesktop.string(args, "version", maximum: 100)
    let spec = try Self.packageSpec(package, version)
    let serverArgs = try Self.arguments(args["args"])
    let approved = try runtime.context.grants()
    let key = SHA256.hash(data: Data(spec.utf8)).map { String(format: "%02x", $0) }.joined()
    let cache = runtime.context.work + "/provider-cache/" + key
    let cached = FileManager.default.fileExists(atPath: cache + "/approved-install.json")
    guard
      try await approvals.capability(
        "npm_server",
        [
          "package": package, "version": version, "args": serverArgs,
          "locations": approved.map(\.dictionary), "cached": cached, "network": "blocked",
        ], NativeDesktop.string(args, "reason", maximum: 500))
    else { return textResult(["status": "denied"]) }
    let executable = try await node.ensure()
    let npm = try await node.npm().1
    let nodeRoot = URL(fileURLWithPath: executable).deletingLastPathComponent()
      .deletingLastPathComponent().path
    let scratch = runtime.scratch + "/provider-" + UUID().uuidString
    try directory(scratch)
    try directory(cache)
    var transferred = false
    defer { if !transferred { try? FileManager.default.removeItem(atPath: scratch) } }
    let marker = cache + "/approved-install.json"
    var auditDue = true
    if cached {
      guard let state = try? jsonObject(Data(contentsOf: URL(fileURLWithPath: marker))),
        state["spec"] as? String == spec
      else { throw SideportError("Cached package identity mismatch") }
      if let timestamp = state["audited"] as? String,
        let date = ISO8601DateFormatter().date(from: timestamp)
      {
        auditDue = !(0..<86400).contains(Date().timeIntervalSince(date))
      }
    }
    if auditDue {
      var installer = try runtime.providerProfile(
        [],
        extra: [
          Grant(path: nodeRoot, kind: "directory", access: "read"),
          Grant(path: cache, kind: "directory", access: "read_write"),
          Grant(path: scratch, kind: "directory", access: "read_write"),
        ], network: true)
      // The installer sees no user project files and has its own writable caches.
      var filesystem = installer["filesystem"] as! JSONObject
      filesystem["allow"] = [cache, scratch]
      filesystem["allow_file"] = ["/dev/null"]
      installer["filesystem"] = filesystem
      for name in ["user.npmrc", "global.npmrc"] {
        try Data().write(to: URL(fileURLWithPath: scratch + "/" + name))
        chmod(scratch + "/" + name, 0o600)
      }
      var anchors: CFArray?
      guard SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess,
        let anchors = anchors as? [SecCertificate]
      else { throw SideportError("Cannot read public TLS trust anchors") }
      let trust = anchors.map { certificate -> String in
        let bytes = SecCertificateCopyData(certificate) as Data
        return "-----BEGIN CERTIFICATE-----\n"
          + bytes.base64EncodedString(options: .lineLength64Characters)
          + "\n-----END CERTIFICATE-----\n"
      }.joined(separator: "\n")
      try Data(trust.utf8).write(to: URL(fileURLWithPath: scratch + "/trust.pem"))
      chmod(scratch + "/trust.pem", 0o600)
      let env = [
        "NPM_CONFIG_USERCONFIG": scratch + "/user.npmrc",
        "NPM_CONFIG_GLOBALCONFIG": scratch + "/global.npmrc",
        "NPM_CONFIG_CACHE": scratch + "/npm-cache", "NODE_EXTRA_CA_CERTS": scratch + "/trust.pem",
        "TMPDIR": scratch + "/",
      ]
      if !cached {
        let download = try await runtime.launchProfile(
          installer, executable,
          [
            npm, "install", "--ignore-scripts", "--no-fund", "--no-audit", "--save-exact",
            "--registry=https://registry.npmjs.org", spec,
          ], cwd: cache, timeout: 120, environment: env)
        guard download.code == 0, !download.stopped else {
          throw SideportError(
            "Package download failed inside the installer sandbox: "
              + secretRedacted(String(decoding: download.stderr.suffix(2000), as: UTF8.self)))
        }
      }
      let audit = try await runtime.launchProfile(
        installer, executable,
        [npm, "audit", "--json", "--audit-level=high", "--registry=https://registry.npmjs.org"],
        cwd: cache, timeout: 120, environment: env)
      let report = try jsonObject(audit.stdout)
      let vulnerabilities = (report["metadata"] as? JSONObject)?["vulnerabilities"] as? JSONObject
      guard audit.code == 0, !audit.stopped, report["error"] == nil, let vulnerabilities,
        (vulnerabilities["high"] as? Int) == 0, (vulnerabilities["critical"] as? Int) == 0
      else { throw SideportError("Package audit failed or found high/critical advisories") }
      try privateWrite(
        ["spec": spec, "audited": ISO8601DateFormatter().string(from: Date())], marker)
    }
    let packageRoot = cache + "/node_modules/" + package
    let metadata = try jsonObject(
      Data(contentsOf: URL(fileURLWithPath: packageRoot + "/package.json")))
    guard metadata["name"] as? String == package, metadata["version"] as? String == version else {
      throw SideportError("Downloaded package identity mismatch")
    }
    let bin: String
    if let value = metadata["bin"] as? String {
      bin = value
    } else if let entries = metadata["bin"] as? [String: String], entries.count == 1,
      let value = entries.values.first
    {
      bin = value
    } else {
      throw SideportError("Package must have one unambiguous executable")
    }
    guard !bin.hasPrefix("/"), !bin.split(separator: "/").contains("..") else {
      throw SideportError("Invalid package executable path")
    }
    let entry = try canonical(packageRoot + "/" + bin, existing: true)
    guard inside(entry, cache),
      ["js", "cjs", "mjs"].contains(URL(fileURLWithPath: entry).pathExtension)
        || (try? String(contentsOfFile: entry, encoding: .utf8).hasPrefix("#!/usr/bin/env node"))
          == true
    else { throw SideportError("Only Node.js MCP package executables are supported") }
    let profilePath = runtime.context.session + "/" + UUID().uuidString + ".provider.json"
    try privateWrite(
      runtime.providerProfile(
        approved,
        extra: [
          Grant(path: nodeRoot, kind: "directory", access: "read"),
          Grant(path: cache, kind: "directory", access: "read"),
          Grant(path: scratch, kind: "directory", access: "read_write"),
        ]), profilePath)
    var env = runtime.environment
    env["TMPDIR"] = scratch + "/"
    env["XDG_CONFIG_HOME"] = runtime.context.work + "/nono-config"
    env["XDG_STATE_HOME"] = runtime.context.work + "/nono-state"
    env["XDG_CACHE_HOME"] = runtime.context.work + "/nono-cache"
    let peer: StdioPeer
    do {
      peer = try StdioPeer(
        runtime.supervisor, runtime.context.work + "/nono-bin/nono",
        ["run", "--silent", "--profile", profilePath, "--no-rollback", "--", executable, entry]
          + serverArgs, environment: env, cwd: runtime.context.workspace)
    } catch {
      try? FileManager.default.removeItem(atPath: profilePath)
      throw error
    }
    let result = try await admit(peer, spec: spec, scratch: scratch, profile: profilePath)
    transferred = true
    return result
  }
  func call(_ name: String, _ args: JSONObject) async throws -> JSONObject {
    guard !closed else { throw SideportError("Connection closed") }
    switch name {
    case "managed_servers": return try await managed.list(args)
    case "request_managed_server":
      guard !admitting, providers.count < 5 else {
        throw SideportError("A provider is starting or the limit is reached")
      }
      admitting = true
      defer { admitting = false }
      guard let (peer, profile, allowed, disabled) = try await managed.start(args) else {
        return textResult(["status": "denied"])
      }
      return try await admit(
        peer, spec: (args["manager"] as? String ?? "") + ":" + (args["name"] as? String ?? ""),
        profile: profile, allowed: allowed, disabled: disabled)
    case "request_server", "request_remote_server":
      guard !admitting, providers.count < 5 else {
        throw SideportError("A provider is starting or the five-provider limit is reached")
      }
      admitting = true
      defer { admitting = false }
      return try await (name == "request_server" ? startNpm(args) : startRemote(args))
    case "active_servers":
      return textResult(
        providers.map {
          [
            "id": $0.key, "package": $0.value.spec, "protocol": $0.value.peer.version,
            "tools": $0.value.tools,
          ] as JSONObject
        })
    case "stop_server":
      let id = try NativeDesktop.string(args, "id")
      guard let provider = providers.removeValue(forKey: id) else {
        throw SideportError("Unknown provider")
      }
      provider.peer.close()
      if let profile = provider.profile { try? FileManager.default.removeItem(atPath: profile) }
      if let scratch = provider.scratch { try? FileManager.default.removeItem(atPath: scratch) }
      return textResult(["status": "stopped"])
    case "call_server_tool":
      let id = try NativeDesktop.string(args, "id")
      let tool = try NativeDesktop.string(args, "tool")
      guard let provider = providers[id],
        provider.tools.contains(where: { $0["name"] as? String == tool }),
        let arguments = args["arguments"] as? JSONObject
      else { throw SideportError("Unknown provider tool") }
      return try await provider.peer.request(
        "tools/call", ["name": tool, "arguments": arguments], timeout: 30)
    default: throw SideportError("Unknown provider operation")
    }
  }
  func close() {
    closed = true
    for p in providers.values {
      p.peer.close()
      if let profile = p.profile { try? FileManager.default.removeItem(atPath: profile) }
      if let scratch = p.scratch { try? FileManager.default.removeItem(atPath: scratch) }
    }
    providers.removeAll()
  }
}
