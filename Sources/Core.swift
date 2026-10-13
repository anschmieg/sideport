import CryptoKit
import Darwin
import Foundation

typealias JSONObject = [String: Any]
struct SideportError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
func jsonData(_ value: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
}
func jsonObject(_ data: Data, limit: Int = 4_194_304) throws -> JSONObject {
  guard data.count <= limit,
    let result = try JSONSerialization.jsonObject(with: data) as? JSONObject
  else { throw SideportError("Invalid JSON object") }
  return result
}
func textResult(_ value: Any, error: Bool = false) -> JSONObject {
  [
    "content": [
      [
        "type": "text",
        "text": (try? String(data: jsonData(value), encoding: .utf8)) ?? "Invalid response",
      ]
    ], "isError": error,
  ]
}
func privateWrite(_ value: Any, _ path: String) throws {
  let data = try jsonData(value)
  try data.write(to: URL(fileURLWithPath: path), options: .atomic)
  guard chmod(path, 0o600) == 0 else { throw SideportError("Could not protect private state") }
}
func secretRedacted(_ text: String) -> String {
  text.replacingOccurrences(
    of: #"(?:gh[opusr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)"#, with: "[credential redacted]",
    options: .regularExpression)
}
func directory(_ path: String) throws {
  try FileManager.default.createDirectory(
    atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
}
func inside(_ child: String, _ parent: String) -> Bool {
  child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/")
}
func canonical(_ value: String, existing: Bool = false) throws -> String {
  guard value.count <= 4096,
    !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
    value.hasPrefix("/") || value.hasPrefix("~/")
  else { throw SideportError("Use an absolute path or ~/path") }
  let path = NSString(string: value).expandingTildeInPath
  if let resolved = realpath(path, nil) {
    defer { free(resolved) }
    return String(cString: resolved)
  }
  guard !existing, errno == ENOENT else {
    throw SideportError("Location does not exist or cannot be resolved")
  }
  let url = URL(fileURLWithPath: path)
  let parent = try canonical(url.deletingLastPathComponent().path, existing: true)
  return URL(fileURLWithPath: parent).appendingPathComponent(url.lastPathComponent).path
}
struct Grant: Codable, Equatable {
  let path: String
  let kind: String
  let access: String
  var dictionary: JSONObject { ["path": path, "kind": kind, "access": access] }
}
struct NativeContext {
  let root: String
  let session: String
  let home = NSHomeDirectory()
  var work: String { root + "/work" }
  var executable: String {
    let path =
      ProcessInfo.processInfo.environment["SIDEPORT_APP_EXECUTABLE"] ?? Bundle.main.executablePath
      ?? CommandLine.arguments[0]
    return (try? canonical(path, existing: true)) ?? path
  }
  var workspace: String {
    ProcessInfo.processInfo.environment["SIDEPORT_WORKSPACE"] ?? home
      + "/Documents/ChatGPT Workspace"
  }
  var codeLocation: String {
    let path = (try? canonical(executable, existing: true)) ?? executable
    let components = path.components(separatedBy: "/")
    if let app = components.firstIndex(where: { $0.hasSuffix(".app") }) {
      return components.prefix(app + 1).joined(separator: "/")
    }
    return path
  }
  init(root: String? = nil, session: String? = nil) throws {
    self.root = try canonical(
      root ?? ProcessInfo.processInfo.environment["SIDEPORT_HOME"] ?? NSHomeDirectory()
        + "/Library/Application Support/Sideport", existing: true)
    self.session = session ?? ProcessInfo.processInfo.environment["MAC_CHATGPT_APPROVAL_DIR"] ?? ""
    guard self.session.hasPrefix(self.root + "/work/permission-sessions/"),
      try canonical(self.session, existing: true) == self.session
    else { throw SideportError("Launch the broker from Sideport") }
  }
  func checkGrant(_ path: String) throws {
    guard !inside(path, root), !inside(root, path) else {
      throw SideportError(
        "This location contains Sideport’s controller or credentials. Choose a separate folder.")
    }
    guard !inside(path, codeLocation) else {
      throw SideportError("Sideport’s application code cannot be granted to an agent")
    }
  }
  func grants() throws -> [Grant] {
    let data = try Data(contentsOf: URL(fileURLWithPath: session + "/grants.json"))
    guard data.count <= 131072 else { throw SideportError("Permission state too large") }
    let state = try JSONDecoder().decode([Grant].self, from: data)
    guard state.count <= 256 else { throw SideportError("Too many grants") }
    return try state.compactMap { grant in
      guard ["read", "read_write"].contains(grant.access),
        ["file", "directory"].contains(grant.kind)
      else { throw SideportError("Invalid local grant") }
      guard FileManager.default.fileExists(atPath: grant.path) else { return nil }
      guard try canonical(grant.path, existing: true) == grant.path else {
        throw SideportError("Approved location changed; reconnect")
      }
      try checkGrant(grant.path)
      let attributes = try FileManager.default.attributesOfItem(atPath: grant.path)
      guard
        attributes[.type] as? FileAttributeType
          == (grant.kind == "directory" ? .typeDirectory : .typeRegular)
      else { throw SideportError("Approved location type changed") }
      return grant
    }
  }
  func permitted(_ location: String, _ access: String, _ grants: [Grant]) -> Bool {
    grants.contains {
      ($0.kind == "directory" ? inside(location, $0.path) : location == $0.path)
        && (access == "read" || $0.access == "read_write")
    }
  }
  var denied: [String] {
    let publicDirectories = Set([
      "node", "runtimes", "provider-cache", "nono-bin", "mcpproxy-bin", "tunnel-client",
      "permission-broker", "baseline", "host-tools",
    ])
    let rootEntries = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
    let workEntries = (try? FileManager.default.contentsOfDirectory(atPath: work)) ?? []
    let controls =
      rootEntries.filter { $0 != "work" }.map { root + "/" + $0 }
      + workEntries.filter { !publicDirectories.contains($0) }.map { work + "/" + $0 }
    return controls + [
      work + "/permission-sessions", work + "/mcpproxy-pilot", work + "/sideport-signing",
      work + "/approval-reviewer.key", work + "/approval-reviewer.json",
      work + "/tunnel-runtime.key", work + "/mcpproxy-runtime.key", home + "/.ssh",
      home + "/Library/Keychains", home + "/.aws", home + "/.config/gcloud", home + "/.npmrc",
      home + "/.cargo/credentials", home + "/.cargo/credentials.toml", home + "/.config/gh",
      home + "/.smithery", home + "/.config/smithery",
    ]
  }
}

// Foundation's counted reads may wait to fill a pipe buffer. RPC needs each
// available chunk immediately, including a short JSON-RPC request.
func pipeChunk(_ handle: FileHandle, maximum: Int = 16384) throws -> Data? {
  var bytes = [UInt8](repeating: 0, count: maximum)
  while true {
    let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
    if count > 0 { return Data(bytes.prefix(count)) }
    if count == 0 { return nil }
    if errno == EINTR { continue }
    throw SideportError("Pipe read failed")
  }
}
