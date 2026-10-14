import Darwin
import Foundation

struct RemoteEndpoint {
  let url: URL
  let host: String
  let port: Int
  let managed: Bool
  init(_ value: String, managed: Bool = false) throws {
    guard value.utf8.count <= 2000,
      !value.unicodeScalars.contains(
        where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains),
      let parts = URLComponents(string: value), let url = parts.url, let encodedHost = parts.host,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
    else { throw SideportError("Invalid MCP endpoint") }
    let host =
      encodedHost.hasPrefix("[") && encodedHost.hasSuffix("]")
      ? String(encodedHost.dropFirst().dropLast()) : encodedHost
    let local = ["localhost", "127.0.0.1", "::1"].contains(host)
    guard
      (parts.scheme == "https" && (managed || parts.port == nil || parts.port == 443))
        || (managed && local && parts.scheme == "http")
    else { throw SideportError("Use public HTTPS without credentials or query parameters") }
    self.url = url
    self.host = host
    self.port = parts.port ?? (parts.scheme == "https" ? 443 : 80)
    self.managed = managed
  }
  static func publicAddress(_ address: String) -> Bool {
    if address.contains(":") {
      var parsed = in6_addr()
      guard inet_pton(AF_INET6, address, &parsed) == 1 else { return false }
      let bytes = withUnsafeBytes(of: &parsed) { Array($0) }
      guard bytes[0] & 0xe0 == 0x20 else { return false }
      if bytes[0] == 0x20, bytes[1] == 0x02 { return false }  // IPv4-embedding transition route.
      if bytes[0] == 0x20, bytes[1] == 0x01 {
        if bytes[2] <= 1 || (bytes[2] == 0x0d && bytes[3] == 0xb8) { return false }
      }
      if bytes[0] == 0x3f, bytes[1] == 0xff, bytes[2] <= 0x0f { return false }
      return true
    }
    let bytes = address.split(separator: ".").compactMap { Int($0) }
    guard bytes.count == 4, bytes.allSatisfy({ (0...255).contains($0) }) else { return false }
    let a = bytes[0]
    let b = bytes[1]
    return
      !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && (64...127).contains(b))
      || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b))
      || (a == 192 && [0, 168].contains(b)) || (a == 198 && [18, 19, 51].contains(b))
      || (a == 203 && b == 0))
  }
  func resolve() throws -> String {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0, let result else {
      throw SideportError("MCP endpoint DNS lookup failed")
    }
    defer { freeaddrinfo(result) }
    var addresses: [String] = []
    var entry: UnsafeMutablePointer<addrinfo>? = result
    while let current = entry {
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(
        current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil,
        0, NI_NUMERICHOST) == 0
      {
        addresses.append(String(cString: buffer))
      }
      entry = current.pointee.ai_next
    }
    guard !addresses.isEmpty, managed || addresses.allSatisfy(Self.publicAddress) else {
      throw SideportError("Local, private and reserved remote endpoints are blocked")
    }
    return addresses.first(where: { !$0.contains(":") }) ?? addresses[0]
  }
}
final class RemotePeer: ToolPeer, @unchecked Sendable {
  let endpoint: RemoteEndpoint
  let supervisor: ChildSupervisor
  let scratch: String
  let headers: [String: String]
  var version = "", session = "", closed = false
  init(
    _ url: String, supervisor: ChildSupervisor, scratch: String, managed: Bool = false,
    headers: [String: String] = [:]
  ) throws {
    endpoint = try RemoteEndpoint(url, managed: managed)
    self.supervisor = supervisor
    self.scratch = scratch
    self.headers = headers
    for (key, value) in headers {
      guard key.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil,
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        value.utf8.count <= 8192
      else { throw SideportError("Invalid managed HTTP header") }
    }
  }
  private func post(_ body: JSONObject, _ method: String, timeout: Double) async throws -> (
    JSONObject?, Int
  ) {
    guard !closed else { throw SideportError("Remote server stopped") }
    let address = try endpoint.resolve()
    let prefix = scratch + "/http-" + UUID().uuidString
    let config = prefix + ".conf"
    let input = prefix + ".json"
    defer {
      try? FileManager.default.removeItem(atPath: config)
      try? FileManager.default.removeItem(atPath: input)
    }
    var all = headers
    all["Content-Type"] = "application/json"
    all["Accept"] = "application/json, text/event-stream"
    all["Mcp-Method"] = method
    all["MCP-Protocol-Version"] =
      version.isEmpty || method == "server/discover" ? "2026-07-28" : version
    if !session.isEmpty, version != "2026-07-28" { all["Mcp-Session-Id"] = session }
    if let name = (body["params"] as? JSONObject)?["name"] as? String {
      guard !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw SideportError("Invalid tool name")
      }
      all["Mcp-Name"] = name
    }
    func quoted(_ value: String) -> String {
      "\""
        + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
          of: "\"", with: "\\\"") + "\""
    }
    let lines = all.sorted { $0.key < $1.key }.map {
      "header = " + quoted($0.key + ": " + $0.value)
    }.joined(separator: "\n")
    try Data(lines.utf8).write(to: URL(fileURLWithPath: config), options: .atomic)
    chmod(config, 0o600)
    try privateWrite(body, input)
    let resolved = address.contains(":") ? "[" + address + "]" : address
    let pin =
      endpoint.host.contains(":")
      ? [] : ["--resolve", endpoint.host + ":" + String(endpoint.port) + ":" + resolved]
    let output = try await supervisor.run(
      "/usr/bin/curl",
      [
        "--disable", "--config", config, "--silent", "--show-error", "--noproxy", "*", "--proto",
        endpoint.url.scheme == "https" ? "=https" : "=http",
      ] + pin + [
        "--max-time", String(timeout),
        "--max-filesize", "4194304", "--include", "--request", "POST", "--data-binary", "@" + input,
        endpoint.url.absoluteString,
      ], environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()], cwd: scratch,
      timeout: timeout + 1, limit: 4_300_000)
    guard output.code == 0, !output.stopped, let text = String(data: output.stdout, encoding: .utf8)
    else { throw SideportError("Remote MCP request failed") }
    var remainder = text
    var header = ""
    // curl may emit an HTTP 100 block before the final response.
    while remainder.hasPrefix("HTTP/") {
      guard let split = remainder.range(of: "\r\n\r\n") else {
        throw SideportError("Invalid HTTP response")
      }
      header = String(remainder[..<split.lowerBound])
      remainder = String(remainder[split.upperBound...])
    }
    guard
      let status = Int(
        header.split(separator: "\n").first?.split(separator: " ").dropFirst().first ?? "")
    else { throw SideportError("Invalid HTTP status") }
    guard (200..<300).contains(status) else {
      throw RPCFailure(code: status, message: "Remote MCP HTTP \(status)")
    }
    for line in header.components(separatedBy: "\r\n").dropFirst() {
      let p = line.split(separator: ":", maxSplits: 1)
      if p.count == 2, p[0].lowercased() == "mcp-session-id" {
        session = p[1].trimmingCharacters(in: .whitespaces)
        guard session.utf8.count <= 1024 else {
          throw SideportError("Remote session identifier too large")
        }
      }
    }
    if body["id"] == nil { return (nil, status) }
    let id = body["id"] as? String
    var payload: JSONObject?
    if header.lowercased().contains("text/event-stream") {
      for event in remainder.replacingOccurrences(of: "\r\n", with: "\n").components(
        separatedBy: "\n\n")
      {
        let data = event.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map {
          String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
        if let item = try? jsonObject(Data(data.utf8)), item["id"] as? String == id {
          payload = item
        }
      }
    } else {
      payload = try jsonObject(Data(remainder.utf8))
    }
    guard let payload, payload["id"] as? String == id else {
      throw SideportError("Remote response identifier mismatch")
    }
    if let error = payload["error"] as? JSONObject {
      throw RPCFailure(
        code: error["code"] as? Int ?? -32603,
        message: error["message"] as? String ?? "Remote provider error")
    }
    return (payload["result"] as? JSONObject ?? [:], status)
  }
  func request(_ method: String, _ params: JSONObject, timeout: Double = 30) async throws
    -> JSONObject
  {
    var params = params
    if version == "2026-07-28" || method == "server/discover" {
      params["_meta"] =
        [
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientInfo": ["name": "Sideport", "version": "0.3.4"],
          "io.modelcontextprotocol/clientCapabilities": [:],
        ] as JSONObject
    }
    return try await post(
      ["jsonrpc": "2.0", "id": UUID().uuidString, "method": method, "params": params], method,
      timeout: timeout
    ).0 ?? [:]
  }
  func connect() async throws {
    do {
      let discovery = try await request("server/discover", [:], timeout: 4)
      if (discovery["supportedVersions"] as? [String])?.contains("2026-07-28") == true {
        version = "2026-07-28"
        return
      }
    } catch let error as RPCFailure {
      guard [400, 404, 405, 406, 415, -32601, -32602, -32022].contains(error.code) else {
        throw error
      }
    }
    let result = try await request(
      "initialize",
      [
        "protocolVersion": "2025-11-25", "capabilities": [:],
        "clientInfo": ["name": "Sideport", "version": "0.3.4"],
      ], timeout: 30)
    guard let version = result["protocolVersion"] as? String,
      ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"].contains(version)
    else { throw SideportError("Unsupported MCP protocol") }
    self.version = version
    _ = try await post(
      ["jsonrpc": "2.0", "method": "notifications/initialized"], "notifications/initialized",
      timeout: 30)
  }
  func close() { closed = true }
}
