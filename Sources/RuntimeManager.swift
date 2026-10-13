import CryptoKit
import Foundation

actor OptionalNode {
  let context: NativeContext, supervisor: ChildSupervisor
  var loading = false
  static let version = "26.5.0",
    checksum = "ee920559aaa2391569cff4d737e3b83963430e3a14dedd91bfe0ff53171b5af9"
  init(_ context: NativeContext, _ supervisor: ChildSupervisor) {
    self.context = context
    self.supervisor = supervisor
  }
  var cached: String { context.work + "/runtimes/node-" + Self.version }
  func ensure() async throws -> String {
    let legacy = context.work + "/node/bin/node"
    if FileManager.default.isExecutableFile(atPath: legacy) { return legacy }
    if FileManager.default.isExecutableFile(atPath: cached + "/bin/node") {
      return cached + "/bin/node"
    }
    guard !loading else { throw SideportError("Optional runtime download already in progress") }
    loading = true
    defer { loading = false }
    guard ProcessInfo.processInfo.machineArchitecture == "arm64" else {
      throw SideportError("This native alpha supports Apple Silicon")
    }
    let archiveName = "node-v" + Self.version + "-darwin-arm64.tar.gz"
    let config = URLSessionConfiguration.ephemeral
    config.urlCredentialStorage = nil
    let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(
      url: URL(string: "https://nodejs.org/dist/v" + Self.version + "/" + archiveName)!)
    request.timeoutInterval = 120
    let (archive, response) = try await session.download(for: request)
    defer { try? FileManager.default.removeItem(at: archive) }
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      (((try FileManager.default.attributesOfItem(atPath: archive.path)[.size]) as? NSNumber)?
        .intValue ?? Int.max) < 104_857_600
    else { throw SideportError("Optional runtime download failed") }
    let handle = try FileHandle(forReadingFrom: archive)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 65536), !data.isEmpty { hash.update(data: data) }
    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == Self.checksum else {
      throw SideportError("Optional Node checksum mismatch")
    }
    let stage = context.work + "/runtimes/.stage-" + UUID().uuidString
    try directory(stage)
    defer { try? FileManager.default.removeItem(atPath: stage) }
    let env = ["HOME": context.home, "PATH": "/usr/bin:/bin"]
    let prefix = "node-v" + Self.version + "-darwin-arm64/"
    try await ReleaseArchive.extract(
      archive.path, to: stage, runner: supervisor, ignoringNodeBinLinks: true)
    try directory(context.work + "/runtimes")
    try FileManager.default.moveItem(
      atPath: stage + "/" + String(prefix.dropLast()), toPath: cached)
    let verify = try await supervisor.run(
      cached + "/bin/node", ["--version"], environment: env, cwd: cached, timeout: 5)
    guard verify.code == 0,
      String(decoding: verify.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        == "v" + Self.version
    else {
      try? FileManager.default.removeItem(atPath: cached)
      throw SideportError("Runtime validation failed")
    }
    return cached + "/bin/node"
  }
  func npm() async throws -> (String, String) {
    let node = try await ensure()
    return (
      node,
      URL(fileURLWithPath: node).deletingLastPathComponent().deletingLastPathComponent().path
        + "/lib/node_modules/npm/bin/npm-cli.js"
    )
  }
}
extension ProcessInfo {
  var machineArchitecture: String {
    var system = utsname()
    uname(&system)
    let size = MemoryLayout.size(ofValue: system.machine)
    return withUnsafePointer(to: &system.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
    }
  }
}
