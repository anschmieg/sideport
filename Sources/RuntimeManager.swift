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

// Go before 1.27 ignores SSL_CERT_FILE on macOS. Use the installed CLI when it
// supports explicit CA bundles; otherwise cache an unmodified official release.
actor CompatibleGitHub {
  static let version = "2.102.0"
  static let checksum = "da922c20d1792e5b2cbf375593d7a658acf034c12c84e007e71c76ef959c337e"
  let runtime: RuntimeSupport
  var loading = false
  var prepared: String?
  init(_ runtime: RuntimeSupport) { self.runtime = runtime }
  nonisolated static func supportsCertificateBundle(_ path: String) -> Bool {
    guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
      bytes.count < 80_000_000,
      let header = bytes.range(of: Data([255] + Array(" Go buildinf:".utf8))),
      header.lowerBound + 33 < bytes.count,
      bytes[header.lowerBound + 15] & 2 != 0
    else { return false }
    var offset = header.lowerBound + 32
    var length = 0
    for shift in stride(from: 0, through: 28, by: 7) {
      guard offset < bytes.count else { return false }
      let byte = bytes[offset]
      offset += 1
      length |= Int(byte & 127) << shift
      if byte & 128 == 0 { break }
    }
    guard (1...64).contains(length), offset + length <= bytes.count,
      let version = String(data: bytes[offset..<offset + length], encoding: .utf8),
      GitHubPlan.matches(version, #"^go1\.\d+(?:\.\d+)?$"#),
      let minor = Int(version.dropFirst(4).split(separator: ".")[0])
    else { return false }
    return minor >= 27
  }
  func ensure() async throws -> String {
    if let prepared { return prepared }
    guard let installed = runtime.trustedTools["gh"] else {
      throw SideportError("Install GitHub CLI and sign in locally first")
    }
    if Self.supportsCertificateBundle(installed) {
      prepared = installed
      return installed
    }
    guard !loading else {
      throw SideportError("GitHub compatibility helper is being prepared; retry shortly")
    }
    loading = true
    defer { loading = false }
    let cached = runtime.context.work + "/runtimes/github-" + Self.version
    if !FileManager.default.isExecutableFile(atPath: cached + "/gh") {
      let stage = runtime.context.work + "/runtimes/.gh-stage-" + UUID().uuidString
      try directory(stage)
      defer { try? FileManager.default.removeItem(atPath: stage) }
      let name = "gh_" + Self.version + "_macOS_arm64.zip"
      let archive = stage + "/" + name
      let download = try await runtime.supervisor.run(
        "/usr/bin/curl",
        [
          "--disable", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
          "--proto-redir", "=https", "--max-time", "120", "--max-filesize", "30000000", "--output",
          archive,
          "https://github.com/cli/cli/releases/download/v" + Self.version + "/" + name,
        ], environment: ["HOME": runtime.context.home, "PATH": "/usr/bin:/bin"], cwd: stage,
        timeout: 125)
      guard download.code == 0, !download.stopped else {
        throw SideportError("Official GitHub helper download failed")
      }
      let bytes = try Data(contentsOf: URL(fileURLWithPath: archive), options: .mappedIfSafe)
      guard bytes.count <= 30_000_000,
        SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == Self.checksum
      else { throw SideportError("Official GitHub helper checksum mismatch") }
      try directory(stage + "/unpacked")
      try await ReleaseArchive.extract(archive, to: stage + "/unpacked", runner: runtime.supervisor)
      let source = stage + "/unpacked/gh_" + Self.version + "_macOS_arm64/bin/gh"
      guard Self.supportsCertificateBundle(source) else {
        throw SideportError("GitHub helper lacks required TLS support")
      }
      try directory(cached)
      try FileManager.default.copyItem(atPath: source, toPath: cached + "/gh")
      chmod(cached + "/gh", 0o500)
    }
    guard Self.supportsCertificateBundle(cached + "/gh") else {
      throw SideportError("Cached GitHub helper is incompatible")
    }
    let frozen = runtime.hostTools + "/github-" + Self.version
    try directory(frozen)
    try FileManager.default.copyItem(atPath: cached + "/gh", toPath: frozen + "/gh")
    chmod(frozen + "/gh", 0o500)
    prepared = frozen + "/gh"
    return prepared!
  }
}
