import Foundation

enum ReleaseArchive {
  // bsdtar understands both ZIP and tar. Refuse links and special entries
  // before extraction, including hard links, duplicate names and control bytes.
  static func validate(_ names: String, _ listing: String) throws -> [String] {
    let entries = names.split(separator: "\n", omittingEmptySubsequences: false)
      .dropLast(names.hasSuffix("\n") ? 1 : 0).map(String.init)
    let rows = listing.split(separator: "\n")
    guard !entries.isEmpty, entries.count <= 10000, entries.count == rows.count else {
      throw SideportError("Invalid archive size or listing")
    }
    var seen = Set<String>()
    for (entry, row) in zip(entries, rows) {
      let components = entry.split(separator: "/").filter { $0 != "." }
      let normalized = components.isEmpty ? "." : components.joined(separator: "/")
      guard !entry.hasPrefix("/"), !entry.contains("\\"), !components.contains(".."),
        !entry.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        !entry.isEmpty, normalized != "." || row.first == "d", seen.insert(normalized).inserted,
        row.first == "-" || row.first == "d"
      else { throw SideportError("Archive links, special files and unsafe paths are refused") }
    }
    return entries
  }
  static func extract(
    _ archive: String, to destination: String, runner: ChildSupervisor,
    ignoringNodeBinLinks: Bool = false
  ) async throws {
    let env = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
    let names = try await runner.run(
      "/usr/bin/tar", ["-tf", archive], environment: env,
      cwd: destination, timeout: 30, limit: 8_388_608)
    let listing = try await runner.run(
      "/usr/bin/tar", ["-tvf", archive], environment: env,
      cwd: destination, timeout: 30, limit: 8_388_608)
    guard names.code == 0, listing.code == 0, !names.stopped, !listing.stopped else {
      throw SideportError("Archive inspection failed")
    }
    var nameLines = String(decoding: names.stdout, as: UTF8.self).split(separator: "\n").map(
      String.init)
    var rows = String(decoding: listing.stdout, as: UTF8.self).split(separator: "\n").map(
      String.init)
    var excluded: [String] = []
    if ignoringNodeBinLinks {
      guard nameLines.count == rows.count else { throw SideportError("Invalid runtime archive") }
      let prefix = "node-v" + OptionalNode.version + "-darwin-arm64/"
      for index in nameLines.indices.reversed() where rows[index].first == "l" {
        let name = nameLines[index]
        guard [prefix + "bin/npm", prefix + "bin/npx"].contains(name) else {
          throw SideportError("Unexpected runtime archive link")
        }
        excluded.append(name)
        nameLines.remove(at: index)
        rows.remove(at: index)
      }
      guard nameLines.allSatisfy({ $0.hasPrefix(prefix) }) else {
        throw SideportError("Invalid runtime archive prefix")
      }
    }
    _ = try validate(nameLines.joined(separator: "\n") + "\n", rows.joined(separator: "\n") + "\n")
    let result = try await runner.run(
      "/usr/bin/tar",
      ["-xf", archive, "-C", destination, "--no-same-owner", "--no-same-permissions"]
        + excluded.flatMap { ["--exclude", $0] }, environment: env, cwd: destination, timeout: 30)
    guard result.code == 0, !result.stopped else {
      throw SideportError("Archive extraction failed")
    }
    guard let enumerator = FileManager.default.enumerator(atPath: destination) else {
      throw SideportError("Archive output missing")
    }
    var total: UInt64 = 0
    for item in DependencyUpdater.paths(enumerator) {
      let attrs = try FileManager.default.attributesOfItem(atPath: destination + "/" + item)
      let type = attrs[.type] as? FileAttributeType
      guard type == .typeDirectory || type == .typeRegular else {
        throw SideportError("Unexpected extracted file type")
      }
      total += (attrs[.size] as? NSNumber)?.uint64Value ?? 0
      guard total <= 1_073_741_824 else { throw SideportError("Expanded archive is too large") }
    }
  }
}
