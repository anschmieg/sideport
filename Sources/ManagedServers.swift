import Darwin
import Foundation

final class SmitheryPeer: ToolPeer {
  let manager: ManagedServers
  let connection: String
  let namespace: String
  let supervisor = ChildSupervisor()
  var version = "smithery-cli", closed = false
  var tools: [JSONObject] = []
  init(_ manager: ManagedServers, _ connection: String, _ namespace: String) {
    self.manager = manager
    self.connection = connection
    self.namespace = namespace
  }
  func connect() async throws {
    tools = try NativeProviders.validateTools(
      await manager.smithery(
        ["tool", "list", connection, "--namespace", namespace, "--flat", "--limit", "1000"],
        supervisor: supervisor)["tools"])
  }
  func request(_ method: String, _ params: JSONObject, timeout: Double) async throws -> JSONObject {
    guard !closed else { throw SideportError("Forwarding stopped") }
    if method == "tools/list" { return ["tools": tools] }
    let tool = try ManagedServers.identifier(NativeDesktop.string(params, "name"))
    guard method == "tools/call", tools.contains(where: { $0["name"] as? String == tool }) else {
      throw SideportError("Unknown managed tool")
    }
    let input = String(decoding: try jsonData(params["arguments"] ?? [:]), as: UTF8.self)
    let response = try await manager.smithery(
      ["tool", "call", connection, tool, input, "--namespace", namespace], supervisor: supervisor)
    let result = response["result"] as? JSONObject ?? response
    return result["content"] is [JSONObject] ? result : textResult(result)
  }
  func close() {
    closed = true
    supervisor.stopAll()
  }
}
final class ManagedServers {
  let runtime: RuntimeSupport
  let approvals: LocalApprovals
  let node: OptionalNode
  init(_ runtime: RuntimeSupport, _ approvals: LocalApprovals, _ node: OptionalNode) {
    self.runtime = runtime
    self.approvals = approvals
    self.node = node
  }
  static func identifier(_ value: String) throws -> String {
    guard !value.isEmpty, value.utf8.count <= 200, !value.hasPrefix("-"),
      value.range(of: #"^[A-Za-z0-9_./:@-]+$"#, options: .regularExpression) != nil
    else { throw SideportError("Invalid managed server identifier") }
    return value
  }
  static func read(_ path: String, optional: Bool = false) throws -> JSONObject {
    if optional, !FileManager.default.fileExists(atPath: path) { return [:] }
    return try jsonObject(Data(contentsOf: URL(fileURLWithPath: path)), limit: 2_097_152)
  }
  static func merge(_ base: JSONObject, _ overlay: JSONObject) throws -> JSONObject {
    var result = base
    for (key, value) in overlay {
      guard !["__proto__", "constructor", "prototype"].contains(key) else {
        throw SideportError("Invalid manager configuration key")
      }
      if let left = result[key] as? JSONObject, let right = value as? JSONObject {
        result[key] = try merge(left, right)
      } else {
        result[key] = value
      }
    }
    return result
  }
  func agents(_ project: String?) throws -> (String, JSONObject) {
    let dir = try canonical(project ?? runtime.context.home, existing: true)
    if project != nil, !runtime.context.permitted(dir, "read", try runtime.context.grants()) {
      throw SideportError("Approve the project folder before reading its agents configuration")
    }
    let config = try Self.read(dir + "/.agents/agents.json")
    let local = try Self.read(dir + "/.agents/local.json", optional: true)
    guard let definitions = (config["mcp"] as? JSONObject)?["servers"] as? JSONObject else {
      throw SideportError("Unsupported agents-dev configuration")
    }
    var selected: Set<String>?
    if let active = config["activeProfile"] as? String {
      guard
        let names = ((config["profiles"] as? JSONObject)?[active] as? JSONObject)?["servers"]
          as? [String]
      else { throw SideportError("Invalid active agents profile") }
      selected = Set(names)
    }
    var servers: JSONObject = [:]
    for (name, value) in definitions {
      guard let value = value as? JSONObject else {
        throw SideportError("Invalid server configuration")
      }
      var merged = try Self.merge(
        value, (local["mcpServers"] as? JSONObject)?[name] as? JSONObject ?? [:])
      if let selected, !selected.contains(name) { merged["enabled"] = false }
      servers[name] = merged
    }
    return (dir, servers)
  }
  func smitheryOutput(_ args: [String], json: Bool = true, supervisor: ChildSupervisor? = nil)
    async throws -> String
  {
    guard
      let cli = [
        "/opt/homebrew/bin/smithery", "/usr/local/bin/smithery",
        runtime.context.home + "/.local/bin/smithery",
      ].compactMap({ try? canonical($0, existing: true) }).first
    else { throw SideportError("Install Smithery CLI and sign in locally first") }
    let nodePath = try await node.ensure()
    let out = try await (supervisor ?? runtime.supervisor).run(
      nodePath, [cli] + (json ? ["--json"] : []) + args,
      environment: [
        "HOME": runtime.context.home,
        "PATH": URL(fileURLWithPath: nodePath).deletingLastPathComponent().path
          + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      ], cwd: runtime.scratch, timeout: 30, limit: 4_194_304)
    guard out.code == 0, !out.stopped else {
      throw SideportError("Smithery request failed; check the existing login locally")
    }
    return String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
  }
  func smithery(_ args: [String], supervisor: ChildSupervisor? = nil) async throws -> JSONObject {
    let value = try await smitheryValue(args, supervisor: supervisor)
    return value as? JSONObject ?? ["result": value]
  }
  func smitheryValue(_ args: [String], supervisor: ChildSupervisor? = nil) async throws -> Any {
    let output = try await smitheryOutput(args, supervisor: supervisor)
    let value = try JSONSerialization.jsonObject(
      with: Data(output.utf8), options: .fragmentsAllowed)
    if let object = value as? JSONObject {
      guard object["error"] == nil, (object["connectionIssues"] as? [Any] ?? []).isEmpty else {
        throw SideportError("Smithery requires local authentication")
      }
    }
    return value
  }
  func namespace(_ args: JSONObject) async throws -> String {
    if let namespace = args["namespace"] as? String { return try Self.identifier(namespace) }
    return try Self.identifier(await smitheryOutput(["namespace", "show"], json: false))
  }
  func list(_ args: JSONObject) async throws -> JSONObject {
    if args["manager"] as? String == "agents" {
      let (_, servers) = try agents(args["project"] as? String)
      return textResult(
        servers.map {
          [
            "name": $0.key, "manager": "agents",
            "transport": ($0.value as? JSONObject)?["transport"] ?? "stdio",
            "enabled": ($0.value as? JSONObject)?["enabled"] as? Bool != false,
          ] as JSONObject
        })
    }
    guard args["manager"] as? String == "smithery" else { throw SideportError("Unknown manager") }
    let ns = try await namespace(args)
    let result = try await smitheryValue(["mcp", "list", "--namespace", ns, "--limit", "1000"])
    let object = result as? JSONObject ?? [:]
    guard
      let rows = result as? [JSONObject] ?? (object["connections"] ?? object["servers"])
        as? [JSONObject]
    else {
      throw SideportError("Unsupported Smithery connection listing")
    }
    return textResult([
      "namespace": ns,
      "servers": rows.map {
        [
          "name": $0["connectionId"] ?? $0["id"] ?? $0["name"] ?? "", "manager": "smithery",
          "status": $0["status"] as? String ?? ($0["status"] as? JSONObject)?["state"] ?? "unknown",
        ] as JSONObject
      },
    ])
  }
  func start(_ args: JSONObject) async throws -> (ToolPeer, String?, [String]?, [String]?)? {
    let name = try Self.identifier(NativeDesktop.string(args, "name"))
    let reason = try NativeDesktop.string(args, "reason", maximum: 500)
    if args["manager"] as? String == "smithery" {
      let ns = try await namespace(args)
      guard
        try await approvals.capability(
          "managed_server",
          [
            "manager": "Smithery", "name": name, "mode": "service", "target": ns,
            "credentials": "Existing Smithery login",
            "scope":
              "The existing service’s permissions. The local file sandbox does not restrict it.",
          ], reason)
      else { return nil }
      return (SmitheryPeer(self, name, ns), nil, nil, nil)
    }
    guard args["manager"] as? String == "agents" else { throw SideportError("Unknown manager") }
    let (project, definitions) = try agents(args["project"] as? String)
    guard let definition = definitions[name] as? JSONObject, definition["enabled"] as? Bool != false
    else { throw SideportError("Server is missing or disabled") }
    guard
      ["oauth", "headersHelper", "envFile", "bearerTokenEnvVar"].allSatisfy({
        definition[$0] == nil
      })
    else {
      throw SideportError(
        "Configured authentication helpers are unsupported; use static headers or an existing Smithery connection"
      )
    }
    let rawEnv = definition["env"] as? [String: String] ?? [:]
    let available = ProcessInfo.processInfo.environment.merging(rawEnv) { _, new in new }
    func expand(_ value: String) throws -> String {
      guard value.utf8.count <= 16384,
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else { throw SideportError("Invalid configured value") }
      let regex = try NSRegularExpression(pattern: #"\$\{([^}]+)\}"#)
      var result = value
      for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        .reversed()
      {
        guard let range = Range(match.range, in: result),
          let keyRange = Range(match.range(at: 1), in: value)
        else { continue }
        let key = String(value[keyRange])
        let split = key.components(separatedBy: ":-")
        let replacement: String
        if key == "PROJECT_ROOT" {
          replacement = project
        } else if let value = available[split[0]] {
          replacement = value
        } else if split.count == 2 {
          replacement = split[1]
        } else {
          throw SideportError("A configured environment variable is missing")
        }
        guard !replacement.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw SideportError("Unsafe configured expansion") }
        result.replaceSubrange(range, with: replacement)
      }
      return result
    }
    var envValues: [String: String] = [:]
    for (key, value) in rawEnv {
      guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
        !GitHubPlan.matches(key, #"^(DYLD_|LD_|SIDEPORT_|MAC_CHATGPT_)"#)
      else { throw SideportError("Unsafe configured environment variable") }
      envValues[key] = try expand(value)
    }
    let allowed = definition["tools"] as? [String]
    let disabled = definition["disabledTools"] as? [String]
    guard definition["tools"] == nil || allowed != nil,
      definition["disabledTools"] == nil || disabled != nil
    else { throw SideportError("Invalid configured tool filters") }
    if let url = definition["url"] as? String {
      let endpoint = try RemoteEndpoint(expand(url), managed: true)
      var headers: [String: String] = [:]
      for (key, value) in definition["headers"] as? [String: String] ?? [:] {
        guard
          !["host", "content-length", "transfer-encoding", "connection", "proxy-authorization"]
            .contains(key.lowercased())
        else { throw SideportError("Unsafe managed header") }
        headers[key] = try expand(value)
      }
      guard
        try await approvals.capability(
          "managed_server",
          [
            "manager": "agents-dev", "name": name, "mode": "service", "target": endpoint.host,
            "credentials": headers.isEmpty ? "None" : "Configured service headers",
            "scope":
              "The existing service’s permissions. The local file sandbox does not restrict it.",
          ], reason)
      else { return nil }
      return (
        try RemotePeer(
          endpoint.url.absoluteString, supervisor: runtime.supervisor, scratch: runtime.scratch,
          managed: true, headers: headers), nil, allowed, disabled
      )
    }
    guard definition["transport"] == nil || definition["transport"] as? String == "stdio",
      let rawCommand = definition["command"] as? String
    else { throw SideportError("Only stdio and HTTP servers are supported") }
    let command = try expand(rawCommand)
    let candidates =
      command.contains("/")
      ? [
        URL(fileURLWithPath: command, relativeTo: URL(fileURLWithPath: project, isDirectory: true))
          .standardizedFileURL.path
      ]
      : (runtime.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + command }
    guard
      let executable = candidates.compactMap({ try? canonical($0, existing: true) }).first(
        where: FileManager.default.isExecutableFile)
    else { throw SideportError("Configured command is not installed") }
    let serverArgs = try NativeProviders.arguments(definition["args"] ?? [String]()).map {
      try expand($0)
    }
    let cwd = try canonical(
      (definition["cwd"] as? String).map { try expand($0) } ?? runtime.context.workspace,
      existing: true)
    let approved = try runtime.context.grants()
    guard runtime.context.permitted(cwd, "read", approved) else {
      throw SideportError("Approve the configured working folder first")
    }
    guard
      try await approvals.capability(
        "managed_server",
        [
          "manager": "agents-dev", "name": name, "mode": "sandbox",
          "target": URL(fileURLWithPath: executable).lastPathComponent,
          "credentials": envValues.keys.sorted().joined(separator: ", "),
          "scope":
            "Approved files and standard development caches, with network access. This server’s internal commands are not screened individually.",
        ], reason)
    else { return nil }
    let profile = runtime.context.session + "/" + UUID().uuidString + ".managed.json"
    try privateWrite(
      runtime.profile(
        approved, extra: [Grant(path: executable, kind: "file", access: "read")], network: true,
        deny: [project + "/.agents/local.json", runtime.context.home + "/.agents"]), profile)
    var env = runtime.environment.merging(envValues) { _, new in new }
    env["XDG_CONFIG_HOME"] = runtime.context.work + "/nono-config"
    env["XDG_STATE_HOME"] = runtime.context.work + "/nono-state"
    env["XDG_CACHE_HOME"] = runtime.context.work + "/nono-cache"
    do {
      return (
        try StdioPeer(
          runtime.supervisor, runtime.context.work + "/nono-bin/nono",
          ["run", "--silent", "--profile", profile, "--no-rollback", "--", executable] + serverArgs,
          environment: env, cwd: cwd), profile, allowed, disabled
      )
    } catch {
      try? FileManager.default.removeItem(atPath: profile)
      throw error
    }
  }
}
