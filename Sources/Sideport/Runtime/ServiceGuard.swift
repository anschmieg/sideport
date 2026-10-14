import Darwin
import Foundation

// Active helpers hold a lease on their tray process. A crash/force-quit closes
// that lease; it must never leave an unattended tunnel serving the Mac.
final class ParentLease {
  let source: DispatchSourceProcess
  init(owner: pid_t, cleanup: @escaping () -> Void) throws {
    guard owner > 1, getppid() == owner else {
      throw SideportError("The connection owner has exited")
    }
    source = DispatchSource.makeProcessSource(identifier: owner, eventMask: .exit, queue: .global())
    source.setEventHandler {
      cleanup()
      exit(0)
    }
    source.resume()
  }
  deinit { source.cancel() }
}
enum NativeService {
  static func run(_ owner: pid_t, _ relative: String, _ arguments: [String]) throws -> Never {
    guard ["work/mcpproxy-bin/mcpproxy", "work/tunnel-client/tunnel-client"].contains(relative)
    else { throw SideportError("Invalid connection service") }
    let root = try canonical(
      ProcessInfo.processInfo.environment["SIDEPORT_HOME"] ?? NSHomeDirectory()
        + "/Library/Application Support/Sideport", existing: true)
    let supervisor = ChildSupervisor()
    let lease = try ParentLease(owner: owner) {
      supervisor.stopAll()
      try? FileManager.default.removeItem(atPath: root + "/work/mcpproxy-runtime.key")
      if let session = ProcessInfo.processInfo.environment["MAC_CHATGPT_APPROVAL_DIR"],
        session.hasPrefix(root + "/work/permission-sessions/"),
        (try? canonical(session, existing: true)) == session
      {
        try? FileManager.default.removeItem(atPath: session)
      }
    }
    let service = try BackgroundService(
      supervisor, root + "/" + relative, arguments,
      environment: ProcessInfo.processInfo.environment, cwd: root, forwardOutput: true)
    for number in [SIGTERM, SIGINT, SIGHUP] { signal(number, SIG_IGN) }
    var signals: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT, SIGHUP] {
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler {
        service.close()
        exit(0)
      }
      source.resume()
      signals.append(source)
    }
    // Exit if the maintained service itself terminates, even before the tray's
    // health check. SIGCHLD cannot safely poll or wait for unrelated processes.
    let monitor = DispatchSource.makeProcessSource(
      identifier: service.pid, eventMask: .exit, queue: .global())
    monitor.setEventHandler {
      supervisor.stopAll()
      exit(1)
    }
    monitor.resume()
    withExtendedLifetime((lease, signals, monitor)) { dispatchMain() }
  }
}
