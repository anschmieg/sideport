import AppKit
import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)
let arguments = CommandLine.arguments
func fail(_ error: Error) -> Never {
  try? FileHandle.standardError.write(
    contentsOf: Data((secretRedacted(error.localizedDescription) + "\n").utf8))
  exit(1)
}
if arguments.contains("--regression-tests") {
  Task {
    do {
      try await SecurityTests.run()
      exit(0)
    } catch { fail(error) }
  }
  dispatchMain()
}
var parentLease: ParentLease?
if arguments.count >= 5, arguments[1] == "--supervise" {
  do {
    guard let owner = Int32(arguments[2]), arguments[4] == "--" else {
      throw SideportError("Invalid service invocation")
    }
    try NativeService.run(owner, arguments[3], Array(arguments.dropFirst(5)))
  } catch { fail(error) }
}
if let index = arguments.firstIndex(of: "--owner") {
  do {
    guard index + 1 < arguments.count, let owner = Int32(arguments[index + 1]) else {
      throw SideportError("Invalid connection owner")
    }
    parentLease = try ParentLease(owner: owner) { exit(0) }
  } catch { fail(error) }
}
if arguments.contains("--file-operation") {
  do {
    guard arguments.count == 4 else { throw SideportError("Invalid file invocation") }
    try FileHandle.standardOutput.write(
      contentsOf: jsonData(NativeFileOperation.run(arguments[2], arguments[3])))
    exit(0)
  } catch { fail(error) }
}
if arguments.contains("--github-credential") {
  Task {
    do {
      guard arguments.count == 3 else { throw SideportError("Invalid credential invocation") }
      try await NativeGitHub.credential(arguments[2])
      exit(0)
    } catch { fail(error) }
  }
  dispatchMain()
}
if arguments.contains("--credential") {
  Task {
    do {
      let root =
        ProcessInfo.processInfo.environment["SIDEPORT_HOME"] ?? NSHomeDirectory()
        + "/Library/Application Support/Sideport"
      try await GatewayAdmin(root).credential(revoke: arguments.contains("--revoke"))
      print("Scoped connection credential prepared.")
      exit(0)
    } catch { fail(error) }
  }
  dispatchMain()
}
if arguments.contains("--broker") {
  let replyDescriptor = dup(STDOUT_FILENO)
  guard replyDescriptor >= 0 else { fail(SideportError("Cannot establish MCP output")) }
  _ = fcntl(replyDescriptor, F_SETFD, FD_CLOEXEC)
  let replies = FileHandle(fileDescriptor: replyDescriptor, closeOnDealloc: true)
  // Keep library diagnostics off the JSON-RPC channel.
  dup2(STDERR_FILENO, STDOUT_FILENO)
  let application = NSApplication.shared
  application.setActivationPolicy(.accessory)
  Task {
    do {
      let broker = try NativeBroker(NativeContext())
      var signalSources: [DispatchSourceSignal] = []
      for number in [SIGTERM, SIGINT, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler {
          Task {
            await broker.close()
            exit(0)
          }
        }
        source.resume()
        signalSources.append(source)
      }
      let stream = AsyncStream<JSONObject>(bufferingPolicy: .bufferingOldest(8)) { continuation in
        DispatchQueue.global().async {
          var buffer = Data()
          do {
            while let data = try pipeChunk(FileHandle.standardInput), !data.isEmpty {
              buffer.append(data)
              guard buffer.count <= 4_194_304 else { throw SideportError("MCP input too large") }
              while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                let object = try jsonObject(line)
                if case .dropped = continuation.yield(object) {
                  throw SideportError("Too many queued MCP requests")
                }
              }
            }
          } catch {
            try? FileHandle.standardError.write(contentsOf: Data("MCP input rejected\n".utf8))
          }
          continuation.finish()
          Task {
            await broker.close()
            exit(0)
          }
        }
      }
      for await object in stream {
        if let response = await broker.message(object) {
          try replies.write(contentsOf: jsonData(response) + Data([10]))
        }
      }
      await broker.close()
      withExtendedLifetime(signalSources) {}
      exit(0)
    } catch { fail(error) }
  }
  application.run()
  exit(0)
}
let application = NSApplication.shared
// Test/build commands use an isolated state root, never the live controller.
if arguments.contains("--update") || arguments.contains("--self-check") {
  Task {
    do {
      let root =
        ProcessInfo.processInfo.environment["SIDEPORT_HOME"] ?? NSHomeDirectory()
        + "/Library/Application Support/Sideport"
      if arguments.contains("--self-check") {
        try await NativeSelfCheck.run(root)
        print("Native runtime compatibility checks passed")
      } else {
        let updater = DependencyUpdater(root: root)
        let value = try await (arguments.contains("--apply") ? updater.apply() : updater.plan())
        try FileHandle.standardOutput.write(contentsOf: jsonData(value) + Data([10]))
      }
      exit(0)
    } catch { fail(error) }
  }
  dispatchMain()
}
do { try SideportBootstrap.prepare() } catch {
  let alert = NSAlert()
  alert.messageText = "Sideport could not start"
  alert.informativeText = error.localizedDescription
  alert.addButton(withTitle: "Quit")
  alert.runModal()
  exit(1)
}
if arguments.contains("--bundle-check") {
  print("BUNDLE: native runtime prepared; connections off")
  exit(0)
}
let controller = ProxyController()
application.delegate = controller
controller.setUp()
if arguments.contains("--off-check") {
  precondition(
    controller.connectionSwitch.state == .off && controller.proxy == nil && controller.tunnel == nil
      && controller.timer == nil && controller.approvalTimer == nil)
  print("BUNDLE: native tray off; no background services or polling")
  exit(0)
}
application.finishLaunching()
withExtendedLifetime(controller) { application.run() }
