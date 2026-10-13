import AppKit
import Darwin
import PeekabooAutomationKit
import PeekabooFoundation
import UniformTypeIdentifiers

extension NativeDesktop {
  nonisolated static func typingDelay(_ args: JSONObject) throws -> Int {
    let value = args["delay_ms"] as? Int ?? 20
    guard (0...1000).contains(value) else {
      throw SideportError("Typing delay must be 0...1000 milliseconds")
    }
    return value
  }
  func application(_ args: JSONObject) async throws -> JSONObject {
    let action = args["action"] as? String ?? "list"
    defer { if action != "list" && action != "windows" { latest = nil } }
    switch action {
    case "list": return textResult(try encoded(await applications.listApplications()))
    case "windows":
      return textResult(
        try encoded(await applications.listWindows(for: Self.string(args, "app"), timeout: 5)))
    case "launch", "open", "relaunch":
      let launch = try Self.launchRequest(args)
      if action == "relaunch" {
        let app = try await applications.findApplication(identifier: Self.string(args, "app"))
        guard let identity = app.processIdentity else {
          throw SideportError("Application identity unavailable")
        }
        let result = try await applications.relaunchApplicationActionResult(
          request: .init(
            targetIdentifier: "PID:\(identity.processIdentifier)", expectedTargetIdentity: identity,
            launchRequest: launch, force: args["force"] as? Bool ?? false, waitSeconds: 2))
        return Self.actionResult(result.outcome, operation: action)
      }
      let result = try await applications.launchApplicationActionResult(request: launch)
      return Self.actionResult(result.outcome, operation: action)
    case "activate":
      let app = try await applications.findApplication(identifier: Self.string(args, "app"))
      let result = try await applications.activateApplicationActionResult(
        request: .init(application: app))
      return Self.actionResult(result.outcome, operation: action)
    case "quit":
      let app = try await applications.findApplication(identifier: Self.string(args, "app"))
      guard let identity = app.processIdentity else {
        throw SideportError("Application identity unavailable")
      }
      let result = try await applications.quitApplicationActionResult(
        request: .init(
          identifier: "PID:\(identity.processIdentifier)", force: args["force"] as? Bool ?? false,
          expectedIdentity: identity))
      return Self.actionResult(result.outcome, operation: action)
    case "hide":
      return Self.actionResult(
        try await applications.hideApplicationActionResult(identifier: Self.string(args, "app"))
          .outcome, operation: action)
    case "unhide":
      return Self.actionResult(
        try await applications.unhideApplicationActionResult(identifier: Self.string(args, "app"))
          .outcome, operation: action)
    default: throw SideportError("Unknown application action")
    }
  }
  nonisolated static func launchRequest(_ args: JSONObject) throws -> ApplicationLaunchRequest {
    var urls = args["urls"] as? [String] ?? []
    if let url = args["url"] as? String { urls.append(url) }
    guard urls.count <= 8 else { throw SideportError("Open at most eight URLs at a time") }
    let targets = try urls.map { raw -> URL in
      guard raw.utf8.count <= 4096,
        !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else { throw SideportError("Invalid application URL") }
      if raw.hasPrefix("/") || raw.hasPrefix("~/") {
        return URL(fileURLWithPath: try canonical(raw, existing: true))
      }
      guard let url = URL(string: raw),
        ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "")
      else { throw SideportError("Use an HTTP, HTTPS or local file URL") }
      return url
    }
    if let app = args["app"] as? String { _ = try Self.string(["app": app], "app", maximum: 4096) }
    guard args["app"] is String || !targets.isEmpty else {
      throw SideportError("Provide an app or URL")
    }
    return ApplicationLaunchRequest(
      applicationIdentifier: args["app"] as? String, openURLs: targets,
      activates: args["activate"] as? Bool ?? true, waitUntilReady: args["wait"] as? Bool ?? false,
      waitForWindow: args["wait_for_window"] as? Bool ?? false,
      createsNewInstance: args["new_instance"] as? Bool ?? false)
  }
  func transfer(_ path: String, data: Data? = nil) async throws -> Data {
    guard let runtime else {
      throw SideportError("File transfer is unavailable in this desktop session")
    }
    let context = runtime.context
    let path = try canonical(path, existing: data == nil)
    let grants = try context.grants()
    guard context.permitted(path, data == nil ? "read" : "read_write", grants) else {
      throw SideportError("Request folder access before transferring clipboard or screenshot files")
    }
    let output = try await runtime.launchProfile(
      runtime.profile(grants), context.executable,
      ["--file-operation", data == nil ? "read_binary" : "write_binary", path],
      cwd: runtime.scratch, timeout: 15, input: data, outputLimit: 24_000_000)
    guard output.code == 0, !output.stopped else {
      throw SideportError("File transfer refused by the sandbox")
    }
    if data != nil { return Data() }
    let response = try jsonObject(output.stdout, limit: 24_000_000)
    guard let content = response["content"] as? [JSONObject],
      let text = content.first?["text"] as? String,
      let encoded = try jsonObject(Data(text.utf8))["data_base64"] as? String,
      let bytes = Data(base64Encoded: encoded)
    else { throw SideportError("Invalid file transfer response") }
    return bytes
  }
  func clipboardAction(_ args: JSONObject) async throws -> JSONObject {
    let action = args["action"] as? String ?? "read"
    let slot = args["slot"] as? String ?? "0"
    guard GitHubPlan.matches(slot, #"^[A-Za-z0-9_-]{1,64}$"#) else {
      throw SideportError("Invalid clipboard slot")
    }
    switch action {
    case "status": return textResult(try encoded(clipboard.readAccessStatus()))
    case "read", "get":
      guard
        let value = try clipboard.get(
          prefer: (args["prefer"] as? String).flatMap(UTType.init), allowPrompt: false)
      else { return textResult(["empty": true]) }
      guard value.data.count <= 1_048_576 else {
        throw SideportError("Clipboard response exceeds 1 MiB")
      }
      if let path = args["outputPath"] as? String {
        guard path != "-" else {
          throw SideportError("Clipboard output must be a file, not MCP stdout")
        }
        _ = try await transfer(path, data: value.data)
        return textResult(["path": path, "uti": value.utiIdentifier, "bytes": value.data.count])
      }
      var response: JSONObject = ["uti": value.utiIdentifier, "bytes": value.data.count]
      if let text = String(data: value.data, encoding: .utf8) {
        response["text"] = text
      } else {
        response["data_base64"] = value.data.base64EncodedString()
      }
      return textResult(response)
    case "save":
      guard clipboardSlots.contains(slot) || clipboardSlots.count < 8 else {
        throw SideportError("At most eight clipboard slots per connection")
      }
      guard clipboard.readAccessStatus().readAdmitted else {
        throw SideportError("Allow clipboard reading in macOS before saving a slot")
      }
      var total = 0
      for item in pasteboard.pasteboardItems ?? [] {
        for type in item.types {
          total += item.data(forType: type)?.count ?? 0
          guard total <= 1_048_576 else { throw SideportError("Clipboard snapshot exceeds 1 MiB") }
        }
      }
      try clipboard.save(slot: clipboardNamespace + "-" + slot, allowPrompt: false)
      clipboardSlots.insert(slot)
      return textResult(["saved": slot, "bytes": total])
    case "restore":
      guard clipboardSlots.contains(slot) else {
        throw SideportError("No clipboard saved in this slot")
      }
      return Self.actionResult(
        try clipboard.restoreActionResult(slot: clipboardNamespace + "-" + slot).outcome,
        operation: "clipboard restore")
    case "clear":
      return Self.actionResult(
        try clipboard.clearActionResult().outcome, operation: "clipboard clear")
    case "set", "write":
      let data: Data
      let type: String
      if let path = args["file_path"] as? String {
        data = try await transfer(path)
        type =
          args["uti"] as? String ?? UTType(
            filenameExtension: URL(fileURLWithPath: path).pathExtension)?.identifier
          ?? UTType.data.identifier
      } else if let raw = args["data_base64"] as? String {
        guard raw.utf8.count <= 1_400_000, let decoded = Data(base64Encoded: raw),
          let uti = args["uti"] as? String, UTType(uti) != nil
        else { throw SideportError("Provide bounded base64 data and a valid UTI") }
        data = decoded
        type = args["uti"] as! String
      } else {
        guard let text = args["text"] as? String else {
          throw SideportError("Provide clipboard text, file_path, or data_base64 and uti")
        }
        data = Data(text.utf8)
        type = UTType.plainText.identifier
      }
      guard data.count <= 1_048_576, (args["alsoText"] as? String ?? "").utf8.count <= 32768 else {
        throw SideportError("Clipboard write exceeds its size limit")
      }
      let representations =
        type == UTType.plainText.identifier
        ? ClipboardWriteRequest.textRepresentations(from: data)
        : [.init(utiIdentifier: type, data: data)]
      let request = ClipboardWriteRequest(
        representations: representations, alsoText: args["alsoText"] as? String)
      return Self.actionResult(
        try clipboard.setActionResult(request).outcome, operation: "clipboard set")
    default: throw SideportError("Unknown clipboard action")
    }
  }
}
