import Darwin
import Foundation

struct CommandOutput {
  let code: Int32
  let stdout: Data
  let stderr: Data
  let stopped: Bool
  var result: JSONObject {
    textResult(
      [
        "exit_code": Int(code), "stdout": secretRedacted(String(decoding: stdout, as: UTF8.self)),
        "stderr": secretRedacted(String(decoding: stderr, as: UTF8.self)), "stopped": stopped,
      ], error: code != 0 || stopped)
  }
}
final class ChildSupervisor: @unchecked Sendable {
  private let lock = NSLock()
  private var children = Set<pid_t>()
  private var trees: [pid_t: [pid_t: ProcessIdentity]] = [:]
  private var leaders: [pid_t: ProcessIdentity] = [:]
  private var observationTimer: DispatchSourceTimer?
  func track(_ pid: pid_t) {
    lock.lock()
    children.insert(pid)
    leaders[pid] = identity(pid)
    trees[pid] = [:]
    if observationTimer == nil {
      let timer = DispatchSource.makeTimerSource(
        queue: DispatchQueue(label: "Sideport.process-tree"))
      timer.schedule(deadline: .now(), repeating: .milliseconds(50))
      timer.setEventHandler { [weak self] in self?.refreshTrees() }
      observationTimer = timer
      timer.resume()
    }
    lock.unlock()
  }
  private func refreshTrees() {
    lock.lock()
    let snapshot = trees
    lock.unlock()
    for (pid, previous) in snapshot {
      var known = previous
      collectDescendants(pid, into: &known)
      lock.lock()
      if children.contains(pid) { trees[pid]?.merge(known) { _, new in new } }
      lock.unlock()
    }
  }
  func stop(_ pid: pid_t) {
    lock.lock()
    var known = trees[pid] ?? [:]
    let receipt = leaders[pid]
    lock.unlock()
    collectDescendants(pid, into: &known)
    if let receipt, identity(pid) == receipt {
      kill(-pid, SIGKILL)
      kill(pid, SIGKILL)
    }
    for (child, receipt) in known where identity(child) == receipt { kill(child, SIGKILL) }
  }
  // waitid(WNOWAIT) proves this is still our unreaped child, so its PID
  // cannot be recycled. Zombie proc_pidinfo may be unavailable; kill the
  // reserved process group before waitpid releases that identity.
  func stopUnreapedChild(_ pid: pid_t) {
    lock.lock()
    let owned = children.contains(pid)
    lock.unlock()
    if owned { kill(-pid, SIGKILL) }
    stop(pid)
  }
  func forget(_ pid: pid_t) {
    stop(pid)
    lock.lock()
    children.remove(pid)
    trees.removeValue(forKey: pid)
    leaders.removeValue(forKey: pid)
    if children.isEmpty {
      observationTimer?.cancel()
      observationTimer = nil
    }
    lock.unlock()
  }
  func stopAll() {
    lock.lock()
    let all = children
    lock.unlock()
    for pid in all { stop(pid) }
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return children.count
  }
  func spawn(
    _ executable: String, _ arguments: [String], environment: [String: String], cwd: String,
    input: Pipe, output: Pipe, error: Pipe
  ) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var pid: pid_t = 0
    guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0
    else { throw SideportError("Cannot initialize child process") }
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    posix_spawn_file_actions_adddup2(
      &actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
    posix_spawn_file_actions_adddup2(
      &actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(
      &actions, error.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
    if #available(macOS 26.0, *) {
      posix_spawn_file_actions_addchdir(&actions, cwd)
    } else {
      posix_spawn_file_actions_addchdir_np(&actions, cwd)
    }
    posix_spawnattr_setflags(
      &attributes,
      Int16(
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
          | POSIX_SPAWN_SETSIGMASK))
    posix_spawnattr_setpgroup(&attributes, 0)
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigmask(&attributes, &mask)
    let args = ([executable] + arguments).map { strdup($0) } + [nil]
    let env =
      environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) } + [nil]
    defer {
      for value in args { free(value) }
      for value in env { free(value) }
    }
    let status = args.withUnsafeBufferPointer { argv in
      env.withUnsafeBufferPointer { envp in
        posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
      }
    }
    guard status == 0 else { throw SideportError("Child process could not start: \(status)") }
    track(pid)
    try? input.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
    try? error.fileHandleForWriting.close()
    return pid
  }
  private struct ProcessIdentity: Equatable {
    let start: UInt64
    let microseconds: UInt64
    let parent: pid_t
    // Reparenting changes ancestry, not the process generation.
    static func == (left: Self, right: Self) -> Bool {
      left.start == right.start && left.microseconds == right.microseconds
    }
  }
  private func identity(_ pid: pid_t) -> ProcessIdentity? {
    var info = proc_bsdinfo()
    guard
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        == MemoryLayout<proc_bsdinfo>.size
    else { return nil }
    return ProcessIdentity(
      start: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec, parent: pid_t(info.pbi_ppid)
    )
  }
  private func collectDescendants(_ parent: pid_t, into known: inout [pid_t: ProcessIdentity]) {
    var visited = Set<pid_t>()
    lock.lock()
    let rootReceipt = leaders[parent]
    lock.unlock()
    var queue = Array(known.keys)
    if let rootReceipt, identity(parent) == rootReceipt { queue.append(parent) }
    while let owner = queue.popLast() {
      guard visited.insert(owner).inserted else { continue }
      if owner != parent, let recorded = known[owner], identity(owner) != recorded { continue }
      let size = proc_listchildpids(owner, nil, 0)
      guard size > 0, size < 4_000_000 else { continue }
      var pids = [pid_t](repeating: 0, count: Int(size) + 64)
      let count = pids.withUnsafeMutableBytes {
        proc_listchildpids(owner, $0.baseAddress, Int32($0.count))
      }
      guard count > 0 else { continue }
      for pid in pids.prefix(Int(count)) {
        if let value = identity(pid), value.parent == owner {
          known[pid] = value
          queue.append(pid)
        }
      }
    }
  }

  private func capture(_ handle: FileHandle, state: CommandCapture, error: Bool) {
    let fd = handle.fileDescriptor
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var buffer = [UInt8](repeating: 0, count: 16384)
    while true {
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
      let ready = poll(&descriptor, 1, 50)
      if ready > 0 {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
          state.append(Data(buffer.prefix(count)), error: error)
          continue
        }
        if count == 0 || (errno != EAGAIN && errno != EINTR) { break }
      }
      if state.finished { break }
    }
  }
  func run(
    _ executable: String, _ args: [String], environment: [String: String], cwd: String,
    timeout: Double = 30, limit: Int = 1_048_576, inputData: Data? = nil
  ) async throws -> CommandOutput {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        do {
          let pid = try self.spawn(
            executable, args, environment: environment, cwd: cwd, input: input, output: output,
            error: error)
          let state = CommandCapture(pid: pid, limit: limit, stopProcess: { self.stop(pid) })
          let group = DispatchGroup()
          for (handle, isError) in [
            (output.fileHandleForReading, false), (error.fileHandleForReading, true),
          ] {
            group.enter()
            DispatchQueue.global().async {
              defer {
                group.leave()
                try? handle.close()
              }
              self.capture(handle, state: state, error: isError)
            }
          }
          DispatchQueue.global().async {
            if let inputData { try? input.fileHandleForWriting.write(contentsOf: inputData) }
            try? input.fileHandleForWriting.close()
          }
          let timer = DispatchWorkItem { state.stop() }
          DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
          var status: Int32 = 0
          var descendants: [pid_t: ProcessIdentity] = [:]
          var unreaped = false
          while true {
            self.collectDescendants(pid, into: &descendants)
            var info = siginfo_t()
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if info.si_pid == pid {
              unreaped = true
              break
            }
            if result < 0 && errno != EINTR { break }
            usleep(20_000)
          }
          timer.cancel()
          if unreaped { self.stopUnreapedChild(pid) } else { self.stop(pid) }
          while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
          for (child, identity) in descendants {
            if self.identity(child) == identity { kill(child, SIGKILL) }
          }
          state.finish()
          group.wait()
          self.forget(pid)
          let code = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : 128 + (status & 0x7f)
          continuation.resume(returning: state.result(code))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}
private final class CommandCapture: @unchecked Sendable {
  let pid: pid_t
  let limit: Int
  let stopProcess: () -> Void
  let lock = NSLock()
  var stdout = Data(), stderr = Data()
  var stopped = false
  var done = false
  init(pid: pid_t, limit: Int, stopProcess: @escaping () -> Void) {
    self.pid = pid
    self.limit = limit
    self.stopProcess = stopProcess
  }
  var finished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return done
  }
  func finish() {
    lock.lock()
    done = true
    lock.unlock()
  }
  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
    stopProcess()
  }
  func append(_ data: Data, error: Bool) {
    lock.lock()
    if stdout.count + stderr.count + data.count > limit {
      stopped = true
      lock.unlock()
      stopProcess()
      return
    }
    if error { stderr.append(data) } else { stdout.append(data) }
    lock.unlock()
  }
  func result(_ code: Int32) -> CommandOutput {
    lock.lock()
    defer { lock.unlock() }
    return CommandOutput(code: code, stdout: stdout, stderr: stderr, stopped: stopped)
  }
}

final class BackgroundService {
  let supervisor: ChildSupervisor
  let pid: pid_t
  init(
    _ supervisor: ChildSupervisor, _ executable: String, _ args: [String],
    environment: [String: String], cwd: String, forwardOutput: Bool = false
  ) throws {
    self.supervisor = supervisor
    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    pid = try supervisor.spawn(
      executable, args, environment: environment, cwd: cwd, input: input, output: output,
      error: error)
    try? input.fileHandleForWriting.close()
    for (handle, destination) in [
      (output.fileHandleForReading, FileHandle.standardOutput),
      (error.fileHandleForReading, FileHandle.standardError),
    ] {
      DispatchQueue.global().async {
        defer { try? handle.close() }
        while let data = try? pipeChunk(handle), !data.isEmpty {
          if forwardOutput { try? destination.write(contentsOf: data) }
        }
      }
    }
    DispatchQueue.global().async { [self] in
      var info = siginfo_t()
      while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0 && errno == EINTR {}
      if info.si_pid == pid { supervisor.stopUnreapedChild(pid) }
      supervisor.forget(pid)
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
  }
  func close() { supervisor.stop(pid) }
}
