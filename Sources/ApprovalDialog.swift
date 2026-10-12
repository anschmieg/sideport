import AppKit

final class ApprovalBackground: NSView {
  override var isOpaque: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }
}

final class ApprovalPrimaryButton: NSButton {
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    layer?.cornerRadius = 8
  }
}

final class ApprovalDialog: NSObject, NSWindowDelegate {
  let panel: NSPanel
  let stack = NSStackView()
  var details: NSScrollView!
  var detailsToggle: NSButton!
  var detailsHeight: NSLayoutConstraint!
  var rememberBox: NSButton?
  var remembersLocation: Bool { rememberBox?.state == .on }
  let contentWidth: CGFloat = 456

  init(
    title: String, reason: String, sections: [(String, String)], duration: String,
    technical: String, allow: String, deny: String, symbol: String, rememberLocation: Bool = false
  ) {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 512, height: 440), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    super.init()
    panel.title = "Sideport"
    panel.delegate = self
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    let content = ApprovalBackground()
    panel.contentView = content
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 18
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
    ])
    let eyebrow = NSStackView()
    eyebrow.orientation = .horizontal
    eyebrow.spacing = 7
    eyebrow.alignment = .centerY
    let icon = NSImageView(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    icon.contentTintColor = .secondaryLabelColor
    icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
    eyebrow.addArrangedSubview(icon)
    eyebrow.addArrangedSubview(
      label("REMOTE AGENT REQUEST", size: 11, weight: .semibold, color: .secondaryLabelColor))
    stack.addArrangedSubview(eyebrow)
    stack.setCustomSpacing(8, after: eyebrow)
    stack.addArrangedSubview(label(title, size: 23, weight: .semibold))
    let purpose = section("Why it’s needed", reason)
    stack.addArrangedSubview(purpose)
    for (heading, body) in sections { stack.addArrangedSubview(section(heading, body)) }
    let footer = label(duration, size: 12, color: .secondaryLabelColor)
    if rememberLocation {
      let checkbox = NSButton(
        checkboxWithTitle: "Remember this location on this Mac", target: nil, action: nil)
      checkbox.state = .on
      checkbox.toolTip =
        "Restore this file scope when you manually reconnect. Revoke it in Remembered locations."
      checkbox.setAccessibilityHelp(
        "When checked, this location is restored on future connections until you forget it.")
      rememberBox = checkbox
      stack.addArrangedSubview(checkbox)
    }
    stack.addArrangedSubview(footer)
    let divider = NSBox()
    divider.boxType = .separator
    divider.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    stack.addArrangedSubview(divider)
    stack.setCustomSpacing(12, after: footer)
    detailsToggle = NSButton(
      title: "▸ Technical details", target: self, action: #selector(toggleDetails))
    detailsToggle.bezelStyle = .inline
    detailsToggle.isBordered = false
    detailsToggle.alignment = .left
    detailsToggle.font = .systemFont(ofSize: 12)
    detailsToggle.contentTintColor = .secondaryLabelColor
    detailsToggle.setAccessibilityLabel("▸ Technical details")
    stack.addArrangedSubview(detailsToggle)
    stack.setCustomSpacing(4, after: detailsToggle)
    details = NSScrollView()
    details.hasVerticalScroller = true
    details.borderType = .noBorder
    details.drawsBackground = false
    let technicalText = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth - 16, height: 140))
    technicalText.string = technical
    technicalText.isEditable = false
    technicalText.isSelectable = true
    technicalText.font = .systemFont(ofSize: 11)
    technicalText.textColor = .secondaryLabelColor
    technicalText.drawsBackground = false
    technicalText.textContainerInset = NSSize(width: 0, height: 3)
    technicalText.textContainer?.widthTracksTextView = true
    technicalText.isVerticallyResizable = true
    technicalText.textContainer?.containerSize = NSSize(
      width: contentWidth - 16, height: .greatestFiniteMagnitude)
    details.documentView = technicalText
    details.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    detailsHeight = details.heightAnchor.constraint(equalToConstant: 140)
    detailsHeight.isActive = true
    stack.addArrangedSubview(details)
    details.isHidden = true
    let buttons = NSStackView()
    buttons.orientation = .horizontal
    buttons.spacing = 10
    buttons.alignment = .centerY
    buttons.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    buttons.addArrangedSubview(spacer)
    let reject = NSButton(title: deny, target: self, action: #selector(rejectRequest))
    reject.bezelStyle = .rounded
    reject.controlSize = .large
    reject.keyEquivalent = "\u{1b}"
    reject.setAccessibilityHelp(
      "Declines this request. The agent can continue with its existing access.")
    let accept = ApprovalPrimaryButton(title: allow, target: self, action: #selector(acceptRequest))
    accept.bezelStyle = .rounded
    accept.controlSize = .large
    accept.isBordered = false
    accept.wantsLayer = true
    accept.attributedTitle = NSAttributedString(
      string: allow,
      attributes: [
        .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .medium),
      ])
    accept.widthAnchor.constraint(greaterThanOrEqualToConstant: 105).isActive = true
    // Approval requires a click or explicit Command-Return, never plain Return.
    accept.keyEquivalent = "\r"
    accept.keyEquivalentModifierMask = .command
    accept.setAccessibilityHelp(
      "Grants only the access described above. If Remember this location is checked, it is also saved for future connections."
    )
    for button in [reject, accept] {
      button.font = .systemFont(ofSize: 13, weight: .medium)
      buttons.addArrangedSubview(button)
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
    }
    stack.addArrangedSubview(buttons)
    resize()
    panel.defaultButtonCell = nil
  }
  func label(
    _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor
  ) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.isSelectable = true
    field.maximumNumberOfLines = 0
    field.lineBreakMode = .byWordWrapping
    field.preferredMaxLayoutWidth = contentWidth
    field.setContentCompressionResistancePriority(.required, for: .vertical)
    field.widthAnchor.constraint(lessThanOrEqualToConstant: contentWidth).isActive = true
    return field
  }
  func section(_ title: String, _ text: String) -> NSStackView {
    let group = NSStackView()
    group.orientation = .vertical
    group.alignment = .leading
    group.spacing = 5
    group.addArrangedSubview(label(title, size: 12, weight: .semibold, color: .secondaryLabelColor))
    group.addArrangedSubview(label(text, size: 14))
    group.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    return group
  }
  func resize() {
    stack.layoutSubtreeIfNeeded()
    let height = max(300, stack.fittingSize.height + 48)
    panel.setContentSize(NSSize(width: 512, height: height))
    panel.contentView?.layoutSubtreeIfNeeded()
    panel.center()
  }
  @objc func toggleDetails() {
    details.isHidden.toggle()
    detailsToggle.title = details.isHidden ? "▸ Technical details" : "▾ Technical details"
    detailsToggle.setAccessibilityLabel(detailsToggle.title)
    resize()
  }
  @objc func rejectRequest() { NSApp.stopModal(withCode: .cancel) }
  @objc func acceptRequest() { NSApp.stopModal(withCode: .OK) }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    NSApp.stopModal(withCode: .cancel)
    return false
  }
  func run(until expires: Double) -> Bool {
    let timeout = DispatchWorkItem {
      NSApp.abortModal()
      self.panel.orderOut(nil)
    }
    DispatchQueue.main.asyncAfter(
      deadline: .now() + max(0, expires / 1000 - Date().timeIntervalSince1970 - 1), execute: timeout
    )
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    defer {
      timeout.cancel()
      panel.orderOut(nil)
    }
    return NSApp.runModal(for: panel) == .OK
  }
  func preview(to path: String) throws {
    panel.makeKeyAndOrderFront(nil)
    panel.contentView?.layoutSubtreeIfNeeded()
    panel.contentView?.displayIfNeeded()
    guard let view = panel.contentView,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    panel.orderOut(nil)
  }
}
