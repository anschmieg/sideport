import Foundation

actor LocalApprovals {
  let context: NativeContext
  var pending = false
  init(_ context: NativeContext) { self.context = context }
  func capability(_ name: String, _ details: JSONObject, _ reason: String) async throws -> Bool {
    guard !pending else { throw SideportError("Another approval is pending") }
    guard !reason.isEmpty, reason.count <= 500,
      !reason.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw SideportError("Invalid approval reason") }
    pending = true
    defer { pending = false }
    let id = UUID().uuidString
    let base = context.session + "/" + id
    let request: JSONObject = [
      "id": id, "capability": name, "details": details, "reason": reason,
      "expires": Date().addingTimeInterval(90).timeIntervalSince1970 * 1000,
    ]
    guard try jsonData(request).count < 8000 else {
      throw SideportError("Approval details too large")
    }
    try privateWrite(request, base + ".capability.json")
    defer {
      try? FileManager.default.removeItem(atPath: base + ".capability.json")
      try? FileManager.default.removeItem(atPath: base + ".decision.json")
    }
    for _ in 0..<360 {
      try Task.checkCancellation()
      if let data = try? Data(contentsOf: URL(fileURLWithPath: base + ".decision.json")),
        let answer = try? jsonObject(data, limit: 8192)
      {
        guard answer["id"] as? String == id, answer["capability"] as? String == name else {
          throw SideportError("Invalid local approval")
        }
        return answer["approved"] as? Bool == true
      }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    return false
  }
  func access(_ location: String, _ access: String, _ reason: String) async throws -> JSONObject {
    guard ["read", "read_write"].contains(access), !pending else {
      throw SideportError("Invalid or overlapping access request")
    }
    try context.checkGrant(location)
    if context.permitted(location, access, try context.grants()) {
      return textResult(["status": "already_allowed", "path": location])
    }
    guard !reason.isEmpty, reason.count <= 500,
      !reason.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw SideportError("Invalid access reason") }
    pending = true
    defer { pending = false }
    let id = UUID().uuidString
    let base = context.session + "/" + id
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: location, isDirectory: &isDir) else {
      throw SideportError("Location does not exist")
    }
    try privateWrite(
      [
        "id": id, "path": location, "kind": isDir.boolValue ? "directory" : "file",
        "access": access, "reason": reason,
        "expires": Date().addingTimeInterval(90).timeIntervalSince1970 * 1000,
      ], base + ".request.json")
    defer {
      try? FileManager.default.removeItem(atPath: base + ".request.json")
      try? FileManager.default.removeItem(atPath: base + ".response.json")
    }
    for _ in 0..<360 {
      try Task.checkCancellation()
      if let data = try? Data(contentsOf: URL(fileURLWithPath: base + ".response.json")),
        let answer = try? jsonObject(data, limit: 8192)
      {
        guard answer["id"] as? String == id, answer["path"] as? String == location,
          answer["access"] as? String == access
        else { throw SideportError("Invalid local access decision") }
        let approved = answer["approved"] as? Bool == true
        let currentGrants = try context.grants()
        guard !approved || context.permitted(location, access, currentGrants) else {
          throw SideportError("Approval was not applied")
        }
        return textResult([
          "status": approved ? "approved" : "denied", "path": location, "access": access,
          "expires": "disconnect",
        ])
      }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    return textResult([
      "status": "denied", "reason": "Local approval timed out; do not repeat automatically",
    ])
  }
}
