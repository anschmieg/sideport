import Darwin
import Foundation

final class RememberedLocations {
  struct Entry: Codable {
    let path: String
    let kind: String
    let access: String
    let device: UInt64
    let inode: UInt64
    var grant: [String: String] { ["path": path, "kind": kind, "access": access] }
  }
  struct State: Codable {
    let version: Int
    var locations: [Entry]
  }
  let file: URL
  let controller: String
  init(file: URL, controller: String) {
    self.file = file
    self.controller = Self.resolve(controller) ?? controller
  }
  static func resolve(_ value: String) -> String? {
    guard let resolved = realpath(value, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
  func allowed(_ path: String) -> Bool {
    path.hasPrefix("/") && path.count <= 4096
      && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      && path != controller && !path.hasPrefix(controller + "/")
      && !controller.hasPrefix(path == "/" ? "/" : path + "/")
  }
  func identity(_ path: String, kind: String) throws -> (UInt64, UInt64) {
    guard allowed(path), Self.resolve(path) == path else { throw CocoaError(.fileReadNoPermission) }
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard
      attributes[.type] as? FileAttributeType
        == (kind == "directory" ? .typeDirectory : .typeRegular),
      let device = attributes[.systemNumber] as? NSNumber,
      let inode = attributes[.systemFileNumber] as? NSNumber
    else { throw CocoaError(.fileReadCorruptFile) }
    return (device.uint64Value, inode.uint64Value)
  }
  func read() throws -> [Entry] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let data = try Data(contentsOf: file)
    guard data.count <= 131072 else { throw CocoaError(.fileReadTooLarge) }
    let state = try JSONDecoder().decode(State.self, from: data)
    guard state.version == 1, state.locations.count <= 256 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return state.locations.filter { entry in
      guard ["read", "read_write"].contains(entry.access),
        ["file", "directory"].contains(entry.kind),
        let current = try? identity(entry.path, kind: entry.kind)
      else { return false }
      return current.0 == entry.device && current.1 == entry.inode
    }
  }
  func write(_ entries: [Entry]) throws {
    guard entries.count <= 256 else { throw CocoaError(.fileWriteOutOfSpace) }
    let data = try JSONEncoder().encode(State(version: 1, locations: entries))
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
  func remember(path: String, kind: String, access: String) throws {
    guard ["file", "directory"].contains(kind), ["read", "read_write"].contains(access) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let current = try identity(path, kind: kind)
    var entries = try read()
    let existing = entries.first(where: { $0.path == path })
    entries.removeAll { $0.path == path }
    entries.append(
      Entry(
        path: path, kind: kind, access: existing?.access == "read_write" ? "read_write" : access,
        device: current.0, inode: current.1))
    try write(entries)
  }
  func forget(_ path: String) throws { try write(read().filter { $0.path != path }) }
}
