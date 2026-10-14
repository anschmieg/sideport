import CoreFoundation
import Foundation

// Read the maintained runtime's live dispatcher, not MCP session history or
// pooled local TCP sockets. Polling and idle workers do not count as clients.
enum TunnelPresence {
  static func endpoint(_ raw: String) throws -> URL {
    guard let url = URL(string: raw), url.scheme == "http", url.host == "127.0.0.1",
      let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/"
    else { throw SideportError("Tunnel health must use IPv4 loopback") }
    return url.appendingPathComponent("health/dispatcher")
  }
  static func active(_ response: JSONObject, now: Date = Date()) throws -> Int {
    guard response["schema_version"] as? Int == 1,
      response["component"] as? String == "dispatcher",
      let status = response["status"] as? String, ["ok", "degraded"].contains(status),
      let state = response["state"] as? String, ["accepting", "draining"].contains(state),
      let stamp = response["snapshot_at"] as? String,
      let details = response["details"] as? JSONObject,
      let active = details["active"] as? NSNumber,
      CFGetTypeID(active) != CFBooleanGetTypeID(),
      active.doubleValue.isFinite, active.doubleValue >= 0, active.doubleValue <= 10000,
      active.doubleValue.rounded() == active.doubleValue
    else { throw SideportError("Tunnel live-operation status is unavailable") }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = formatter.date(from: stamp)
    if date == nil {
      formatter.formatOptions = [.withInternetDateTime]
      date = formatter.date(from: stamp)
    }
    guard let date, (-1...5).contains(now.timeIntervalSince(date)) else {
      throw SideportError("Tunnel live-operation snapshot is stale")
    }
    return active.intValue
  }
  static func read(_ raw: String) async throws -> Int {
    let url = try endpoint(raw)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 1
    config.timeoutIntervalForResource = 2
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.connectionProxyDictionary = [:]
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(from: url)
    guard data.count <= 32768, let response = response as? HTTPURLResponse,
      response.statusCode == 200, response.url == url
    else { throw SideportError("Invalid tunnel live-operation response") }
    return try active(jsonObject(data, limit: 32768))
  }
  static func clientLabel(_ root: URL) -> String {
    if let data = try? Data(contentsOf: root.appendingPathComponent("work/client-label.json")),
      data.count <= 1024, let settings = try? jsonObject(data),
      let label = settings["label"] as? String,
      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return AgentPresence.name(label)
    }
    // The bundled connection setup currently targets the ChatGPT connector.
    // This is a local display label, never proof of remote identity.
    return "ChatGPT"
  }
}
