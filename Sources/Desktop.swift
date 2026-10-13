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
  var latest: DesktopObservationResult?
  var observedAt = Date.distantPast
  var savedClipboard: String?
  init() {
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
  nonisolated static func preview(_ bytes: Data) throws -> (Data, Int, Int) {
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else {
      throw SideportError("Cannot decode captured image")
    }
    for maximum in [2304, 1600, 1024, 640] {
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
  func call(_ tool: String, _ args: JSONObject) async throws -> JSONObject {
    if let extra = try await extra(tool, args) { return extra }
    if tool == "permissions" {
      return textResult([
        "screen_recording": await permissions.checkScreenRecordingPermissionLive(forceProbe: true),
        "accessibility": permissions.checkAccessibilityPermission(),
        "event_synthesis": permissions.checkPostEventPermission(),
      ])
    }
    if ["see", "inspect_ui", "capture", "image", "verify_state"].contains(tool) {
      let target: DesktopObservationTargetRequest
      if args["target"] as? String == "screen" {
        target = .screen(index: args["display_index"] as? Int)
      } else if let id = args["window_id"] as? UInt32 {
        target = .windowID(id)
      } else if let app = args["app"] as? String {
        target = .app(identifier: app, window: nil)
      } else {
        target = .frontmost
      }
      let result = try await observation.observe(
        DesktopObservationRequest(
          target: target,
          detection: DesktopDetectionOptions(
            mode: .accessibilityAndOCR, requiresFreshAccessibilityTree: true),
          output: DesktopObservationOutputOptions(saveSnapshot: true, includeImageData: true),
          timeout: DesktopObservationTimeouts(overall: 20, detection: 12, ocr: 8)))
      latest = result
      observedAt = Date()
      var metadata = try encoded(result.withoutImageData())
      metadata["snapshot_id"] = result.files.publishedSnapshotID ?? result.elements?.snapshotId
      let (image, width, height) = try Self.preview(result.capture.imageData)
      metadata["preview"] = [
        "width": width, "height": height, "format": "jpeg",
        "guidance":
          "Preview may be scaled. Use element selectors and original observation bounds for actions.",
      ]
      var content = textResult(metadata)["content"] as! [JSONObject]
      content.append([
        "type": "image", "mimeType": "image/jpeg", "data": image.base64EncodedString(),
      ])
      return ["content": content, "isError": false]
    }
    if tool == "app" {
      defer {
        if args["action"] as? String != "list" && args["action"] as? String != "windows" {
          latest = nil
        }
      }
      switch args["action"] as? String ?? "list" {
      case "list": return textResult(try encoded(await applications.listApplications()))
      case "windows":
        return textResult(
          try encoded(await applications.listWindows(for: Self.string(args, "app"), timeout: 5)))
      case "launch":
        return textResult(
          try encoded(
            await applications.launchApplication(
              request: ApplicationLaunchRequest(
                applicationIdentifier: Self.string(args, "app"), activates: true))))
      case "activate":
        try await applications.activateApplication(identifier: Self.string(args, "app"))
        return textResult(["completed": true])
      case "hide":
        try await applications.hideApplication(identifier: Self.string(args, "app"))
        return textResult(["completed": true])
      case "unhide":
        try await applications.unhideApplication(identifier: Self.string(args, "app"))
        return textResult(["completed": true])
      case "quit":
        return textResult([
          "completed": try await applications.quitApplication(
            identifier: Self.string(args, "app"), force: false)
        ])
      default: throw SideportError("Unknown application action")
      }
    }
    if tool == "clipboard" {
      switch args["action"] as? String ?? "read" {
      case "read", "get", "save":
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard text.utf8.count <= 1_048_576 else {
          throw SideportError("Clipboard text exceeds 1 MiB")
        }
        if args["action"] as? String == "save" { savedClipboard = text }
        return textResult(["text": text])
      case "status": return textResult(["types": NSPasteboard.general.types?.map(\.rawValue) ?? []])
      case "clear":
        NSPasteboard.general.clearContents()
        return textResult(["completed": true])
      case "write", "set", "restore":
        let text: String
        if args["action"] as? String == "restore" {
          guard let savedClipboard else {
            throw SideportError("No clipboard text saved this session")
          }
          text = savedClipboard
        } else {
          guard let value = args["text"] as? String, value.utf8.count <= 32768 else {
            throw SideportError("Provide clipboard text up to 32 KiB")
          }
          text = value
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
          throw SideportError("Cannot write clipboard")
        }
        return textResult(["completed": true])
      default: throw SideportError("Unknown clipboard action")
      }
    }
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
      outcome = try await automation.typeWithOutcome(
        text: Self.string(args, "text"), target: element.id,
        clearExisting: args["clear"] as? Bool ?? false, typingDelay: 5, snapshotId: snapshot
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
          direction: direction, amount: amount, target: element.id, snapshotId: snapshot)
      ).outcome
    case "drag":
      guard args.keys.allSatisfy({ ["from", "to", "snapshot_id", "duration_ms"].contains($0) })
      else { throw SideportError("Drag accepts element selectors only; coordinates are forbidden") }
      let elements = result.elements?.elements.all ?? []
      let from = try Self.select(Self.string(args, "from"), from: elements)
      let to = try Self.select(Self.string(args, "to"), from: elements)
      guard let identity = result.target.detectionContext?.windowMutationIdentity,
        let bounds = result.target.window?.bounds
      else { throw SideportError("Drag requires an exact window observation") }
      let target = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
      let request = ExactWindowDragRequest(
        snapshotID: snapshot, target: target,
        from: CGPoint(x: from.bounds.midX, y: from.bounds.midY),
        to: CGPoint(x: to.bounds.midX, y: to.bounds.midY),
        durationMilliseconds: args["duration_ms"] as? Int ?? 500)
      try request.validate()
      outcome = try await automation.dragExactWindow(request).outcome
    default: throw SideportError("Unknown computer tool")
    }
    // Every mutation consumes its observation; callers must inspect the resulting UI.
    latest = nil
    return Self.actionResult(outcome, operation: tool)
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
