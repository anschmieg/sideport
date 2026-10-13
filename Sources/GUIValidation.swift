import AppKit
import ApplicationServices
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
final class GUIFixture: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
  let path: String
  var window: NSWindow!
  var input: NSTextField!
  fileprivate var source: FixtureDragSource!
  fileprivate var destination: FixtureDropTarget!
  var timer: Timer?
  init(path: String) { self.path = path }
  func applicationDidFinishLaunching(_ notification: Notification) {
    let panel = NSWindow(
      contentRect: NSRect(x: 200, y: 220, width: 540, height: 330),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    panel.title = "Sideport • temporary automation test"
    panel.isReleasedWhenClosed = false
    window = panel
    input = NSTextField(frame: NSRect(x: 30, y: 240, width: 470, height: 28))
    input.setAccessibilityLabel("Sideport test input")
    input.setAccessibilityIdentifier("sideport-test-input")
    input.delegate = self
    panel.contentView!.addSubview(input)
    let button = NSButton(
      title: "Record test click", target: self, action: #selector(clicked))
    button.frame = NSRect(x: 30, y: 192, width: 200, height: 32)
    panel.contentView!.addSubview(button)
    let picker = NSButton(
      title: "Open test file", target: self, action: #selector(openFile))
    picker.frame = NSRect(x: 280, y: 192, width: 200, height: 32)
    panel.contentView!.addSubview(picker)
    source = FixtureDragSource(frame: NSRect(x: 35, y: 65, width: 170, height: 90))
    source.setAccessibilityElement(true)
    source.setAccessibilityEnabled(true)
    source.setAccessibilityRole(.button)
    source.setAccessibilityLabel("Drag test Alpha")
    source.setAccessibilityIdentifier("sideport-drag-alpha")
    destination = FixtureDropTarget(frame: NSRect(x: 290, y: 65, width: 200, height: 90))
    destination.path = path
    destination.setAccessibilityElement(true)
    destination.setAccessibilityEnabled(true)
    destination.setAccessibilityRole(.button)
    destination.setAccessibilityLabel("Drop test Beta")
    destination.setAccessibilityIdentifier("sideport-drop-beta")
    destination.registerForDraggedTypes([.string])
    panel.contentView!.addSubview(source)
    panel.contentView!.addSubview(destination)
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    panel.makeFirstResponder(input)
    try? privateWrite(["pid": getpid(), "window": panel.windowNumber], path + "/ready.json")
    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        try? privateWrite(
          ["text": self.input.stringValue, "key_window": self.window.isKeyWindow],
          self.path + "/typed.json")
        if FileManager.default.fileExists(atPath: self.path + "/mutate") {
          self.source.setAccessibilityLabel("Replaced test Gamma")
          try? FileManager.default.removeItem(atPath: self.path + "/mutate")
          try? privateWrite(["changed": true], self.path + "/mutated.json")
        }
      }
    }
  }
  func controlTextDidChange(_ notification: Notification) {
    try? privateWrite(["text": input.stringValue], path + "/typed.json")
  }
  @objc func clicked() { try? privateWrite(["clicked": true], path + "/clicked.json") }
  @objc func openFile() {
    let picker = NSOpenPanel()
    picker.directoryURL = URL(fileURLWithPath: path)
    picker.canChooseDirectories = false
    picker.canChooseFiles = true
    picker.beginSheetModal(for: window) { result in
      if result == .OK {
        try? privateWrite(
          ["selected": picker.url?.lastPathComponent ?? ""], self.path + "/picked.json")
      }
    }
  }
}
@MainActor
private final class FixtureDragSource: NSView, NSDraggingSource {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.systemBlue.withAlphaComponent(0.18).setFill()
    bounds.fill()
    ("Alpha" as NSString).draw(
      at: NSPoint(x: 25, y: 35), withAttributes: [.font: NSFont.systemFont(ofSize: 20)])
  }
  override func mouseDown(with event: NSEvent) {
    let item = NSPasteboardItem()
    item.setString("SIDEPORT-SYNTHETIC-DRAG", forType: .string)
    let dragging = NSDraggingItem(pasteboardWriter: item)
    dragging.setDraggingFrame(bounds, contents: NSImage(size: bounds.size))
    beginDraggingSession(with: [dragging], event: event, source: self)
  }
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation { .copy }
}
@MainActor
private final class FixtureDropTarget: NSView {
  var path = ""
  override func draw(_ dirtyRect: NSRect) {
    NSColor.systemGreen.withAlphaComponent(0.18).setFill()
    bounds.fill()
    ("Drop Alpha here" as NSString).draw(
      at: NSPoint(x: 20, y: 35), withAttributes: [.font: NSFont.systemFont(ofSize: 17)])
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard sender.draggingPasteboard.string(forType: .string) == "SIDEPORT-SYNTHETIC-DRAG" else {
      return false
    }
    try? privateWrite(["dropped": true], path + "/dropped.json")
    return true
  }
}
@MainActor
enum GUIValidation {
  static func fixture(_ path: String) throws -> Never {
    guard path.hasPrefix("/private/tmp/sideport-gui-"), try canonical(path, existing: true) == path
    else { throw SideportError("Invalid test fixture directory") }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = GUIFixture(path: path)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
    exit(0)
  }
  static func check() async throws {
    let desktop = NativeDesktop()
    let permissions =
      CommandLine.arguments.contains("--gui-request-permissions")
      ? try await desktop.requestPermissions() : await desktop.permissionStatus()
    guard permissions.values.allSatisfy({ $0 as? Bool == true })
    else {
      throw SideportError(
        "GUI audit deferred: native permissions are not already available. Use an explicitly interactive permission run while present at the Mac."
      )
    }
    // The fixture will take focus. Give the person at the Mac a brief pause
    // before the first automated UI action, including already-approved runs.
    try await Task.sleep(nanoseconds: 3_000_000_000)
    let path = "/private/tmp/sideport-gui-" + UUID().uuidString
    try directory(path)
    let supervisor = ChildSupervisor()
    let service = try BackgroundService(
      supervisor, try canonical(Bundle.main.executablePath!, existing: true),
      ["--gui-fixture", path], environment: ProcessInfo.processInfo.environment, cwd: path)
    defer {
      service.close()
      try? FileManager.default.removeItem(atPath: path)
      desktop.close()
    }
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: path + "/ready.json"), Date() < deadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    let fixture = try jsonObject(Data(contentsOf: URL(fileURLWithPath: path + "/ready.json")))
    guard let window = fixture["window"] as? UInt32 else {
      throw SideportError("GUI fixture did not start")
    }
    // AppKit's field editor and window-management utilities can finish laying
    // out a new window after it first becomes visible. Observe after settling.
    try await Task.sleep(nanoseconds: 1_000_000_000)
    func observe() async throws -> String {
      guard kill(service.pid, 0) == 0 else { throw SideportError("GUI fixture exited") }
      _ = try await desktop.call("see", ["window_id": window])
      guard
        let id = desktop.latest?.files.publishedSnapshotID ?? desktop.latest?.elements?.snapshotId
      else { throw SideportError("GUI fixture observation has no snapshot") }
      return id
    }
    func evidence(_ name: String) async throws {
      for _ in 0..<40 {
        if FileManager.default.fileExists(atPath: path + "/" + name) { return }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      throw SideportError("GUI fixture did not confirm " + name)
    }
    func selector(_ label: String, type: ElementType) throws -> String {
      let elements = desktop.latest?.elements?.elements.all ?? []
      let matches = elements.filter {
        $0.type == type && ($0.label == label || type == .textField) && !$0.isOCRSemanticEvidence
      }
      guard matches.count == 1, let selected = matches.first else {
        print(
          "Fixture elements:",
          elements.map {
            [
              "id": $0.id, "label": $0.label ?? "", "type": $0.type.rawValue,
              "enabled": String($0.isEnabled),
            ]
          })
        throw SideportError("Fixture selector is missing or ambiguous: " + label)
      }
      guard selected.isEnabled, selected.bounds.width > 0, selected.bounds.height > 0 else {
        throw SideportError(
          "Fixture control is disabled or has no bounds: \(label), enabled=\(selected.isEnabled), bounds=\(selected.bounds)"
        )
      }
      return selected.id
    }
    var snapshot = try await observe()
    print("GUI fixture: capture ready")
    _ = try await desktop.call(
      "type",
      [
        "snapshot_id": snapshot, "target": try selector("Sideport test input", type: .textField),
        "text": "Sideport synthetic typing", "clear": true,
      ])
    try await evidence("typed.json")
    var typed = ""
    for _ in 0..<60 {
      typed =
        (try? jsonObject(Data(contentsOf: URL(fileURLWithPath: path + "/typed.json"))))?["text"]
        as? String ?? ""
      if typed == "Sideport synthetic typing" { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard typed == "Sideport synthetic typing" else {
      throw SideportError("Typed fixture text differs: " + typed)
    }
    print("GUI fixture: whole-field text replacement passed")
    snapshot = try await observe()
    _ = try await desktop.call(
      "click",
      [
        "snapshot_id": snapshot, "target": try selector("Sideport test input", type: .textField),
      ])
    try await Task.sleep(nanoseconds: 200_000_000)
    snapshot = try await observe()
    _ = try await desktop.call(
      "type",
      [
        "snapshot_id": snapshot, "target": try selector("Sideport test input", type: .textField),
        "text": " café α🙂", "clear": false,
      ])
    for _ in 0..<60 {
      typed =
        (try? jsonObject(Data(contentsOf: URL(fileURLWithPath: path + "/typed.json"))))?["text"]
        as? String ?? ""
      if typed.contains("café α🙂") { break }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard typed.contains("café α🙂"), typed.contains("Sideport synthetic typing") else {
      throw SideportError("Unicode insertion failed to preserve the fixture text: " + typed)
    }
    print("GUI fixture: Unicode insertion passed")
    snapshot = try await observe()
    _ = try await desktop.call(
      "click",
      ["snapshot_id": snapshot, "target": try selector("Record test click", type: .button)])
    try await evidence("clicked.json")
    print("GUI fixture: selected button click passed")
    snapshot = try await observe()
    _ = try await desktop.call(
      "drag",
      [
        "snapshot_id": snapshot, "from": try selector("Drag test Alpha", type: .button),
        "to": try selector("Drop test Beta", type: .button),
      ])
    try await evidence("dropped.json")
    snapshot = try await observe()
    let staleFrom = try selector("Drag test Alpha", type: .button)
    let staleTo = try selector("Drop test Beta", type: .button)
    try privateWrite(["change": true], path + "/mutate")
    try await evidence("mutated.json")
    do {
      _ = try await desktop.call(
        "drag", ["snapshot_id": snapshot, "from": staleFrom, "to": staleTo])
      throw SideportError("Changed drag selector was accepted")
    } catch { guard error.localizedDescription.contains("selector changed") else { throw error } }
    print(
      "PASS: signed GUI capture, exact typing/clicking, selector drag and changed-selector refusal")
    // Compare unsandboxed access with an actual sandboxed process against this
    // one fixture window; no desktop image or user clipboard contents are read.
    guard let root = ProcessInfo.processInfo.environment["SIDEPORT_HOME"] else {
      throw SideportError("GUI isolation check requires private controller state")
    }
    let session = root + "/work/permission-sessions/" + UUID().uuidString
    try directory(session)
    try privateWrite([], session + "/grants.json")
    let context = try NativeContext(root: root, session: session)
    let runtime = try RuntimeSupport(context, supervisor)
    defer { runtime.close() }
    for (mode, target) in [("--screen-probe", String(window)), ("--ax-probe", String(service.pid))]
    {
      let positive = try await supervisor.run(
        context.executable, [mode, target], environment: ProcessInfo.processInfo.environment,
        cwd: path, timeout: 15)
      guard positive.code == 0, try jsonObject(positive.stdout)["available"] as? Bool == true else {
        throw SideportError(
          "GUI privacy probe lacks a positive control for \(mode): exit=\(positive.code), \(String(decoding: positive.stdout + positive.stderr, as: UTF8.self))"
        )
      }
      let negative = try await runtime.launchProfile(
        runtime.profile([]), context.executable, [mode, target], cwd: runtime.scratch, timeout: 15)
      print(
        "GUI privacy probe: \(mode), sandbox exit=\(negative.code), \(String(decoding: negative.stdout, as: UTF8.self))"
      )
      guard negative.code != 0 || (try? jsonObject(negative.stdout))?["available"] as? Bool != true
      else {
        throw SideportError("Sandboxed code bypassed the computer-control gate through \(mode)")
      }
    }
    print("PASS: kernel refusal of screen capture and Accessibility from sandboxed children")
  }
}
