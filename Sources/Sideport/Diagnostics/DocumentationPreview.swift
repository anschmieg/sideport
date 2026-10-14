import AppKit

// Native UI fixtures for documentation. No tunnel, tool execution, desktop
// capture, clipboard read or macOS permission request is involved.
enum DocumentationPreview {
  static func snapshot(_ view: NSView) throws -> NSImage {
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw SideportError("Cannot render documentation view")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let image = NSImage(size: view.bounds.size)
    image.addRepresentation(bitmap)
    return image
  }
  static func save(_ image: NSImage, to path: URL) throws {
    let scale: CGFloat = 2
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw SideportError("Cannot render Retina documentation image") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)
    image.draw(
      in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    bitmap.size = image.size
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw SideportError("Cannot encode documentation image")
    }
    try png.write(to: path)
  }
  static func connectionImage(_ header: NSView, button: NSStatusBarButton) throws -> NSImage {
    let content = try snapshot(header)
    let status = try snapshot(button)
    return NSImage(
      size: NSSize(width: content.size.width, height: content.size.height + 36), flipped: false
    ) { bounds in
      NSColor.windowBackgroundColor.setFill()
      bounds.fill()
      content.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
      status.draw(
        at: NSPoint(x: bounds.maxX - status.size.width - 16, y: content.size.height + 4),
        from: .zero,
        operation: .sourceOver, fraction: 1)
      return true
    }
  }
  static func render(_ destination: URL) throws {
    precondition(Thread.isMainThread)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    NSApp.appearance = NSAppearance(named: .darkAqua)
    let controller = ProxyController()
    controller.setUp()
    defer { NSStatusBar.system.removeStatusItem(controller.item) }
    guard let header = controller.popover.contentViewController?.view,
      let button = controller.item.button
    else {
      throw SideportError("Sideport header is unavailable")
    }
    let panel = NSPanel(
      contentRect: header.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.contentView = header
    panel.appearance = NSApp.appearance
    try save(
      connectionImage(header, button: button),
      to: destination.appendingPathComponent("connection-off.png"))
    controller.connectionSwitch.state = .on
    controller.connectionState.stringValue = "Recent activity · Example agent"
    controller.item.length = 36
    controller.statusArtwork.frame = button.bounds
    controller.statusArtwork.connected = true
    button.highlight(true)
    try save(
      connectionImage(header, button: button),
      to: destination.appendingPathComponent("connection-active.png"))
    button.highlight(false)
    let dialog = ApprovalDialog(
      title: "Allow access to ~/Projects/demo?",
      reason: "Inspect and update this project's source files to resolve its build error.",
      sections: [
        ("What the agent can do", "Read and change files in this folder."),
        ("Location", "~/Projects/demo"),
      ],
      duration: "Access stops when disconnected. Remembered locations return when you reconnect.",
      technical: "Location: ~/Projects/demo\nScope: directory\nAccess: read_write",
      allow: "Allow access", deny: "Don’t allow", symbol: "folder", rememberLocation: true)
    dialog.panel.appearance = NSApp.appearance
    if let view = dialog.panel.contentView {
      try save(snapshot(view), to: destination.appendingPathComponent("folder-approval.png"))
    }
    try DesktopControlIndicator().documentationPreview(
      to: destination.appendingPathComponent("desktop-control.png"))
    panel.orderOut(nil)
    print("Rendered four native UI fixtures; no connection or desktop capture was started")
  }
}
