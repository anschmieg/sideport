import AppKit
import ImageIO
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
final class NativeDesktop {
  let permissions = PermissionsService()
  let snapshots = InMemorySnapshotManager()
  let automation: UIAutomationService
  let applications: ApplicationService
  let observation: DesktopObservationService
  var indicatorWindow: Int?
  var indicatorAction = UUID().uuidString
  var latest: DesktopObservationResult? {
    didSet { if let window = latest?.target.window?.windowID { indicatorWindow = Int(window) } }
  }
  var observedAt = Date.distantPast
  let runtime: RuntimeSupport?
  let indicatorsRequired: Bool
  let pasteboard: NSPasteboard
  let clipboardNamespace = UUID().uuidString
  let clipboard: ClipboardService
  var clipboardSlots = Set<String>()
  var requestedNativePermissions = false
  init(
    runtime: RuntimeSupport? = nil, pasteboard: NSPasteboard = .general,
    indicatorsRequired: Bool = ProcessInfo.processInfo.environment["SIDEPORT_INDICATORS"] == "1"
  ) {
    self.indicatorsRequired = indicatorsRequired
    self.runtime = runtime
    self.pasteboard = pasteboard
    clipboard = ClipboardService(pasteboard: pasteboard, sizeLimit: 1_048_576)
    let logging = LoggingService(subsystem: "local.sideport.automation")
    let capture = ScreenCaptureService(
      loggingService: logging, feedbackClient: NoopAutomationFeedbackClient())
    automation = UIAutomationService(
      snapshotManager: snapshots, loggingService: logging,
      feedbackClient: NoopAutomationFeedbackClient())
    applications = ApplicationService(
      permissions: permissions, feedbackClient: NoopAutomationFeedbackClient())
    observation = DesktopObservationService(
      screenCapture: capture, automation: automation, applications: applications,
      snapshotManager: snapshots)
  }
  nonisolated static func string(_ args: JSONObject, _ key: String, maximum: Int = 32768) throws
    -> String
  {
    guard let value = args[key] as? String, !value.isEmpty, value.utf8.count <= maximum else {
      throw SideportError("Provide \(key) (maximum \(maximum) bytes)")
    }
    return value
  }
  nonisolated static func select(_ selector: String, from elements: [DetectedElement]) throws
    -> DetectedElement
  {
    let exact = elements.filter { $0.id == selector }
    let candidates = exact.isEmpty ? elements.filter { $0.label == selector } : exact
    guard candidates.count == 1, let element = candidates.first, element.isEnabled,
      element.bounds.width > 0, element.bounds.height > 0
    else {
      throw SideportError(
        "Selector must identify exactly one enabled element in the latest observation")
    }
    return element
  }
  func retained(_ args: JSONObject) throws -> (DesktopObservationResult, String) {
    guard let latest, Date().timeIntervalSince(observedAt) < 60,
      let id = latest.files.publishedSnapshotID ?? latest.elements?.snapshotId,
      args["snapshot_id"] as? String == id
    else {
      throw SideportError("Observe the target window again and use its snapshot_id before acting")
    }
    return (latest, id)
  }
  func encoded<T: Encodable>(_ value: T) throws -> JSONObject {
    try jsonObject(JSONEncoder().encode(value))
  }
  nonisolated static func preview(_ bytes: Data, maximum: Int = 2304) throws -> (Data, Int, Int) {
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else {
      throw SideportError("Cannot decode captured image")
    }
    for maximum in Array(Set([maximum, min(maximum, 1600), min(maximum, 1024), min(maximum, 640)]))
      .sorted(by: >)
    {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maximum,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
      else { continue }
      let bitmap = NSBitmapImageRep(cgImage: image)
      if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]),
        jpeg.count <= 524288
      {
        return (jpeg, image.width, image.height)
      }
    }
    throw SideportError("Captured image exceeds the connection’s response limit")
  }
  func publishActivity(_ args: JSONObject, busy: Bool, screenWide: Bool) throws {
    guard let runtime else { return }
    var value: JSONObject = [
      "pid": getpid(), "at": Date().timeIntervalSince1970, "busy": busy, "screen_wide": screenWide,
      "action": indicatorAction,
    ]
    value["identity"] = OwnedExecution.token(getpid()).map(OwnedExecution.values) ?? []
    if let display = args["display_index"] as? Int { value["display"] = display }
    if let window = args["window_id"] as? UInt32 {
      value["window"] = window
    } else if let window = latest?.target.window?.windowID {
      value["window"] = window
    } else if let window = indicatorWindow {
      value["window"] = window
    }
    try privateWrite(value, runtime.context.session + "/desktop-activity.json")
  }
  func call(_ tool: String, _ args: JSONObject) async throws -> JSONObject {
    let indicates = tool != "permissions"
    let screenWide =
      ["screen", "all_screens", "menubar"].contains(args["target"] as? String ?? "")
      || ["app", "space", "dock"].contains(tool)
    if indicates {
      indicatorAction = UUID().uuidString
      let retargeting =
        ["see", "inspect_ui", "capture", "image", "verify_state"].contains(tool)
        && args["window_id"] == nil
      try publishActivity(args, busy: true, screenWide: screenWide || retargeting)
    }
    defer { if indicates { try? publishActivity(args, busy: false, screenWide: screenWide) } }
    if indicates, let runtime, indicatorsRequired {
      let deadline = Date().addingTimeInterval(2)
      var visible = false
      while Date() < deadline {
        let path = runtime.context.session + "/desktop-visible.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 1024,
          let receipt = try? jsonObject(data), receipt["action"] as? String == indicatorAction
        {
          visible = true
          break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      guard visible else {
        throw SideportError(
          "Computer control paused because its local activity indicator is unavailable")
      }
    }
    if let extra = try await extra(tool, args) { return extra }
    if tool == "permissions" {
      return textResult(await permissionStatus())
    }
    if ["see", "inspect_ui", "capture", "image", "verify_state"].contains(tool) {
      return try await capture(tool, args)
    }
    if tool == "app" { return try await application(args) }
    if tool == "clipboard" { return try await clipboardAction(args) }
    if tool == "sleep" {
      let seconds = args["seconds"] as? Double ?? 1
      guard seconds >= 0, seconds <= 10 else {
        throw SideportError("Sleep must be between 0 and 10 seconds")
      }
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      return textResult(["completed": true])
    }
    let (result, snapshot) = try retained(args)
    defer { latest = nil }
    var outcome: DesktopActionOutcome?
    switch tool {
    case "click":
      let element = try Self.select(
        Self.string(args, "target"), from: result.elements?.elements.all ?? [])
      let click: ClickType =
        args["click_type"] as? String == "right"
        ? .right : args["click_type"] as? String == "double" ? .double : .single
      outcome = try await automation.clickWithOutcome(
        target: .elementId(element.id), clickType: click, snapshotId: snapshot
      ).outcome
    case "type":
      let element = try Self.select(
        Self.string(args, "target"), from: result.elements?.elements.all ?? [])
      guard let identity = result.target.detectionContext?.windowMutationIdentity,
        let bounds = result.target.window?.bounds
      else { throw SideportError("Text input requires an exact window observation") }
      let text = try Self.string(args, "text")
      let delay = try Self.typingDelay(args)
      if args["clear"] as? Bool == true, args["delay_ms"] == nil {
        // Whole-field replacement has no need for physical shortcuts or input
        // focus. Only fall back if the driver proves it dispatched no mutation.
        do {
          outcome = try await automation.setValueWithOutcome(
            target: element.id, value: .string(text), snapshotId: snapshot
          ).outcome
          break
        } catch let failure as DesktopActionFailure {
          guard !failure.outcome.dispatchState.mutationDispatched,
            failure.outcome.state == .refused,
            failure.outcome.refusalReason == .operationUnsupported
          else { throw failure }
        }
      }
      // Bind the receiver before editing. The targeted driver uses Accessibility
      // text edits or literal Unicode, rather than keyboard-layout key positions.
      let focused = try await automation.focusExactElementWithOutcome(
        target: .elementId(element.id), snapshotId: snapshot,
        expectedWindowIdentity: identity, expectedWindowBounds: bounds)
      let actions: [TypeAction] =
        (args["clear"] as? Bool == true ? [.clear] : []) + [.text(text)]
      outcome = try await automation.typeActionsWithOutcome(
        actions, cadence: .fixed(milliseconds: delay), snapshotId: snapshot,
        target: ExactWindowKeyboardTarget(
          windowIdentity: identity, windowBounds: bounds, focusedElement: focused.payload)
      ).outcome
    case "set_value":
      let element = try Self.select(
        Self.string(args, "target"), from: result.elements?.elements.all ?? [])
      outcome = try await automation.setValueWithOutcome(
        target: element.id, value: .string(Self.string(args, "value")), snapshotId: snapshot
      ).outcome
    case "select_text":
      let element = try Self.select(
        Self.string(args, "target"), from: result.elements?.elements.all ?? [])
      outcome = try await automation.selectText(
        target: element.id,
        request: TextSelectionRequest(
          text: Self.string(args, "text"), prefix: args["prefix"] as? String,
          suffix: args["suffix"] as? String), snapshotId: snapshot
      ).outcome
    case "press", "paste":
      guard let identity = result.target.detectionContext?.windowMutationIdentity,
        let bounds = result.target.window?.bounds
      else { throw SideportError("Keyboard input requires an exact window observation") }
      outcome = try await automation.hotkeyWithOutcome(
        keys: tool == "paste" ? "cmd+v" : Self.string(args, "keys", maximum: 200), holdDuration: 50,
        expectedWindowIdentity: identity, expectedWindowBounds: bounds
      ).outcome
    case "scroll":
      let element = try Self.select(
        Self.string(args, "target"), from: result.elements?.elements.all ?? [])
      guard let direction = ScrollDirection(rawValue: args["direction"] as? String ?? "down") else {
        throw SideportError("Invalid scroll direction")
      }
      let amount = args["amount"] as? Int ?? 3
      guard (1...100).contains(amount) else { throw SideportError("Invalid scroll amount") }
      outcome = try await automation.scrollWithOutcome(
        ScrollRequest(
          direction: direction, amount: amount, target: element.id,
          smooth: args["smooth"] as? Bool ?? false, delay: try Self.typingDelay(args),
          snapshotId: snapshot)
      ).outcome
    case "drag":
      guard
        args.keys.allSatisfy({
          ["from", "to", "snapshot_id", "duration_ms", "delivery"].contains($0)
        })
      else { throw SideportError("Drag accepts element selectors only; coordinates are forbidden") }
      let delivery = args["delivery"] as? String ?? "foreground"
      let duration = args["duration_ms"] as? Int ?? 500
      guard ["foreground", "background"].contains(delivery), (1...10000).contains(duration) else {
        throw SideportError(
          "Choose foreground/background drag and a duration of 1...10000 milliseconds")
      }
      let elements = result.elements?.elements.all ?? []
      let previousFrom = try Self.select(Self.string(args, "from"), from: elements)
      let previousTo = try Self.select(Self.string(args, "to"), from: elements)
      guard let identity = result.target.detectionContext?.windowMutationIdentity,
        let window = result.target.window?.windowID, let captureWindow = UInt32(exactly: window),
        SystemIdentityResolver.validateWindowMutationIdentity(identity)
      else { throw SideportError("Drag requires an exact window observation") }
      if delivery == "foreground" {
        let windows = WindowManagementService(
          applicationService: applications, feedbackClient: NoopAutomationFeedbackClient())
        _ = try await windows.focusWindowActionResult(
          target: .windowId(Int(window)), expectedIdentity: identity)
        try await Task.sleep(nanoseconds: 100_000_000)
      }
      let fresh = try await observation.observe(
        DesktopObservationRequest(
          target: .windowID(captureWindow),
          detection: DesktopDetectionOptions(
            mode: .accessibility, requiresFreshAccessibilityTree: true),
          output: DesktopObservationOutputOptions(saveSnapshot: true),
          timeout: DesktopObservationTimeouts(overall: 10, detection: 8)))
      guard let currentIdentity = fresh.target.detectionContext?.windowMutationIdentity,
        identity.hasSameStableReceipt(as: currentIdentity),
        let bounds = fresh.target.window?.bounds,
        let freshID = fresh.files.publishedSnapshotID ?? fresh.elements?.snapshotId
      else { throw SideportError("Drag target window changed; observe it again") }
      let current = fresh.elements?.elements.all ?? []
      let from = try Self.refreshed(previousFrom, from: current)
      let to = try Self.refreshed(previousTo, from: current)
      let detection = try await snapshots.getDetectionResult(snapshotId: freshID)
      let receipt = try SnapshotTargetReceiptPlanner.assemble(
        snapshotID: freshID, detectionResult: detection
      ).receipt.requireIdentity()
      guard let target = receipt.exactWindow,
        target.identity.hasSameStableReceipt(as: currentIdentity), target.bounds == bounds
      else { throw SideportError("Fresh drag receipt does not match the observed window") }
      let request = ExactWindowDragRequest(
        snapshotID: freshID, target: target,
        from: CGPoint(x: from.bounds.midX, y: from.bounds.midY),
        to: CGPoint(x: to.bounds.midX, y: to.bounds.midY),
        durationMilliseconds: duration)
      try request.validate()
      if delivery == "background" {
        outcome = try await automation.dragExactWindow(request).outcome
      } else {
        guard
          NSWorkspace.shared.frontmostApplication?.processIdentifier
            == currentIdentity.ownerProcessIdentifier,
          SystemIdentityResolver.validateWindowMutationIdentity(currentIdentity)
        else { throw SideportError("Foreground drag target changed; observe the window again") }
        outcome = try await automation.dragWithOutcome(
          DragOperationRequest(
            from: request.from, to: request.to, duration: duration,
            steps: 20, modifiers: nil, profile: .linear)
        ).outcome
      }
    default: throw SideportError("Unknown computer tool")
    }
    // Every mutation consumes its observation; callers must inspect the resulting UI.
    latest = nil
    return Self.actionResult(outcome, operation: tool)
  }
  func close() {
    latest = nil
    for slot in clipboardSlots {
      let name =
        pasteboard.name.rawValue + ".boo.peekaboo.clipboard.slot." + clipboardNamespace + "-" + slot
      let saved = NSPasteboard(name: NSPasteboard.Name(name))
      saved.clearContents()
      saved.releaseGlobally()
    }
    clipboardSlots.removeAll()
  }
  nonisolated static func actionResult(_ outcome: DesktopActionOutcome?, operation: String)
    -> JSONObject
  {
    var receipt: JSONObject = [
      "completed": outcome?.state == .confirmedChange || outcome?.state == .confirmedNoChange,
      "status": outcome?.state.rawValue ?? "unverified",
      "next": ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: operation),
    ]
    if let outcome, let bytes = try? JSONEncoder().encode(outcome),
      let encoded = try? jsonObject(bytes)
    {
      receipt["outcome"] = encoded
    }
    return textResult(receipt, error: outcome?.state == .refused || outcome?.state == .partial)

  }
}
