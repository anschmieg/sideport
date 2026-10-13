import AppKit
import PeekabooAutomationKit
import PeekabooFoundation

extension NativeDesktop {
  nonisolated static func region(_ args: JSONObject) throws -> CGRect {
    guard let x = args["x"] as? Double, let y = args["y"] as? Double,
      let width = args["width"] as? Double, let height = args["height"] as? Double,
      [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0,
      width <= 20000, height <= 20000
    else { throw SideportError("Provide finite positive capture bounds up to 20000 points") }
    return CGRect(x: x, y: y, width: width, height: height)
  }
  func capture(_ tool: String, _ args: JSONObject) async throws -> JSONObject {
    if args["target"] as? String == "all_screens" {
      guard ["image", "capture"].contains(tool), args["path"] == nil else {
        throw SideportError("Capture displays inline, or save each display individually")
      }
      let screens = ScreenService().listScreens()
      guard !screens.isEmpty, screens.count <= 4 else {
        throw SideportError("Capture at most four displays individually")
      }
      var content: [JSONObject] = []
      for screen in screens {
        var input = args
        input["target"] = "screen"
        input["display_index"] = screen.index
        let response = try await capture(tool, input)
        content += response["content"] as? [JSONObject] ?? []
      }
      latest = nil
      return ["content": content, "isError": false]
    }
    let target: DesktopObservationTargetRequest
    if let region = args["region"] as? JSONObject {
      target = .area(try Self.region(region))
    } else if args["target"] as? String == "screen" {
      target = .screen(index: args["display_index"] as? Int)
    } else if args["target"] as? String == "menubar" {
      target = .menubar
    } else if let id = args["window_id"] as? UInt32 {
      target = .windowID(id)
    } else if let app = args["app"] as? String {
      let window = (args["window_title"] as? String).map { WindowSelection.title($0) }
      target = .app(identifier: app, window: window)
    } else {
      target = .frontmost
    }
    let rawFormat = args["format"] as? String ?? "png"
    guard ["png", "jpg", "data"].contains(rawFormat) else {
      throw SideportError("Capture format must be png, jpg or data")
    }
    let scale = args["scale"] as? String ?? "logical"
    guard ["logical", "1x", "native", "retina", "2x"].contains(scale) else {
      throw SideportError("Unknown capture scale")
    }
    let maximum = args["max_dimension"] as? Int ?? 2304
    guard (320...4096).contains(maximum) else {
      throw SideportError("Preview dimension must be 320...4096")
    }
    let observing = !["image", "capture"].contains(tool)
    let result = try await observation.observe(
      DesktopObservationRequest(
        target: target,
        capture: DesktopCaptureOptions(
          scale: ["native", "retina", "2x"].contains(scale) || args["retina"] as? Bool == true
            ? .native : .logical1x),
        detection: DesktopDetectionOptions(
          mode: observing ? .accessibilityAndOCR : .none, requiresFreshAccessibilityTree: observing),
        output: DesktopObservationOutputOptions(
          format: rawFormat == "jpg" ? .jpg : .png, saveSnapshot: true, includeImageData: true),
        timeout: DesktopObservationTimeouts(overall: 20, detection: 12, ocr: 8)))
    latest = result
    observedAt = Date()
    var metadata = try encoded(result.withoutImageData())
    metadata["snapshot_id"] = result.files.publishedSnapshotID ?? result.elements?.snapshotId
    if let path = args["path"] as? String {
      _ = try await transfer(path, data: result.capture.imageData)
      metadata["saved_path"] = path
    }
    let (image, width, height) = try Self.preview(result.capture.imageData, maximum: maximum)
    metadata["preview"] = [
      "width": width, "height": height, "format": "jpeg",
      "guidance":
        "Preview may be scaled. Use fresh element selectors and original observation bounds for actions.",
    ]
    var content = textResult(metadata)["content"] as! [JSONObject]
    content.append(["type": "image", "mimeType": "image/jpeg", "data": image.base64EncodedString()])
    return ["content": content, "isError": false]
  }
  // Freshly resolve both semantic selectors before converting them to native
  // pointer endpoints. Snapshot-generated IDs alone cannot survive changed rows.
  nonisolated static func refreshed(_ old: DetectedElement, from elements: [DetectedElement]) throws
    -> DetectedElement
  {
    guard let label = old.label, !label.isEmpty, !old.isOCRSemanticEvidence else {
      throw SideportError(
        "Drag requires uniquely labelled native elements; observe the target again")
    }
    let candidates = elements.filter {
      $0.label == label && $0.type == old.type && !$0.isOCRSemanticEvidence
    }
    guard candidates.count == 1, let current = candidates.first, current.isEnabled,
      current.bounds.width > 0, current.bounds.height > 0
    else {
      throw SideportError("Drag selector changed or became ambiguous; observe the target again")
    }
    for key in ["identifier", "AXIdentifier", "role", "subrole"] {
      if let value = old.attributes[key], current.attributes[key] != value {
        throw SideportError("Drag element identity changed; observe the target again")
      }
    }
    return current
  }
}
