import Darwin
import Foundation

// launchd creates a distinct kernel audit session before any sandboxed code runs.
// Session membership survives reparenting and setsid. A trusted custodian outside
// the sandbox remains alive if the connection/controller is killed.
enum OwnedExecution {
  static func token(_ pid: pid_t) -> audit_token_t? {
    var task: mach_port_t = 0
    guard task_name_for_pid(mach_task_self_, pid, &task) == KERN_SUCCESS else { return nil }
    defer { mach_port_deallocate(mach_task_self_, task) }
    var value = audit_token_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? value : nil
  }
  static func values(_ token: audit_token_t) -> [UInt32] {
    withUnsafeBytes(of: token) { Array($0.bindMemory(to: UInt32.self)) }
  }
  static func members(_ session: UInt32, excluding: pid_t) -> [audit_token_t]? {
    let required = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
    guard required > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(required) / MemoryLayout<pid_t>.size + 1024)
    let bytes = pids.withUnsafeMutableBytes {
      proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, Int32($0.count))
    }
    guard bytes > 0 else { return nil }
    return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).compactMap { pid in
      guard pid > 1, pid != excluding, let token = token(pid), values(token)[6] == session else {
        return nil
      }
      return token
    }
  }
  static func extinguish(_ session: UInt32, excluding: pid_t = 0) -> Bool {
    guard session > 0, session != UInt32.max else { return false }
    // Freeze before killing so a live member cannot keep spawning while cleanup
    // walks the session. Audit-token signals pin the PID generation atomically.
    for _ in 0..<100 {
      guard var targets = members(session, excluding: excluding) else { return false }
      if targets.isEmpty { return true }
      for index in targets.indices { _ = proc_signal_with_audittoken(&targets[index], SIGSTOP) }
      for index in targets.indices { _ = proc_signal_with_audittoken(&targets[index], SIGKILL) }
      usleep(20_000)
    }
    return members(session, excluding: excluding)?.isEmpty == true
  }
  static func prepare(
    _ executable: String, _ arguments: [String], environment: [String: String], cwd: String
  ) throws -> (String, [String])? {
    guard let root = environment["SIDEPORT_HOME"],
      executable == root + "/work/nono-bin/nono"
    else { return nil }
    let helper = try canonical(
      Bundle.main.executablePath ?? CommandLine.arguments[0], existing: true)
    let parent = root + "/work/owned-execution"
    try directory(parent)
    let path = parent + "/" + UUID().uuidString
    try directory(path)
    do {
      for name in ["input", "output", "error", "secrets"] {
        guard mkfifo(path + "/" + name, 0o600) == 0 else {
          throw SideportError("Cannot create private job channels")
        }
      }
      try privateWrite(
        [
          "executable": executable, "arguments": arguments,
          "environment": environment.filter { !$0.key.hasPrefix("SIDEPORT_PRIVATE_") },
          "secret_keys": environment.keys.filter { $0.hasPrefix("SIDEPORT_PRIVATE_") }.sorted(),
          "cwd": cwd, "helper": helper, "origin": token(getpid()).map(values) ?? [],
        ], path + "/request.json")
      return (helper, ["--job-client", path])
    } catch {
      try? FileManager.default.removeItem(atPath: path)
      throw error
    }
  }
  static func request(_ path: String) throws -> JSONObject {
    guard let root = ProcessInfo.processInfo.environment["SIDEPORT_HOME"],
      (try canonical(path, existing: true)) == path,
      path.hasPrefix(root + "/work/owned-execution/"),
      UUID(uuidString: URL(fileURLWithPath: path).lastPathComponent) != nil
    else { throw SideportError("Invalid private job") }
    let file = path + "/request.json"
    guard (try canonical(file, existing: true)) == file else {
      throw SideportError("Invalid private job request")
    }
    let value = try jsonObject(Data(contentsOf: URL(fileURLWithPath: file)), limit: 262144)
    guard value["executable"] as? String == root + "/work/nono-bin/nono",
      value["arguments"] is [String], value["environment"] is [String: String],
      value["cwd"] is String, value["helper"] is String
    else { throw SideportError("Invalid private job request") }
    return value
  }
  static func launchctl(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    let deadline = Date().addingTimeInterval(10)
    while process.isRunning, Date() < deadline { usleep(10_000) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw SideportError("macOS could not manage the isolated job")
    }
  }
  static func client(_ path: String) throws -> Never {
    var specification = try request(path)
    guard let own = token(getpid()) else { throw SideportError("Cannot identify job controller") }
    specification["owner"] = values(own)
    try privateWrite(specification, path + "/request.json")
    let label = "local.sideport.job." + URL(fileURLWithPath: path).lastPathComponent.lowercased()
    let target = "gui/\(getuid())/" + label
    let helper = specification["helper"] as! String
    var descriptors: [Int32] = []
    for name in ["input", "output", "error"] {
      let fd = open(path + "/" + name, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { throw SideportError("Cannot open job channel") }
      descriptors.append(fd)
    }
    defer {
      for fd in descriptors { Darwin.close(fd) }
      try? launchctl(["bootout", target])
      try? FileManager.default.removeItem(atPath: path)
    }
    let plist: JSONObject = [
      "Label": label, "ProgramArguments": [helper, "--job-guard", path],
      "EnvironmentVariables": [
        "SIDEPORT_HOME": ProcessInfo.processInfo.environment["SIDEPORT_HOME"]!,
        "SIDEPORT_RESOURCES": NativeResources.directory.path,
      ],
      "RunAtLoad": true, "KeepAlive": false, "SessionCreate": true,
      "AbandonProcessGroup": false,
      "StandardInPath": path + "/input", "StandardOutPath": path + "/output",
      "StandardErrorPath": path + "/error",
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: URL(fileURLWithPath: path + "/job.plist"), options: .atomic)
    guard chmod(path + "/job.plist", 0o600) == 0 else {
      throw SideportError("Cannot protect job definition")
    }
    let secretKeys = specification["secret_keys"] as? [String] ?? []
    guard secretKeys.count <= 8,
      secretKeys.allSatisfy({ GitHubPlan.matches($0, #"^SIDEPORT_PRIVATE_[A-Z0-9_]{1,64}$"#) })
    else { throw SideportError("Invalid job secret channel") }
    let secrets = Dictionary(
      uniqueKeysWithValues: try secretKeys.map { name -> (String, String) in
        guard let value = ProcessInfo.processInfo.environment[name] else {
          throw SideportError("Missing private job credential")
        }
        return (name, value)
      })
    let body = try jsonData(secrets)
    guard body.count <= 4096 else {
      throw SideportError("Private job credentials exceed channel limit")
    }
    let secretFD = open(path + "/secrets", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard secretFD >= 0 else { throw SideportError("Cannot open private credential channel") }
    defer { Darwin.close(secretFD) }
    try launchctl(["bootstrap", "gui/\(getuid())", path + "/job.plist"])
    var count = UInt32(body.count).bigEndian
    let frame = withUnsafeBytes(of: &count) { Data($0) } + body
    try FileHandle(fileDescriptor: secretFD, closeOnDealloc: false).write(contentsOf: frame)

    let ready = path + "/ready.json"
    let deadline = Date().addingTimeInterval(15)
    while !FileManager.default.fileExists(atPath: ready), Date() < deadline { usleep(10_000) }
    guard let receipt = try? jsonObject(Data(contentsOf: URL(fileURLWithPath: ready))),
      let session = receipt["session"] as? UInt32, session != values(own)[6]
    else { throw SideportError("Isolated job did not establish its ownership boundary") }
    defer { _ = extinguish(session) }
    let inputFD = descriptors.removeFirst()
    DispatchQueue.global().async {
      defer { Darwin.close(inputFD) }
      _ = fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) & ~O_NONBLOCK)
      while let data = try? pipeChunk(FileHandle.standardInput), !data.isEmpty {
        do {
          try FileHandle(fileDescriptor: inputFD, closeOnDealloc: false).write(contentsOf: data)
        } catch { break }
      }
    }
    let resultPath = path + "/result.json"
    var result: JSONObject?
    while true {
      for (fd, destination) in zip(descriptors, [FileHandle.standardOutput, .standardError]) {
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
          let count = Darwin.read(fd, &bytes, bytes.count)
          if count <= 0 { break }
          try destination.write(contentsOf: Data(bytes.prefix(count)))
        }
      }
      if result != nil { break }  // one final drain after the custodian commits completion
      result = try? jsonObject(Data(contentsOf: URL(fileURLWithPath: resultPath)))
      if result == nil, let guardPID = receipt["pid"] as? Int32,
        token(guardPID).map(values) != receipt["identity"] as? [UInt32]
      {
        throw SideportError("Job custodian exited unexpectedly; session cleanup was required")
      }
      usleep(10_000)
    }
    let code = result?["code"] as? Int32 ?? 1
    // exit() does not execute Swift defer blocks.
    for fd in descriptors { Darwin.close(fd) }
    _ = extinguish(session)
    try? launchctl(["bootout", target])
    try? FileManager.default.removeItem(atPath: path)
    exit(code)
  }
  static func guardJob(_ path: String) throws -> Never {
    let specification = try request(path)
    guard let expected = specification["owner"] as? [UInt32], expected.count == 8,
      let own = token(getpid()), values(own)[6] != expected[6],
      expected[5] > 1
    else { throw SideportError("Session isolation is unavailable") }
    let session = values(own)[6]
    let cleanup = JobCleanup(session: session, path: path)
    guard let origin = specification["origin"] as? [UInt32], origin.count == 8 else {
      cleanup.finish(code: 1)
    }
    var observers: [DispatchSourceProcess] = []
    for receipt in [expected, origin] {
      let observer = DispatchSource.makeProcessSource(
        identifier: pid_t(receipt[5]), eventMask: .exit, queue: .global())
      observer.setEventHandler { cleanup.finish(code: 1) }
      observer.resume()
      observers.append(observer)
      guard token(pid_t(receipt[5])).map(values) == receipt else { cleanup.finish(code: 1) }
    }
    try privateWrite(
      [
        "pid": getpid(), "session": session, "identity": values(own),
      ], path + "/ready.json")
    let supervisor = ChildSupervisor(ownedRouting: false)
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    var environment = specification["environment"] as! [String: String]
    let secretFD = open(path + "/secrets", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard secretFD >= 0 else { throw SideportError("Private credential channel unavailable") }
    func exact(_ length: Int) throws -> Data {
      var data = Data()
      while data.count < length {
        var bytes = [UInt8](repeating: 0, count: length - data.count)
        let count = Darwin.read(secretFD, &bytes, bytes.count)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw SideportError("Private credential channel closed") }
        data.append(contentsOf: bytes.prefix(count))
      }
      return data
    }
    let header = try exact(4)
    let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length <= 4096 else { throw SideportError("Invalid private credential frame") }
    let secrets = try jsonObject(exact(Int(length)))
    Darwin.close(secretFD)
    let expectedKeys = specification["secret_keys"] as? [String] ?? []
    guard Set(secrets.keys) == Set(expectedKeys),
      expectedKeys.allSatisfy({ GitHubPlan.matches($0, #"^SIDEPORT_PRIVATE_[A-Z0-9_]{1,64}$"#) })
    else { throw SideportError("Invalid private credential fields") }
    for (name, value) in secrets {
      guard let value = value as? String else {
        throw SideportError("Invalid private job credential")
      }
      environment[name] = value
    }
    let pid = try supervisor.spawn(
      specification["executable"] as! String, specification["arguments"] as! [String],
      environment: environment,
      cwd: specification["cwd"] as! String, input: input, output: output, error: error)
    let draining = DispatchGroup()
    for (source, destination) in [
      (output.fileHandleForReading, FileHandle.standardOutput),
      (error.fileHandleForReading, FileHandle.standardError),
    ] {
      draining.enter()
      DispatchQueue.global().async {
        defer { draining.leave() }
        while let data = try? pipeChunk(source), !data.isEmpty {
          do { try destination.write(contentsOf: data) } catch { break }
        }
      }
    }
    DispatchQueue.global().async {
      defer { try? input.fileHandleForWriting.close() }
      while let data = try? pipeChunk(FileHandle.standardInput), !data.isEmpty {
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { break }
      }
    }
    for number in [SIGTERM, SIGINT, SIGHUP] { signal(number, SIG_IGN) }
    var signals: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT, SIGHUP] {
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { cleanup.finish(code: 1) }
      source.resume()
      signals.append(source)
    }
    DispatchQueue.global().async {
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      guard extinguish(session, excluding: getpid()) else { cleanup.finish(code: 1) }
      // Descendants holding pipe writers have now been killed.
      draining.wait()
      let code = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : 128 + (status & 0x7f)
      cleanup.finish(code: code)
    }
    withExtendedLifetime((observers, signals, supervisor)) { dispatchMain() }
  }
}
private final class JobCleanup: @unchecked Sendable {
  let session: UInt32
  let path: String
  private let lock = NSLock()
  init(session: UInt32, path: String) {
    self.session = session
    self.path = path
  }
  func finish(code: Int32) -> Never {
    lock.lock()
    let stopped = OwnedExecution.extinguish(session, excluding: getpid())
    try? privateWrite(["code": stopped ? code : 1, "cleaned": stopped], path + "/result.json")
    // Keep the session alive until the client acknowledges completion by
    // terminating it. This prevents an ordinary cleanup from using a stale ASID.
    if let request = try? OwnedExecution.request(path), let owner = request["owner"] as? [UInt32],
      owner.count == 8
    {
      while OwnedExecution.token(pid_t(owner[5])).map(OwnedExecution.values) == owner {
        usleep(20_000)
      }
    }
    // If the controller was force-killed it cannot unregister this one-shot job.
    let label = "local.sideport.job." + URL(fileURLWithPath: path).lastPathComponent.lowercased()
    if let request = try? OwnedExecution.request(path), let owner = request["owner"] as? [UInt32],
      owner.count == 8, OwnedExecution.token(pid_t(owner[5])).map(OwnedExecution.values) != owner
    {
      try? FileManager.default.removeItem(atPath: path)
      try? OwnedExecution.launchctl(["bootout", "gui/\(getuid())/" + label])
    }
    exit(stopped ? code : 1)
  }
}
