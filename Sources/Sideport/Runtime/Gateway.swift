import Darwin
import Foundation

struct GatewayAdmin {
  let root: String
  let key: String
  let endpoint: String
  init(_ root: String) throws {
    self.root = root
    let config = try jsonObject(
      Data(contentsOf: URL(fileURLWithPath: root + "/work/mcpproxy-pilot/config.json")))
    guard let key = config["api_key"] as? String, !key.isEmpty, key.utf8.count <= 256 else {
      throw SideportError("Gateway settings are incomplete")
    }
    guard let listen = config["listen"] as? String, let url = URL(string: "http://" + listen),
      url.host == "127.0.0.1", let port = url.port, (1...65535).contains(port), url.path.isEmpty,
      url.query == nil, url.fragment == nil, url.user == nil, url.password == nil
    else { throw SideportError("Gateway must listen on IPv4 loopback") }
    endpoint = url.absoluteString
    self.key = key
  }
  func api(_ method: String, _ route: String, _ body: JSONObject? = nil) async throws -> JSONObject
  {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: endpoint + route)!)
    request.httpMethod = method
    request.setValue(key, forHTTPHeaderField: "X-API-Key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let body { request.httpBody = try jsonData(body) }
    let (data, response) = try await session.data(for: request)
    guard data.count <= 4_194_304, let response = response as? HTTPURLResponse else {
      throw SideportError("Invalid local gateway response")
    }
    if method == "DELETE", response.statusCode == 404 { return [:] }
    guard (200..<300).contains(response.statusCode) else {
      throw SideportError("Local gateway request failed (\(response.statusCode))")
    }
    return data.isEmpty ? [:] : try jsonObject(data)
  }
  func credential(revoke: Bool) async throws {
    _ = try await api("DELETE", "/api/v1/tokens/mac-chatgpt-session/permanent")
    let destination = root + "/work/mcpproxy-runtime.key"
    if revoke {
      try? FileManager.default.removeItem(atPath: destination)
      return
    }
    guard
      let expected = try JSONSerialization.jsonObject(
        with: Data(contentsOf: NativeResources.directory.appendingPathComponent("Tools.json")))
        as? [JSONObject]
    else { throw SideportError("Bundled tools missing") }
    var tools: [JSONObject] = []
    for _ in 0..<30 {
      let response = try await api("GET", "/api/v1/servers/permissions/tools")
      tools = (response["data"] as? JSONObject)?["tools"] as? [JSONObject] ?? []
      if tools.count == expected.count { break }
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    guard tools.count == expected.count else {
      throw SideportError("Gateway tools have not loaded")
    }
    for tool in expected {
      guard let name = tool["name"] as? String,
        let match = tools.first(where: { $0["name"] as? String == name }),
        match["description"] as? String == tool["description"] as? String,
        try jsonData(match["schema"] ?? [:]) == jsonData(tool["inputSchema"] ?? [:])
      else {
        throw SideportError(
          "Gateway tools differ from the bundled definitions; connection stays off")
      }
    }
    _ = try await api(
      "POST", "/api/v1/servers/permissions/tools/approve",
      ["tools": expected.compactMap { $0["name"] as? String }])
    let response = try await api(
      "POST", "/api/v1/tokens",
      [
        "name": "mac-chatgpt-session", "allowed_servers": ["permissions"],
        "permissions": ["read", "write", "destructive"], "expires_in": "365d",
      ])
    guard let token = (response["data"] as? JSONObject ?? response)["token"] as? String,
      token.hasPrefix("mcp_agt_"), !token.contains(where: { $0.isWhitespace })
    else { throw SideportError("Invalid scoped gateway credential") }
    try Data((token + "\n").utf8).write(to: URL(fileURLWithPath: destination), options: .atomic)
    chmod(destination, 0o600)
  }
}
