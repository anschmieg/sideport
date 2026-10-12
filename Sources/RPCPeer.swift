import Darwin
import Foundation

struct RPCFailure: LocalizedError {
  let code: Int
  let message: String
  var errorDescription: String? { message }
}
protocol ToolPeer: AnyObject {
  var version: String { get }
  func connect() async throws
  func request(_ method: String, _ params: JSONObject, timeout: Double) async throws -> JSONObject
  func close()
}
final class StdioPeer: ToolPeer, @unchecked Sendable {
  let supervisor: ChildSupervisor
  let input = Pipe(), output = Pipe(), error = Pipe()
  let pid: pid_t
  private let writeLock = NSLock()
  private let lock = NSLock()
  private var pending: [String: CheckedContinuation<JSONObject, Error>] = [:]
  private var timers: [String: DispatchWorkItem] = [:]
  private var closed = false
  var version = ""
  let identity: JSONObject = ["name": "Sideport", "version": "0.3.0"]
  init(
    _ supervisor: ChildSupervisor, _ executable: String, _ args: [String],
    environment: [String: String], cwd: String
  ) throws {
    self.supervisor = supervisor
    pid = try supervisor.spawn(
      executable, args, environment: environment, cwd: cwd, input: input, output: output,
      error: error)
    DispatchQueue.global().async { [self] in
      var buffer = Data()
      defer { close() }
      while let bytes = try? pipeChunk(output.fileHandleForReading), !bytes.isEmpty {
        buffer.append(bytes)
        guard buffer.count <= 4_194_304 else { return }
        while let newline = buffer.firstIndex(of: 10) {
          let line = Data(buffer[..<newline])
          buffer.removeSubrange(...newline)
          guard !line.isEmpty else { continue }
          guard let object = try? jsonObject(line) else { return }
          receive(object)
        }
      }
    }
    DispatchQueue.global().async { [self] in
      while let bytes = try? pipeChunk(error.fileHandleForReading), !bytes.isEmpty {}
    }
    DispatchQueue.global().async { [self] in
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      supervisor.forget(pid)
      close()
    }
  }
  var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }
  private func receive(_ object: JSONObject) {
    if object["method"] != nil, let id = object["id"] {
      try? send([
        "jsonrpc": "2.0", "id": id,
        "error": ["code": -32601, "message": "Client-side requests are not permitted"],
      ])
      return
    }
    guard let id = object["id"] as? String else { return }
    lock.lock()
    let continuation = pending.removeValue(forKey: id)
    timers.removeValue(forKey: id)?.cancel()
    lock.unlock()
    guard let continuation else { return }
    if let error = object["error"] as? JSONObject {
      continuation.resume(
        throwing: RPCFailure(
          code: error["code"] as? Int ?? -32603,
          message: error["message"] as? String ?? "Provider error"))
    } else {
      continuation.resume(returning: object["result"] as? JSONObject ?? [:])
    }
  }
  private func send(_ object: JSONObject) throws {
    writeLock.lock()
    defer { writeLock.unlock() }
    try input.fileHandleForWriting.write(contentsOf: jsonData(object) + Data([10]))
  }
  func request(_ method: String, _ params: JSONObject = [:], timeout: Double = 30) async throws
    -> JSONObject
  {
    var params = params
    if version == "2026-07-28" || method == "server/discover" {
      params["_meta"] =
        [
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientInfo": identity,
          "io.modelcontextprotocol/clientCapabilities": [:],
        ] as JSONObject
    }
    let id = UUID().uuidString
    return try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      guard !closed else {
        lock.unlock()
        continuation.resume(throwing: SideportError("Server is not running"))
        return
      }
      pending[id] = continuation
      let timer = DispatchWorkItem { [weak self] in
        guard let self else { return }
        lock.lock()
        let awaiting = pending.removeValue(forKey: id)
        timers.removeValue(forKey: id)
        lock.unlock()
        awaiting?.resume(throwing: SideportError("Server request timed out"))
        if method != "server/discover" { close() }
      }
      timers[id] = timer
      lock.unlock()
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
      do { try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) } catch {
        close()
      }
    }
  }
  func connect() async throws {
    if let discovery = try? await request("server/discover", [:], timeout: 4),
      (discovery["supportedVersions"] as? [String])?.contains("2026-07-28") == true
    {
      version = "2026-07-28"
      return
    }
    let result = try await request(
      "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": identity],
      timeout: 30)
    guard let protocolVersion = result["protocolVersion"] as? String,
      ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"].contains(protocolVersion)
    else { throw SideportError("Unsupported MCP protocol") }
    version = protocolVersion
    try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
  }
  func close() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    let waiting = Array(pending.values)
    pending.removeAll()
    for timer in timers.values { timer.cancel() }
    timers.removeAll()
    lock.unlock()
    supervisor.stop(pid)
    try? input.fileHandleForWriting.close()
    for continuation in waiting { continuation.resume(throwing: SideportError("Server stopped")) }
  }
}
