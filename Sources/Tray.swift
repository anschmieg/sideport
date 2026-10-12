import AppKit
import Darwin
import Foundation

final class ProxyController: NSObject, NSApplicationDelegate {
  let root = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["SIDEPORT_HOME"]
      ?? (NSHomeDirectory() + "/Library/Application Support/Sideport"))
  var executable: URL {
    URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
  }
  var childEnvironment: [String: String] {
    [
      "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      "HOME": NSHomeDirectory(), "SIDEPORT_HOME": root.path,
      "SIDEPORT_APP_EXECUTABLE": Bundle.main.executablePath ?? "",
      "SIDEPORT_RESOURCES": NativeResources.directory.path,
      "SIDEPORT_WORKSPACE": ProcessInfo.processInfo.environment["SIDEPORT_WORKSPACE"]
        ?? NSHomeDirectory() + "/Documents/ChatGPT Workspace",
    ]
  }
  var savedLocations: RememberedLocations {
    RememberedLocations(
      file: root.appendingPathComponent("work/remembered-locations.json"), controller: root.path)
  }
  var item: NSStatusItem!
  var status: NSMenuItem!
  var popover: NSPopover!
  var connectionSwitch: NSSwitch!
  var connectionState: NSTextField!
  var connectItem: NSMenuItem!
  var disconnectItem: NSMenuItem!
  var proxy: Process?
  var tunnel: Process?
  var timer: Timer?
  var log: FileHandle?
  var stopping = false
  var checking = false
  var started = Date()
  var updating = false
  var updateItem: NSMenuItem!
  var didSetUp = false
  let ownedServices = ChildSupervisor()
  let credentialLock = NSLock()
  var credentialCancelled = true
  var credentialProcess: Process?
  var credentialPrepared = false
  var preparingCredential = false
  var approvalTimer: Timer?
  var approvalDirectory: URL?
  var prompting = false
  var seenRequests = Set<String>()
  let smoke = CommandLine.arguments.contains("--smoke-test")
  let localSmoke =
    CommandLine.arguments.contains("--smoke-test-local")
    || CommandLine.arguments.contains("--toggle-smoke-test-local")
    || CommandLine.arguments.contains("--cancel-connect-smoke-local")
  let toggleSmoke =
    CommandLine.arguments.contains("--toggle-smoke-test-local")
    || CommandLine.arguments.contains("--cancel-connect-smoke-local")
  let cancelSmoke = CommandLine.arguments.contains("--cancel-connect-smoke-local")
  let permissionTest = CommandLine.arguments.contains("--permission-test-local")
  let connectionTest = CommandLine.arguments.contains("--connection-test")
  var healthFile: String { root.appendingPathComponent("work/mcpproxy-health.url").path }

  func applicationDidFinishLaunching(_ notification: Notification) {
    setUp()
  }
  func setUp() {
    guard !didSetUp else { return }
    didSetUp = true
    NSApp.setActivationPolicy(.accessory)
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let header = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 168))
    header.material = .popover
    header.blendingMode = .withinWindow
    header.state = .active
    let title = NSTextField(labelWithString: "Sideport")
    title.font = .systemFont(ofSize: 19, weight: .semibold)
    title.frame = NSRect(x: 18, y: 130, width: 200, height: 25)
    header.addSubview(title)
    let alpha = NSTextField(labelWithString: "ALPHA 0.3")
    alpha.font = .systemFont(ofSize: 10, weight: .semibold)
    alpha.textColor = .secondaryLabelColor
    alpha.frame = NSRect(x: 245, y: 136, width: 80, height: 17)
    header.addSubview(alpha)
    let subtitle = NSTextField(labelWithString: "Computer use for remote agents.")
    subtitle.font = NSFontManager.shared.convert(
      .systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
    subtitle.textColor = .secondaryLabelColor
    subtitle.frame = NSRect(x: 18, y: 107, width: 310, height: 20)
    header.addSubview(subtitle)
    let label = NSTextField(labelWithString: "Allow connections")
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.frame = NSRect(x: 18, y: 73, width: 230, height: 22)
    header.addSubview(label)
    connectionState = NSTextField(labelWithString: "Off")
    connectionState.font = .systemFont(ofSize: 12)
    connectionState.textColor = .secondaryLabelColor
    connectionState.frame = NSRect(x: 18, y: 51, width: 304, height: 18)
    header.addSubview(connectionState)
    connectionSwitch = NSSwitch(frame: NSRect(x: 278, y: 72, width: 44, height: 26))
    connectionSwitch.target = self
    connectionSwitch.action = #selector(toggleConnection(_:))
    connectionSwitch.setAccessibilityLabel("Allow remote agent connections")
    header.addSubview(connectionSwitch)

    connectItem = NSMenuItem(
      title: "Allow agent connections", action: #selector(connect), keyEquivalent: "")
    disconnectItem = NSMenuItem(
      title: "Disconnect", action: #selector(disconnect), keyEquivalent: "")
    for entry in [connectItem!, disconnectItem!] { entry.target = self }
    menu.addItem(.separator())
    updateItem = NSMenuItem(
      title: "Check for updates…", action: #selector(checkUpdates), keyEquivalent: "")
    updateItem.target = self
    menu.addItem(updateItem)
    let review = NSMenuItem(
      title: "Automatic command review", action: #selector(toggleReview(_:)), keyEquivalent: "")
    review.target = self
    review.state = reviewSettings()["enabled"] as? Bool == true ? .on : .off
    review.toolTip = "Jev reviews flagged commands. Uncertain decisions still ask you."
    menu.addItem(review)
    let locations = NSMenuItem(
      title: "Remembered locations…", action: #selector(manageLocations), keyEquivalent: "")
    locations.target = self
    menu.addItem(locations)
    let help = NSMenuItem(
      title: "Getting started…", action: #selector(openGuide), keyEquivalent: "")
    help.target = self
    menu.addItem(help)
    let logs = NSMenuItem(
      title: "Show connection log…", action: #selector(openLog), keyEquivalent: "")
    logs.target = self
    menu.addItem(logs)
    let about = NSMenuItem(title: "About Sideport…", action: #selector(about), keyEquivalent: "")
    about.target = self
    menu.addItem(about)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit (disconnects)", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    let divider = NSBox(frame: NSRect(x: 18, y: 37, width: 304, height: 1))
    divider.boxType = .separator
    header.addSubview(divider)
    let options = NSPopUpButton(frame: NSRect(x: 14, y: 6, width: 105, height: 26), pullsDown: true)
    menu.insertItem(NSMenuItem(title: "More…", action: nil, keyEquivalent: ""), at: 0)
    options.menu = menu
    options.bezelStyle = .rounded
    options.controlSize = .small
    options.setAccessibilityLabel("Sideport options")
    header.addSubview(options)
    let controller = NSViewController()
    controller.view = header
    popover = NSPopover()
    popover.contentViewController = controller
    popover.contentSize = header.frame.size
    popover.behavior = .transient
    item.button?.target = self
    item.button?.action = #selector(togglePopover)
    update("Disconnected — Mac access off", active: false)
    if CommandLine.arguments.contains("--tray-preview") {
      DispatchQueue.main.async {
        let panel = NSPanel(
          contentRect: header.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Sideport"
        panel.contentView = header
        panel.makeKeyAndOrderFront(nil)
        header.displayIfNeeded()
        if let bitmap = header.bitmapImageRepForCachingDisplay(in: header.bounds) {
          header.cacheDisplay(in: header.bounds, to: bitmap)
          try? bitmap.representation(using: .png, properties: [:])?.write(
            to: self.root.appendingPathComponent("outputs/Sideport preview.png"))
        }
        panel.orderOut(nil)
        NSApp.terminate(nil)
      }
      return
    }
    if CommandLine.arguments.contains("--command-approval-preview") {
      let dialog = capabilityDialog(
        "shell_command",
        details: [
          "command": "git reset --hard HEAD",
          "cwd": NSHomeDirectory() + "/Documents/Sideport Workspace",
          "risk": "This discards uncommitted changes in the working folder and staging area.",
          "rule": "core.git:reset-hard",
        ], reason: "Reset this test checkout to its last commit after saving the changes elsewhere."
      )
      DispatchQueue.main.async {
        do {
          try dialog?.preview(
            to: self.root.appendingPathComponent("outputs/Sideport command approval.png").path)
        } catch { print(error) }
        NSApp.terminate(nil)
      }
      return
    }
    if CommandLine.arguments.contains("--approval-preview") {
      let dialog = capabilityDialog(
        "npm_server",
        details: [
          "package": "@modelcontextprotocol/server-filesystem", "version": "2026.8.31",
          "args": [NSHomeDirectory() + "/Documents/Sideport Workspace"],
          "locations": [
            [
              "path": NSHomeDirectory() + "/Documents/Sideport Workspace", "access": "read_write",
              "kind": "directory",
            ]
          ], "cached": true, "network": "blocked",
        ],
        reason:
          "Test the new permission prompt. The file tool will start, show its available actions, and then stop. It will not read or change your files."
      )
      DispatchQueue.main.async {
        do {
          try dialog?.preview(
            to: self.root.appendingPathComponent("outputs/Permission prompt preview.png").path)
        } catch { print(error) }
        NSApp.terminate(nil)
      }
      return
    }
    if smoke || localSmoke || permissionTest || connectionTest
      || CommandLine.arguments.contains("--connect")
    {
      DispatchQueue.main.async {
        if self.toggleSmoke {
          self.connectionSwitch.state = .on
          precondition(
            self.connectionSwitch.sendAction(
              self.connectionSwitch.action, to: self.connectionSwitch.target))
        } else {
          self.connect()
        }
        if self.cancelSmoke {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.connectionSwitch.state = .off
            precondition(self.connectionSwitch.isEnabled)
            precondition(
              self.connectionSwitch.sendAction(
                self.connectionSwitch.action, to: self.connectionSwitch.target))
          }
        }
      }
    }
  }
  func update(_ text: String, active: Bool) {
    status.title = text
    let ready = text == "Connected — Mac access on"
    let off = text == "Disconnected — Mac access off"
    connectionState.stringValue =
      ready
      ? "Ready · agents can connect"
      : off
        ? "Off · connections blocked"
        : text.hasPrefix("Disconnected") ? "Off · connection interrupted" : text
    connectionState.toolTip = text
    connectionSwitch.state = active ? .on : .off
    connectionSwitch.isEnabled = !stopping && !updating
    connectionSwitch.setAccessibilityValue(ready ? "Ready" : off ? "Off" : text)
    item.button?.image = NSImage(
      systemSymbolName: active ? "desktopcomputer.badge.checkmark" : "desktopcomputer",
      accessibilityDescription: text)
    item.button?.title = active ? " On" : " Off"
    item.button?.toolTip = text
    connectItem.isEnabled = proxy == nil && !stopping && !updating
    updateItem?.isEnabled = proxy == nil && !stopping && !updating
    disconnectItem.isEnabled = proxy != nil && !stopping
  }
  func reviewSettings() -> [String: Any] {
    guard
      let data = try? Data(contentsOf: root.appendingPathComponent("work/approval-reviewer.json")),
      let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return settings
  }
  @objc func toggleReview(_ sender: NSMenuItem) {
    var settings = reviewSettings()
    guard !settings.isEmpty else {
      report("Automatic review is not configured yet.")
      return
    }
    settings["enabled"] = sender.state != .on
    do {
      let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
      try data.write(
        to: root.appendingPathComponent("work/approval-reviewer.json"), options: [.atomic])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: root.appendingPathComponent("work/approval-reviewer.json").path)
      sender.state = settings["enabled"] as? Bool == true ? .on : .off
    } catch { report("Could not change command review settings.") }
  }
  @objc func togglePopover() {
    guard let button = item.button else { return }
    if popover.isShown {
      popover.performClose(nil)
    } else {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
  }
  @objc func toggleConnection(_ sender: NSSwitch) {
    if sender.state == .on { connect() } else { disconnect() }
  }
  func report(_ message: String) {
    if smoke || localSmoke {
      FileHandle.standardError.write(Data(("SMOKE FAILED: " + message + "\n").utf8))
      NSApp.terminate(nil)
      return
    }
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Sideport"
    alert.informativeText = message
    alert.runModal()
  }
  func updateCommand(_ apply: Bool, completion: @escaping (Bool, String) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let process = Process()
      process.executableURL = self.executable
      process.arguments = ["--update"] + (apply ? ["--apply"] : [])
      process.environment = self.childEnvironment
      process.standardInput = FileHandle.nullDevice
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      var success = false
      var output = ""
      do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        output = String(data: data, encoding: .utf8) ?? "Update returned unreadable output"
        success = process.terminationStatus == 0
      } catch { output = error.localizedDescription }
      DispatchQueue.main.async { completion(success, output) }
    }
  }
  @objc func checkUpdates() {
    guard proxy == nil, !stopping, !updating else { return }
    updating = true
    update("Checking dependencies…", active: false)
    updateCommand(false) { success, output in
      guard success, let data = output.data(using: .utf8),
        let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let changes = result["changes"] as? [String]
      else {
        self.updating = false
        self.update("Disconnected — Mac access off", active: false)
        self.report("Update check failed: " + output.prefix(1500))
        return
      }
      if changes.isEmpty {
        self.updating = false
        self.update("Disconnected — Mac access off", active: false)
        self.report("All dependencies are current.")
        return
      }
      NSApp.activate(ignoringOtherApps: true)
      let alert = NSAlert()
      alert.messageText = "Update dependencies?"
      alert.informativeText =
        changes.joined(separator: "\n")
        + "\n\nUpdates verify release checksums and run compatibility checks. Previous versions are restored if a check fails. Mac access stays off."
      alert.addButton(withTitle: "Update")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else {
        self.updating = false
        self.update("Disconnected — Mac access off", active: false)
        return
      }
      self.update("Updating dependencies…", active: false)
      self.updateCommand(true) { _, message in
        self.updating = false
        self.update("Disconnected — Mac access off", active: false)
        self.report(String(message.prefix(2000)))
      }
    }
  }
  @objc func openGuide() {
    if let guide = Bundle.main.url(forResource: "Getting started", withExtension: "md") {
      NSWorkspace.shared.open(guide)
    }
  }
  @objc func openLog() {
    let file = root.appendingPathComponent("work/mcpproxy-controller.log")
    guard FileManager.default.fileExists(atPath: file.path) else {
      report("No connection log yet. Turn on Allow connections to start a session.")
      return
    }
    NSWorkspace.shared.open(file)
  }
  @objc func about() {
    report(
      "Early alpha · Version 0.3.0\n\nComputer use for remote agents.\n\nAccess starts off. Active access ends when you disconnect. Remembered file locations return only when you reconnect; tool and computer-control approvals expire. Computer control can reach beyond approved folders.\n\nRuntime dependencies are bundled. Settings and remembered locations are stored in Application Support/Sideport. Getting started explains the supported tools and limitations."
    )
  }
  func launch(_ path: String, _ arguments: [String]) throws -> Process {
    let child = Process()
    child.executableURL = executable
    child.arguments = ["--supervise", String(getpid()), path, "--"] + arguments
    child.currentDirectoryURL = root
    var env = childEnvironment
    env["PATH"] = childEnvironment["PATH"]
    env["HEADLESS"] = "true"
    env["MCPPROXY_TELEMETRY"] = "false"
    if let directory = approvalDirectory { env["MAC_CHATGPT_APPROVAL_DIR"] = directory.path }
    child.environment = env
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = log
    child.standardError = log
    child.terminationHandler = { [weak self] process in
      self?.ownedServices.forget(process.processIdentifier)
      DispatchQueue.main.async {
        guard let self = self, !self.stopping,
          self.proxy === process || self.tunnel === process
        else { return }
        self.stop("Disconnected — service exited (\(process.terminationStatus))")
      }
    }
    try child.run()
    ownedServices.track(child.processIdentifier)
    return child
  }
  func configureCredential(revoke: Bool = false) throws {
    let child = Process()
    child.executableURL = self.executable
    child.arguments = ["--credential", "--owner", String(getpid())] + (revoke ? ["--revoke"] : [])
    child.environment = self.childEnvironment
    child.standardInput = FileHandle.nullDevice
    child.standardOutput = log
    child.standardError = log
    if !revoke {
      credentialLock.lock()
      guard !credentialCancelled else {
        credentialLock.unlock()
        throw SideportError("Connection preparation cancelled")
      }
      do {
        try child.run()
        credentialProcess = child
        ownedServices.track(child.processIdentifier)
        credentialLock.unlock()
      } catch {
        credentialLock.unlock()
        throw error
      }
    } else {
      try child.run()
    }
    defer {
      if !revoke {
        ownedServices.forget(child.processIdentifier)
        credentialLock.lock()
        if credentialProcess === child { credentialProcess = nil }
        credentialLock.unlock()
      }
    }
    child.waitUntilExit()
    guard child.terminationStatus == 0 else {
      throw NSError(
        domain: "Sideport", code: 4,
        userInfo: [
          NSLocalizedDescriptionKey: "Restricted connection credential could not be prepared"
        ])
    }
  }
  @objc func connect() {
    guard proxy == nil, !stopping, !updating else { return }
    let required = [
      "work/mcpproxy-bin/mcpproxy", "work/tunnel-client/tunnel-client", "work/nono-bin/nono",
      "work/tunnel-runtime.key", "work/mcpproxy-pilot/config.json",
    ]
    guard FileManager.default.isExecutableFile(atPath: executable.path),
      required.allSatisfy({
        FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
      })
    else {
      connectionSwitch.state = .off
      report(
        "Connection settings are missing. Complete the one-time tunnel setup before enabling connections. Sideport starts with connections off."
      )
      return
    }
    let check = Process()
    check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    check.arguments = ["-x", "tunnel-client"]
    check.standardOutput = FileHandle.nullDevice
    check.standardError = FileHandle.nullDevice
    do {
      try check.run()
      check.waitUntilExit()
    } catch {
      report(error.localizedDescription)
      return
    }
    guard localSmoke || permissionTest || check.terminationStatus != 0 else {
      connectionSwitch.state = .off
      report(
        "Another connection tunnel is already running. Close the previous launcher or disconnect it, then turn on Allow connections again."
      )
      return
    }
    try? FileManager.default.removeItem(atPath: healthFile)
    let url = root.appendingPathComponent("work/mcpproxy-controller.log")
    FileManager.default.createFile(
      atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    do {
      credentialLock.lock()
      credentialCancelled = false
      credentialLock.unlock()
      credentialPrepared = false
      preparingCredential = false
      try preparePermissions()
      log = try FileHandle(forWritingTo: url)
      proxy = try launch(
        "work/mcpproxy-bin/mcpproxy",
        [
          "serve", "--config", root.appendingPathComponent("work/mcpproxy-pilot/config.json").path,
          "--data-dir", root.appendingPathComponent("work/mcpproxy-pilot").path,
          "--log-dir", root.appendingPathComponent("work/mcpproxy-pilot/logs").path, "--log-level",
          "warn",
        ])
      started = Date()
      update("Starting tools…", active: true)
      timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
        self?.checkHealth()
      }
      approvalTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        self?.checkPermissions()
      }
      checkHealth()
    } catch {
      stop("Disconnected — start failed")
      report(error.localizedDescription)
    }
  }
  func preparePermissions() throws {
    let manager = FileManager.default
    let workspace = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["SIDEPORT_WORKSPACE"]
        ?? NSHomeDirectory() + "/Documents/ChatGPT Workspace", isDirectory: true)
    try manager.createDirectory(
      at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let canonical = canonicalPath(workspace.path) ?? workspace.path
    guard safeGrant(canonical) else {
      throw NSError(
        domain: "Sideport", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The default workspace points into the connection controller. Choose a separate folder."
        ])
    }
    let parent = root.appendingPathComponent("work/permission-sessions", isDirectory: true)
    try manager.createDirectory(
      at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    approvalDirectory = directory
    seenRequests.removeAll()
    var restored = try savedLocations.read().map { $0.grant }.filter { $0["path"] != canonical }
    restored.append(["path": canonical, "kind": "directory", "access": "read_write"])
    try writePrivate(restored, to: directory.appendingPathComponent("grants.json"))
    let configuration = root.appendingPathComponent("work/mcpproxy-pilot/config.json")
    guard
      var config = (try JSONSerialization.jsonObject(with: Data(contentsOf: configuration)))
        as? [String: Any],
      var servers = config["mcpServers"] as? [[String: Any]],
      let index = servers.firstIndex(where: { $0["name"] as? String == "permissions" })
    else {
      throw NSError(
        domain: "Sideport", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Permission server is missing from configuration"])
    }
    servers[index]["command"] = executable.path
    servers[index]["args"] = ["--broker"]
    servers[index]["env"] = childEnvironment.merging(["MAC_CHATGPT_APPROVAL_DIR": directory.path]) {
      _, new in new
    }
    config["mcpServers"] = servers
    try writePrivate(config, to: configuration)
  }
  func safeGrant(_ path: String) -> Bool {
    let control = canonicalPath(root.path) ?? root.path
    return path != control && !path.hasPrefix(control + "/")
      && !control.hasPrefix(path == "/" ? "/" : path + "/")
  }
  func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
  func writePrivate(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
      to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  func checkPermissions() {
    let stopMarker = root.appendingPathComponent(
      connectionTest ? "work/connection-test.stop" : "work/permission-test.stop")
    if (permissionTest || connectionTest) && FileManager.default.fileExists(atPath: stopMarker.path)
    {
      try? FileManager.default.removeItem(at: stopMarker)
      stop("Disconnected — Mac access off") { NSApp.terminate(nil) }
      return
    }
    guard !prompting, !stopping, proxy?.isRunning == true, let directory = approvalDirectory,
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    if checkCapabilities(in: directory, files: files) { return }
    for file in files where file.lastPathComponent.hasSuffix(".request.json") {
      guard let data = try? Data(contentsOf: file), data.count < 8192,
        let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let id = request["id"] as? String, UUID(uuidString: id) != nil,
        file.lastPathComponent == id + ".request.json", !seenRequests.contains(id),
        let path = request["path"] as? String, path.hasPrefix("/"), path.count <= 4096,
        !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        let reason = request["reason"] as? String, !reason.isEmpty, reason.count <= 500,
        !reason.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        let access = request["access"] as? String, ["read", "read_write"].contains(access),
        let kind = request["kind"] as? String, ["file", "directory"].contains(kind),
        let expires = request["expires"] as? Double
      else { continue }
      seenRequests.insert(id)
      let location = canonicalPath(path)
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      let valid =
        exists && location == path && safeGrant(path)
        && (isDirectory.boolValue ? "directory" : "file") == kind
        && expires > Date().timeIntervalSince1970 * 1000
        && expires < Date().addingTimeInterval(125).timeIntervalSince1970 * 1000
      var approved = false
      var remember = false
      let testFixture = permissionTest && path.hasPrefix("/private/tmp/mac-permission-test-")
      if valid && testFixture
        && (CommandLine.arguments.contains("--test-approve")
          || CommandLine.arguments.contains("--test-deny"))
      {
        approved = CommandLine.arguments.contains("--test-approve")
      } else if valid {
        prompting = true
        NSApp.activate(ignoringOtherApps: true)
        let display = compact(displayPath(path), limit: 160)
        let dialog = ApprovalDialog(
          title:
            "Allow access to “\(compact(URL(fileURLWithPath: path).lastPathComponent, limit: 58))”?",
          reason: reason,
          sections: [
            (
              "Access you’re granting",
              "\(access == "read" ? "Read files in" : "Read, change and delete files in")\n\(display)"
            )
          ],
          duration:
            "Access stops when disconnected. Remembered locations return when you reconnect; remove them in Remembered locations.",
          technical: "Location: \(path)\nScope: \(kind)\nAccess: \(access)",
          allow: "Allow access", deny: "Don’t allow", symbol: "folder", rememberLocation: true)
        approved = dialog.run(until: expires)
        remember = approved && dialog.remembersLocation
        prompting = false
        approved =
          approved && !stopping && approvalDirectory == directory
          && Date().timeIntervalSince1970 * 1000 < expires
          && canonicalPath(path) == path
      }
      if approved {
        do {
          let state = directory.appendingPathComponent("grants.json")
          guard
            var grants = (try JSONSerialization.jsonObject(with: Data(contentsOf: state)))
              as? [[String: String]]
          else {
            throw NSError(
              domain: "Sideport", code: 2,
              userInfo: [NSLocalizedDescriptionKey: "Invalid local permission state"])
          }
          if remember { try savedLocations.remember(path: path, kind: kind, access: access) }
          grants.append(["path": path, "kind": kind, "access": access])
          try writePrivate(grants, to: state)
        } catch {
          approved = false
          report("Access could not be granted: " + error.localizedDescription)
        }
      }
      try? writePrivate(
        ["id": id, "path": path, "access": access, "approved": approved],
        to: directory.appendingPathComponent(id + ".response.json"))
      log?.write(
        Data(
          ("PERMISSION: valid=\(valid) approved=\(approved) access=\(access) path=\(path)\n").utf8))
      return
    }
  }
  @objc func manageLocations() {
    guard !prompting else { return }
    guard proxy == nil && tunnel == nil && !stopping else {
      report(
        "Disconnect before editing remembered locations, so running commands and tools lose their access first."
      )
      return
    }
    do {
      let entries = try savedLocations.read().sorted { $0.path < $1.path }
      guard !entries.isEmpty else {
        report(
          "No remembered locations. Check Remember this location when approving a folder to save it for future connections."
        )
        return
      }
      let chooser = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 430, height: 28))
      for entry in entries {
        chooser.addItem(
          withTitle: compact(displayPath(entry.path), limit: 70)
            + (entry.access == "read" ? " · read only" : " · read/write"))
        chooser.lastItem?.representedObject = entry.path
        chooser.lastItem?.toolTip = entry.path
      }
      chooser.setAccessibilityLabel("Remembered location to forget")
      let alert = NSAlert()
      alert.messageText = "Remembered locations"
      alert.informativeText =
        "These locations return when you manually connect. Forgetting a location removes its saved approval. Locations inside another allowed parent folder remain covered by that parent."
      alert.accessoryView = chooser
      alert.addButton(withTitle: "Forget location")
      alert.addButton(withTitle: "Done")
      NSApp.activate(ignoringOtherApps: true)
      if alert.runModal() == .alertFirstButtonReturn,
        let selected = chooser.selectedItem?.representedObject as? String
      {
        try savedLocations.forget(selected)
        if let directory = approvalDirectory {
          let state = directory.appendingPathComponent("grants.json")
          if let grants = try JSONSerialization.jsonObject(with: Data(contentsOf: state))
            as? [[String: String]]
          {
            try writePrivate(grants.filter { $0["path"] != selected }, to: state)
          }
        }
      }
    } catch { report("Remembered locations could not be updated: " + error.localizedDescription) }
  }
  func compact(_ text: String, limit: Int = 96) -> String {
    guard text.count > limit else { return text }
    let side = (limit - 1) / 2
    return String(text.prefix(side)) + "…" + String(text.suffix(side))
  }
  func displayPath(_ path: String) -> String {
    path.hasPrefix(NSHomeDirectory() + "/") ? "~" + path.dropFirst(NSHomeDirectory().count) : path
  }
  func capabilityDialog(_ capability: String, details: [String: Any], reason: String)
    -> ApprovalDialog?
  {
    let duration = "Permission ends when you disconnect."
    if capability == "shell_command" {
      guard let command = details["command"] as? String, !command.isEmpty, command.count <= 4000,
        let cwd = details["cwd"] as? String, canonicalPath(cwd) == cwd, safeGrant(cwd),
        let risk = details["risk"] as? String, !risk.isEmpty, risk.count <= 2000,
        let rule = details["rule"] as? String, rule.count <= 200
      else { return nil }
      let dialog = ApprovalDialog(
        title: "Run this flagged command?", reason: reason,
        sections: [
          ("Why it needs your decision", compact(risk, limit: 400)),
          ("Command preview", compact(command, limit: 180)), ("Working folder", displayPath(cwd)),
          (
            "What approval permits",
            "Run this command once. It may delete files, discard work, or change remote services. Existing file restrictions still apply."
          ),
        ],
        duration: "Approval is for this invocation only.",
        technical:
          "Command: \(command)\nWorking directory: \(cwd)\nGuard rule: \(rule)\nNetwork: ordinary command access\nNo file permission or credential access is added.",
        allow: "Run once", deny: "Don’t run", symbol: "exclamationmark.triangle")
      dialog.toggleDetails()  // Show the complete command for review, in a bounded scroll area.
      return dialog
    }
    if capability == "computer_control" {
      return ApprovalDialog(
        title: "Allow an agent to control this Mac?", reason: reason,
        sections: [
          ("Access you’re granting", "Click, type and interact with apps on your screen."),
          (
            "This goes beyond approved folders",
            "Screen control can open other files and use Terminal. Only allow it for a task you trust."
          ),
        ],
        duration: duration,
        technical:
          "Computer tool: Peekaboo\nDrag actions require source and target element selectors.\nApproval does not change the file and shell sandbox.",
        allow: "Allow screen control", deny: "Don’t allow", symbol: "cursorarrow")
    }
    if capability == "managed_server" {
      guard let manager = details["manager"] as? String,
        ["agents-dev", "Smithery"].contains(manager),
        let name = details["name"] as? String, name.count <= 200,
        let mode = details["mode"] as? String, ["sandbox", "service"].contains(mode),
        let target = details["target"] as? String, target.count <= 500,
        let credentials = details["credentials"] as? String, credentials.count <= 2000,
        let scope = details["scope"] as? String, scope.count <= 2000
      else { return nil }
      return ApprovalDialog(
        title: "Forward \(compact(name, limit: 48))?", reason: reason,
        sections: [
          ("Existing connection", "\(manager) · \(compact(target, limit: 100))"),
          (mode == "sandbox" ? "Access on this Mac" : "Service permissions", scope),
          ("Configured credentials", credentials),
        ],
        duration:
          "Forwarding ends when you disconnect. The manager’s saved connection remains available locally.",
        technical:
          "Manager: \(manager)\nServer: \(name)\nTarget: \(target)\nMode: \(mode)\nExisting configuration is reused; no manager settings are changed.",
        allow: "Forward server", deny: "Don’t forward", symbol: "arrow.triangle.branch")
    }
    if capability == "remote_server" {
      guard let endpoint = details["endpoint"] as? String, let url = URL(string: endpoint),
        url.scheme == "https", let host = url.host, url.user == nil, url.password == nil
      else { return nil }
      return ApprovalDialog(
        title: "Connect to \(compact(host, limit: 56))?", reason: reason,
        sections: [
          (
            "What this service receives",
            "The inputs the agent sends when using this tool. Local files and saved credentials are not shared automatically."
          )
        ],
        duration: duration,
        technical:
          "MCP endpoint: \(endpoint)\nPublic HTTPS only. Account authentication is not enabled.\nJuly 2026 protocol preferred, with older-server compatibility.",
        allow: "Connect service", deny: "Don’t connect", symbol: "network")
    }
    guard capability == "npm_server", let package = details["package"] as? String,
      package.count <= 200,
      let version = details["version"] as? String, version.count <= 60,
      let args = details["args"] as? [String],
      let locations = details["locations"] as? [[String: String]],
      let cached = details["cached"] as? Bool, details["network"] as? String == "blocked",
      !package.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !version.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    var scope: [String] = []
    for grant in locations {
      guard let path = grant["path"], let access = grant["access"],
        ["read", "read_write"].contains(access),
        canonicalPath(path) == path, safeGrant(path)
      else { return nil }
      scope.append(
        "\(displayPath(path)) — \(access == "read" ? "read only" : "read, change and delete")")
    }
    let name =
      package == "@modelcontextprotocol/server-filesystem"
      ? "Filesystem" : package.split(separator: "/").last.map(String.init) ?? package
    let visibleScope =
      scope.prefix(3).map { compact($0, limit: 120) }.joined(separator: "\n")
      + (scope.count > 3 ? "\n+ \(scope.count - 3) other approved locations (see details)" : "")
    let technical =
      "Package: \(package)@\(version)\nArguments: \(args.joined(separator: " "))\n\nAll approved locations:\n\(scope.joined(separator: "\n"))\n\nInstall scripts: disabled\nPackage audit: high and critical findings block startup\nNetwork while running: blocked\nDownloads: separate installer sandbox"
    return ApprovalDialog(
      title: package == "@modelcontextprotocol/server-filesystem"
        ? "Run a filesystem tool?" : "Run \(compact(name, limit: 48))?", reason: reason,
      sections: [
        (
          "What will happen",
          cached
            ? "Start a previously downloaded tool on this Mac."
            : "Download a tool and run it on this Mac."
        ),
        ("Files it can use", visibleScope.isEmpty ? "No personal files." : visibleScope),
        ("Network access", "Blocked while the tool is running."),
      ],
      duration: duration, technical: technical,
      allow: package == "@modelcontextprotocol/server-filesystem" ? "Run file tool" : "Run tool",
      deny: "Don’t run", symbol: "shippingbox")
  }
  func checkCapabilities(in directory: URL, files: [URL]) -> Bool {
    for file in files where file.lastPathComponent.hasSuffix(".capability.json") {
      guard let data = try? Data(contentsOf: file), data.count < 8192,
        let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let id = request["id"] as? String, UUID(uuidString: id) != nil,
        file.lastPathComponent == id + ".capability.json", !seenRequests.contains(id),
        let capability = request["capability"] as? String,
        ["computer_control", "npm_server", "remote_server", "shell_command", "managed_server"]
          .contains(capability),
        let details = request["details"] as? [String: Any],
        let reason = request["reason"] as? String, !reason.isEmpty, reason.count <= 500,
        !reason.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
        let expires = request["expires"] as? Double,
        expires > Date().timeIntervalSince1970 * 1000,
        expires < Date().addingTimeInterval(125).timeIntervalSince1970 * 1000
      else { continue }
      guard let dialog = capabilityDialog(capability, details: details, reason: reason) else {
        continue
      }
      seenRequests.insert(id)
      prompting = true
      let decision = dialog.run(until: expires)
      prompting = false
      let approved =
        decision && !stopping && approvalDirectory == directory
        && Date().timeIntervalSince1970 * 1000 < expires
      try? writePrivate(
        ["id": id, "capability": capability, "approved": approved],
        to: directory.appendingPathComponent(id + ".decision.json"))
      log?.write(Data(("CAPABILITY: \(capability) approved=\(approved)\n").utf8))
      return true
    }
    return false
  }
  func checkHealth() {
    guard let gateway = proxy, gateway.isRunning, !stopping, !checking else { return }
    checking = true
    let url: URL
    if tunnel == nil {
      guard let gateway = try? GatewayAdmin(root.path) else {
        checking = false
        stop("Disconnected — invalid local gateway")
        return
      }
      url = URL(string: gateway.endpoint + "/healthz")!
    } else if let text = try? String(contentsOfFile: healthFile, encoding: .utf8),
      let base = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      base.host == "127.0.0.1" || base.host == "localhost"
    {
      url = base.appendingPathComponent("readyz")
    } else {
      checking = false
      if Date().timeIntervalSince(started) > 60 { stop("Disconnected — connection timed out") }
      return
    }
    URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 3)) {
      [weak self] _, response, _ in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.checking = false
        guard self.proxy === gateway, !self.stopping else { return }
        let ready = (response as? HTTPURLResponse)?.statusCode == 200
        if self.localSmoke && self.tunnel == nil && ready {
          print("SMOKE: gateway ready; remote access stayed off")
          if self.toggleSmoke {
            self.connectionSwitch.state = .off
            precondition(
              self.connectionSwitch.sendAction(
                self.connectionSwitch.action, to: self.connectionSwitch.target))
          } else {
            self.stop("Disconnected — Mac access off") { NSApp.terminate(nil) }
          }
          return
        }
        if self.permissionTest && self.tunnel == nil && ready {
          self.update("Local permission test — remote access off", active: true)
          return
        }
        if self.tunnel == nil && ready {
          if !self.credentialPrepared {
            guard !self.preparingCredential else { return }
            self.preparingCredential = true
            self.update("Preparing private connection…", active: true)
            DispatchQueue.global(qos: .userInitiated).async {
              var failure: Error?
              do { try self.configureCredential() } catch { failure = error }
              DispatchQueue.main.async {
                self.preparingCredential = false
                guard self.proxy === gateway, !self.stopping else { return }
                if let failure = failure {
                  self.stop("Disconnected — credential setup failed")
                  self.report(failure.localizedDescription)
                } else {
                  self.credentialPrepared = true
                  self.checkHealth()
                }
              }
            }
            return
          }
          do {
            self.tunnel = try self.launch(
              "work/tunnel-client/tunnel-client",
              [
                "run", "--profile-file",
                self.root.appendingPathComponent("work/tunnel-profiles/macbook-mcpproxy.yaml").path,
                "--health.url-file", self.healthFile,
              ])
            self.update("Connecting…", active: true)
          } catch {
            self.stop("Disconnected — tunnel failed")
            self.report(error.localizedDescription)
          }
        } else if self.tunnel != nil && ready {
          self.update("Connected — Mac access on", active: true)
          if self.smoke {
            print("SMOKE: gateway and tunnel ready")
            self.stop("Disconnected — Mac access off") { NSApp.terminate(nil) }
          }
        } else if Date().timeIntervalSince(self.started) > 60 {
          self.stop("Disconnected — connection lost")
        }
      }
    }.resume()
  }
  func stop(_ message: String, completion: (() -> Void)? = nil) {
    guard !stopping else { return }
    stopping = true
    credentialLock.lock()
    credentialCancelled = true
    let preparation = credentialProcess
    credentialLock.unlock()
    timer?.invalidate()
    timer = nil
    approvalTimer?.invalidate()
    approvalTimer = nil
    if prompting { NSApp.abortModal() }
    update("Disconnecting…", active: false)
    let children = [tunnel, proxy].compactMap { $0 }
    DispatchQueue.global(qos: .userInitiated).async {
      if let preparation, preparation.isRunning {
        self.ownedServices.stop(preparation.processIdentifier)
        preparation.waitUntilExit()
      }
      for child in children where child.isRunning {
        if child === self.proxy { try? self.configureCredential(revoke: true) }
        child.terminate()
        self.ownedServices.stop(child.processIdentifier)
        let deadline = Date().addingTimeInterval(10)
        while child.isRunning && Date() < deadline { usleep(50_000) }
        if child.isRunning {
          kill(child.processIdentifier, SIGKILL)
          child.waitUntilExit()
        }
      }
      DispatchQueue.main.async {
        self.tunnel = nil
        self.proxy = nil
        self.stopping = false
        self.checking = false
        try? self.log?.close()
        self.log = nil
        try? FileManager.default.removeItem(atPath: self.healthFile)
        if let directory = self.approvalDirectory {
          try? FileManager.default.removeItem(at: directory)
        }
        self.approvalDirectory = nil
        self.seenRequests.removeAll()
        self.credentialPrepared = false
        self.preparingCredential = false
        try? FileManager.default.removeItem(
          at: self.root.appendingPathComponent("work/mcpproxy-runtime.key"))
        self.update(message, active: false)
        if self.smoke || self.localSmoke { print("SMOKE: owned services stopped") }
        if self.toggleSmoke {
          precondition(
            self.connectionSwitch.state == .off && self.proxy == nil && self.tunnel == nil
              && self.timer == nil && self.approvalTimer == nil && self.approvalDirectory == nil)
          precondition(
            !FileManager.default.fileExists(
              atPath: self.root.appendingPathComponent("work/mcpproxy-runtime.key").path))
          print(
            "SMOKE: switch actions connected and disconnected; state, timers, credential and permissions cleared"
          )
          NSApp.terminate(nil)
        }
        completion?()
      }
    }
  }
  @objc func disconnect() { stop("Disconnected — Mac access off") }
  @objc func quit() { NSApp.terminate(nil) }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if updating {
      report("Please wait for the dependency update to finish before quitting.")
      return .terminateCancel
    }
    if proxy == nil && tunnel == nil && !stopping { return .terminateNow }
    if stopping { return .terminateCancel }
    stop("Disconnected — Mac access off") { sender.reply(toApplicationShouldTerminate: true) }
    return .terminateLater
  }
}
