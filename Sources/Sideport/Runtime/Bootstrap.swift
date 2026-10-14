import Darwin
import Foundation

enum SideportBootstrap {
  static let version = "0.3.4"
  static let payload = ["mcpproxy-bin", "nono-bin", "tunnel-client", "permission-broker"]
  static func prepare() throws {
    let root =
      ProcessInfo.processInfo.environment["SIDEPORT_HOME"] ?? NSHomeDirectory()
      + "/Library/Application Support/Sideport"
    let work = root + "/work"
    let marker = work + "/bundle-version.json"
    if let state = try? jsonObject(Data(contentsOf: URL(fileURLWithPath: marker))),
      state["version"] as? String == version
    {
      return
    }
    guard !FileManager.default.fileExists(atPath: work + "/mcpproxy-runtime.key") else {
      throw SideportError("Disconnect the installed Sideport before updating its runtime")
    }
    let resources = NativeResources.directory.appendingPathComponent("Runtime/work").path
    guard payload.allSatisfy({ FileManager.default.fileExists(atPath: resources + "/" + $0) })
    else { throw SideportError("Bundled dependencies are missing") }
    try directory(root)
    try directory(work)
    let lease = try ControllerLease(root)
    defer { withExtendedLifetime(lease) {} }
    let lock = work + "/bundle-install.lock"
    let fd = open(lock, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw SideportError("Another installation is in progress") }
    defer {
      Darwin.close(fd)
      try? FileManager.default.removeItem(atPath: lock)
    }
    let stage = work + "/bundle-stage-" + UUID().uuidString
    let backup = work + "/bundle-previous"
    try directory(stage)
    try directory(backup)
    defer { try? FileManager.default.removeItem(atPath: stage) }
    for item in payload {
      try FileManager.default.copyItem(atPath: resources + "/" + item, toPath: stage + "/" + item)
    }
    var installed: [String] = []
    let stateFiles = [
      "mcpproxy-pilot/config.json", "bundle-version.json",
      "mcpproxy-release.json", "nono-release.json", "tunnel-release.json", "dcg-release.json",
    ]
    var originalFiles: [String: Data] = [:]
    for item in stateFiles where FileManager.default.fileExists(atPath: work + "/" + item) {
      originalFiles[item] = try Data(contentsOf: URL(fileURLWithPath: work + "/" + item))
    }
    do {
      for item in payload {
        let current = work + "/" + item
        let previous = backup + "/" + item
        try? FileManager.default.removeItem(atPath: previous)
        if FileManager.default.fileExists(atPath: current) {
          try FileManager.default.moveItem(atPath: current, toPath: previous)
        }
        installed.append(item)
        try FileManager.default.moveItem(atPath: stage + "/" + item, toPath: current)
      }
      for name in ["permission-sessions", "tunnel-profiles"] { try directory(work + "/" + name) }
      let configPath = work + "/mcpproxy-pilot/config.json"
      if !FileManager.default.fileExists(atPath: configPath) {
        try directory(work + "/mcpproxy-pilot")
        var template = try jsonObject(
          Data(contentsOf: NativeResources.directory.appendingPathComponent("config-template.json"))
        )
        var random = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&random, random.count)
        template["api_key"] = random.map { String(format: "%02x", $0) }.joined()
        template["data_dir"] = work + "/mcpproxy-pilot"
        try privateWrite(template, configPath)
      }
      for name in [
        "mcpproxy-release.json", "nono-release.json", "tunnel-release.json", "dcg-release.json",
      ] {
        let source = NativeResources.directory.appendingPathComponent("Runtime/work/" + name)
        let metadata = try jsonObject(Data(contentsOf: source))
        try privateWrite(metadata, work + "/" + name)
      }
      try privateWrite(["version": version], marker)
    } catch {
      var failures: [String] = []
      for item in installed.reversed() {
        do {
          if FileManager.default.fileExists(atPath: work + "/" + item) {
            try FileManager.default.removeItem(atPath: work + "/" + item)
          }
          if FileManager.default.fileExists(atPath: backup + "/" + item) {
            try FileManager.default.moveItem(atPath: backup + "/" + item, toPath: work + "/" + item)
          }
        } catch { failures.append(item) }
      }
      for item in stateFiles {
        do {
          if let previous = originalFiles[item] {
            try previous.write(to: URL(fileURLWithPath: work + "/" + item), options: .atomic)
            chmod(work + "/" + item, 0o600)
          } else if FileManager.default.fileExists(atPath: work + "/" + item) {
            try FileManager.default.removeItem(atPath: work + "/" + item)
          }
        } catch { failures.append(item) }
      }
      if !failures.isEmpty {
        throw SideportError(
          "Installation rollback failed for " + failures.joined(separator: ", ")
            + ". Backups remain at " + backup)
      }
      throw error
    }
  }
}
