import Darwin
import Foundation

// A trusted broker receipt exists only while the tool call is running. The
// tray verifies kernel process identity so a crashed/reused PID cannot linger.
final class RequestActivity {
  let path: String
  init(_ context: NativeContext) throws {
    let id = UUID().uuidString
    path = context.session + "/" + id + ".request.json"
    guard let token = OwnedExecution.token(getpid()) else {
      throw SideportError("Cannot identify the executing broker")
    }
    try privateWrite(
      ["id": id, "kind": "tool", "pid": getpid(), "identity": OwnedExecution.values(token)], path)
  }
  func finish() { try? FileManager.default.removeItem(atPath: path) }
  deinit { finish() }
}
