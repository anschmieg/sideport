import AppKit
import Darwin

// Gateway presence is separate from tunnel readiness. Only current, active
// sessions authenticated by Sideport's scoped token count as remote agents.
enum AgentPresence {
  static func name(_ raw: String?) -> String {
    let cleaned = (raw ?? "").unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0)
        && ![0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains(
          $0.value)
    }
    let value = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(
      in: .whitespacesAndNewlines)
    return value.isEmpty ? "Remote agent" : String(value.prefix(48))
  }
  static func clients(_ response: JSONObject, since: Date) -> [String] {
    let data = response["data"] as? JSONObject ?? response
    let rows = data["sessions"] as? [JSONObject] ?? []
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return rows.prefix(100).compactMap { row in
      guard row["status"] as? String == "active",
        row["token_name"] as? String == "mac-chatgpt-session",
        let start = row["start_time"] as? String
      else { return nil }
      var date = formatter.date(from: start)
      if date == nil {
        formatter.formatOptions = [.withInternetDateTime]
        date = formatter.date(from: start)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      }
      guard let date, date >= since else { return nil }
      return name(row["client_name"] as? String)
    }
  }
  static func desktopActive(_ state: JSONObject, now: Date = Date()) -> Bool {
    guard let pid = state["pid"] as? Int32, pid > 1, kill(pid, 0) == 0,
      let identity = state["identity"] as? [UInt32],
      OwnedExecution.token(pid).map(OwnedExecution.values) == identity,
      let time = state["at"] as? Double
    else { return false }
    let age = now.timeIntervalSince1970 - time
    return age >= 0 && age < (state["busy"] as? Bool == true ? 310 : 8)
  }
}

enum SideportGlyph {
  static func image(connected: Bool) -> NSImage {
    let size = NSSize(width: connected ? 36 : 24, height: 22)
    let image = NSImage(size: size, flipped: false) { bounds in
      if connected {
        NSColor.systemOrange.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
      }
      (connected ? NSColor.white : NSColor.labelColor).setStroke()
      let x = (size.width - 16) / 2
      // An open side port, with an incoming arrow: distinct from a monitor.
      let port = NSBezierPath()
      port.lineWidth = 2
      port.lineCapStyle = .round
      port.move(to: NSPoint(x: x + 9, y: 4))
      port.line(to: NSPoint(x: x + 15, y: 4))
      port.line(to: NSPoint(x: x + 15, y: 18))
      port.line(to: NSPoint(x: x + 9, y: 18))
      port.stroke()
      let arrow = NSBezierPath()
      arrow.lineWidth = 2
      arrow.lineCapStyle = .round
      arrow.lineJoinStyle = .round
      arrow.move(to: NSPoint(x: x, y: 11))
      arrow.line(to: NSPoint(x: x + 10, y: 11))
      arrow.move(to: NSPoint(x: x + 6, y: 7))
      arrow.line(to: NSPoint(x: x + 10, y: 11))
      arrow.line(to: NSPoint(x: x + 6, y: 15))
      arrow.stroke()
      return true
    }
    image.isTemplate = !connected
    return image
  }
}

final class DesktopControlIndicator {
  private var outline: NSPanel?
  private var pill: NSPanel?
  private var label: NSTextField?
  var onStop: (() -> Void)?
  func hide() {
    precondition(Thread.isMainThread)
    outline?.orderOut(nil)
    pill?.orderOut(nil)
  }
  private func panel(_ frame: NSRect, interactive: Bool) -> NSPanel {
    let panel = NSPanel(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = interactive
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = !interactive
    panel.sharingType = .none
    return panel
  }
  func show(client: String, window: UInt32?, screenWide: Bool, displayIndex: Int? = nil) {
    precondition(Thread.isMainThread)
    let screens = NSScreen.screens
    guard let primary = screens.first else {
      hide()
      return
    }
    var frame: NSRect?
    if !screenWide, let window,
      let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, window) as? [JSONObject],
      let row = rows.first(where: { $0[kCGWindowNumber as String] as? UInt32 == window }),
      let bounds = row[kCGWindowBounds as String] as? [String: Any],
      let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 0,
      rect.height > 0
    {
      frame = NSRect(
        x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
    if frame == nil, let index = displayIndex, screens.indices.contains(index) {
      frame = screens[index].frame
    }
    if frame == nil {
      frame =
        screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.frame ?? primary.frame
    }
    guard let frame else { return }
    present(client: client, frame: frame)
  }
  private func present(client: String, frame: NSRect) {
    let screens = NSScreen.screens
    guard let primary = screens.first else { return }
    if outline == nil {
      outline = panel(frame, interactive: false)
      let view = NSView()
      view.wantsLayer = true
      view.layer?.borderWidth = 3
      view.layer?.borderColor = NSColor.systemOrange.cgColor
      view.layer?.cornerRadius = 10
      outline?.contentView = view
    }
    outline?.setFrame(frame.insetBy(dx: 2, dy: 2), display: true)
    outline?.orderFrontRegardless()
    if pill == nil {
      let panel = panel(NSRect(x: 0, y: 0, width: 360, height: 42), interactive: true)
      let view = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 360, height: 42))
      view.material = .hudWindow
      view.blendingMode = .behindWindow
      view.state = .active
      view.wantsLayer = true
      view.layer?.cornerRadius = 21
      view.layer?.masksToBounds = true
      let icon = NSImageView(frame: NSRect(x: 13, y: 10, width: 24, height: 22))
      icon.image = SideportGlyph.image(connected: true)
      view.addSubview(icon)
      let text = NSTextField(labelWithString: "")
      text.frame = NSRect(x: 44, y: 12, width: 238, height: 18)
      text.font = .systemFont(ofSize: 12, weight: .medium)
      text.lineBreakMode = .byTruncatingTail
      view.addSubview(text)
      label = text
      let stop = NSButton(title: "Stop", target: self, action: #selector(stopControl))
      stop.frame = NSRect(x: 286, y: 7, width: 62, height: 28)
      stop.bezelStyle = .rounded
      stop.setAccessibilityLabel("Stop remote computer control and disconnect Sideport")
      stop.toolTip = "Disconnects Sideport and stops remote access"
      view.addSubview(stop)
      panel.contentView = view
      pill = panel
    }
    label?.stringValue = "Computer use · " + AgentPresence.name(client)
    let screen = screens.first(where: { $0.frame.intersects(frame) }) ?? primary
    let visible = screen.visibleFrame
    pill?.setFrameOrigin(NSPoint(x: visible.maxX - 372, y: visible.minY + 12))
    pill?.orderFrontRegardless()
  }
  func documentationPreview(to path: URL) throws {
    precondition(Thread.isMainThread)
    let fixture = NSPanel(
      contentRect: NSRect(x: 80, y: 120, width: 480, height: 240),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    fixture.title = "Example workspace · Documentation fixture"
    fixture.appearance = NSApp.appearance
    fixture.ignoresMouseEvents = true
    fixture.isReleasedWhenClosed = false
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    for (index, text) in ["Demo project", "README.md", "Sources/main.swift", "Tests/"].enumerated()
    {
      let label = NSTextField(labelWithString: text)
      label.frame = NSRect(x: 26, y: 194 - index * 38, width: 420, height: 24)
      label.font =
        index == 0
        ? .systemFont(ofSize: 17, weight: .semibold)
        : .monospacedSystemFont(ofSize: 13, weight: .regular)
      content.addSubview(label)
    }
    fixture.contentView = content
    fixture.orderFrontRegardless()
    defer {
      hide()
      fixture.orderOut(nil)
    }
    // Documentation knows its own Cocoa fixture frame. No window-server
    // metadata or recording permission is needed to render these native views.
    present(client: "Example agent", frame: fixture.frame)
    guard let outlineView = outline?.contentView, let pillView = pill?.contentView,
      let theme = fixture.contentView?.superview
    else { throw SideportError("Missing documentation indicator views") }
    let window = try DocumentationPreview.snapshot(theme)
    let border = try DocumentationPreview.snapshot(outlineView)
    let badge = try DocumentationPreview.snapshot(pillView)
    let canvas = NSImage(
      size: NSSize(
        width: max(window.size.width, border.size.width) + 32,
        height: max(window.size.height, border.size.height) + 92), flipped: false
    ) { rect in
      NSColor.windowBackgroundColor.setFill()
      rect.fill()
      window.draw(at: NSPoint(x: 16, y: 76), from: .zero, operation: .sourceOver, fraction: 1)
      border.draw(at: NSPoint(x: 18, y: 78), from: .zero, operation: .sourceOver, fraction: 1)
      badge.draw(
        at: NSPoint(x: rect.width - badge.size.width - 16, y: 16), from: .zero,
        operation: .sourceOver, fraction: 1)
      return true
    }
    try DocumentationPreview.save(canvas, to: path)
  }
  func checkAndPreview(_ path: String) throws {
    precondition(Thread.isMainThread)
    var stopped = false
    onStop = { stopped = true }
    show(client: "Test agent", window: nil, screenWide: true)
    guard let outline, let pill, let view = pill.contentView,
      outline.ignoresMouseEvents, !pill.ignoresMouseEvents, !pill.isKeyWindow,
      let stop = view.subviews.compactMap({ $0 as? NSButton }).first
    else { throw SideportError("Invalid computer-control indicator") }
    let preview = NSImage(size: NSSize(width: 400, height: 100), flipped: false) { rect in
      NSColor.windowBackgroundColor.setFill()
      rect.fill()
      SideportGlyph.image(connected: false).draw(
        at: NSPoint(x: 22, y: 67), from: .zero, operation: .sourceOver, fraction: 1)
      SideportGlyph.image(connected: true).draw(
        at: NSPoint(x: 68, y: 67), from: .zero, operation: .sourceOver, fraction: 1)
      return true
    }
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw SideportError("Cannot render indicator preview")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    preview.lockFocus()
    NSImage(cgImage: bitmap.cgImage!, size: view.bounds.size).draw(
      at: NSPoint(x: 20, y: 12), from: .zero, operation: .sourceOver, fraction: 1)
    preview.unlockFocus()
    guard let tiff = preview.tiffRepresentation, let image = NSBitmapImageRep(data: tiff),
      let png = image.representation(using: .png, properties: [:])
    else { throw SideportError("Cannot encode preview") }
    try png.write(to: URL(fileURLWithPath: path))
    stop.performClick(nil)
    guard stopped, !pill.isVisible, !outline.isVisible else {
      throw SideportError("Stop did not dismiss indicators")
    }
    print(
      "PASS: distinct icon, connected pill, click-through outline, nonactivating client pill and Stop callback"
    )
  }
  @objc private func stopControl() {
    hide()
    onStop?()
  }
}
