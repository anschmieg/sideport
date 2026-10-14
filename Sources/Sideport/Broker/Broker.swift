import Darwin
import Foundation

actor NativeBroker {
  let context: NativeContext
  let supervisor = ChildSupervisor()
  let runtime: RuntimeSupport
  let approvals: LocalApprovals
  let safety: CommandSafety
  let github: NativeGitHub
  let providers: NativeProviders
  var desktop: NativeDesktop?
  var computerAllowed = false
  let tools: [JSONObject]
  init(_ context: NativeContext) throws {
    self.context = context
    runtime = try RuntimeSupport(context, supervisor)
    approvals = LocalApprovals(context)
    safety = try CommandSafety(context, supervisor, approvals)
    github = NativeGitHub(runtime, approvals)
    providers = NativeProviders(runtime, approvals)
    guard
      let tools = try JSONSerialization.jsonObject(
        with: Data(contentsOf: NativeResources.directory.appendingPathComponent("Tools.json")))
        as? [JSONObject]
    else { throw SideportError("Bundled tool manifest is missing") }
    self.tools = tools
  }
  func call(_ name: String, _ args: JSONObject) async throws -> JSONObject {
    guard tools.contains(where: { $0["name"] as? String == name }) else {
      throw SideportError("Unknown tool")
    }
    switch name {
    case "allowed_locations": return textResult(try context.grants().map(\.dictionary))
    case "request_access":
      return try await approvals.access(
        canonical(NativeDesktop.string(args, "path"), existing: true),
        NativeDesktop.string(args, "access"), NativeDesktop.string(args, "reason", maximum: 500))
    case "read_file", "write_file", "list_directory":
      let path = try canonical(NativeDesktop.string(args, "path"), existing: name != "write_file")
      let grants = try context.grants()
      let access = name == "write_file" ? "read_write" : "read"
      guard context.permitted(path, access, grants) else {
        return textResult(
          [
            "status": "access_denied", "path": path, "access": access,
            "hint": "Decide whether to request_access for the required location",
          ], error: true)
      }
      let content = args["content"] as? String ?? ""
      guard name != "write_file" || (args["content"] is String && content.utf8.count <= 524288)
      else { throw SideportError("Provide UTF-8 content up to 512 KiB") }
      let output = try await runtime.launchProfile(
        runtime.profile(grants), context.executable, ["--file-operation", name, path],
        cwd: runtime.scratch, timeout: 10, input: Data(content.utf8), outputLimit: 8_388_608)
      guard output.code == 0, !output.stopped else {
        throw SideportError("File operation refused by the operating-system sandbox")
      }
      return try jsonObject(output.stdout, limit: 8_388_608)
    case "run_shell", "run_github":
      let cwd = try canonical(NativeDesktop.string(args, "cwd"), existing: true)
      let grants = try context.grants()
      guard context.permitted(cwd, "read", grants) else {
        return textResult(
          [
            "status": "access_denied", "path": cwd,
            "hint": "Request access to the working folder if appropriate",
          ], error: true)
      }
      if name == "run_github" { return try await github.call(args, cwd: cwd, grants: grants) }
      let command = try NativeDesktop.string(args, "command", maximum: 65536)
      if let words = try GitHubPlan.simple(command) {
        var forwarded = args
        forwarded["args"] = words
        return try await github.call(forwarded, cwd: cwd, grants: grants)
      }
      let verdict = try await safety.assess(
        command, cwd: cwd, reason: args["approval_reason"] as? String,
        task: args["task_context"] as? String, scope: grants)
      guard verdict["allowed"] as? Bool == true else { return textResult(verdict, error: true) }
      let timeout = args["timeout_seconds"] as? Double ?? 30
      guard (1...300).contains(timeout) else { throw SideportError("Invalid command timeout") }
      let output = try await runtime.execute(
        "/bin/bash", ["--noprofile", "--norc", "-c", command], cwd: cwd, approved: grants,
        network: true, timeout: timeout
      )
      await safety.record([
        "tool": "run_shell", "command": String(command.prefix(500)), "cwd": cwd,
        "exit_code": output.code, "at": ISO8601DateFormatter().string(from: Date()),
      ])
      return output.result
    case "request_computer_control":
      if !computerAllowed {
        guard
          try await approvals.capability(
            "computer_control", ["tool": "Peekaboo", "version": "4.9.1"],
            NativeDesktop.string(args, "reason", maximum: 500))
        else { return textResult(["status": "denied"]) }
        desktop = await MainActor.run { NativeDesktop(runtime: runtime) }
        computerAllowed = true
      }
      guard let desktop else { throw SideportError("Computer-control service unavailable") }
      let permissions = try await desktop.requestPermissions()
      guard permissions.values.allSatisfy({ $0 as? Bool == true }) else {
        return textResult([
          "status": "permissions_required", "permissions": permissions,
          "guidance":
            "Finish approving Sideport in macOS Privacy & Security, then retry. If permissions are already enabled, disconnect and reconnect Sideport to refresh macOS's cached authorization.",
        ])
      }
      return textResult([
        "status": "approved", "tools": Self.computerTools,
        "guidance":
          "Use screen control for graphical tasks. Use run_shell for commands; never bypass a sandbox refusal with Terminal.",
      ])
    case "computer_action":
      guard computerAllowed, let desktop, let arguments = args["arguments"] as? JSONObject else {
        return textResult(
          ["status": "access_denied", "hint": "Request computer control if appropriate"],
          error: true)
      }
      return try await desktop.call(NativeDesktop.string(args, "tool"), arguments)
    default: return try await providers.call(name, args)
    }
  }
  func message(_ object: JSONObject) async -> JSONObject? {
    let id = object["id"]
    guard let method = object["method"] as? String else {
      return id.map {
        ["jsonrpc": "2.0", "id": $0, "error": ["code": -32600, "message": "Invalid request"]]
      }
    }
    guard id != nil else { return nil }
    let params = object["params"] as? JSONObject ?? [:]
    do {
      let result: JSONObject
      switch method {
      case "server/discover":
        result = [
          "supportedVersions": ["2026-07-28", "2025-11-25"],
          "serverInfo": ["name": "Sideport", "version": "0.3.3"], "capabilities": ["tools": [:]],
        ]
      case "initialize":
        let requested = params["protocolVersion"] as? String ?? ""
        result = [
          "protocolVersion": ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            .contains(requested) ? requested : "2025-11-25",
          "serverInfo": ["name": "Sideport", "version": "0.3.3"], "capabilities": ["tools": [:]],
        ]
      case "ping": result = [:]
      case "tools/list": result = ["tools": tools]
      case "tools/call":
        do {
          result = try await call(
            NativeDesktop.string(params, "name"), params["arguments"] as? JSONObject ?? [:])
        } catch {
          result = textResult(["error": secretRedacted(error.localizedDescription)], error: true)
        }
      default: throw RPCFailure(code: -32601, message: "Method not found")
      }
      return ["jsonrpc": "2.0", "id": id!, "result": result]
    } catch {
      return [
        "jsonrpc": "2.0", "id": id!,
        "error": [
          "code": (error as? RPCFailure)?.code ?? -32602,
          "message": secretRedacted(error.localizedDescription),
        ],
      ]
    }
  }
  func close() async {
    try? FileManager.default.removeItem(atPath: context.session + "/desktop-activity.json")
    await providers.close()
    supervisor.shutdown()
    runtime.close()
    computerAllowed = false
    await desktop?.close()
    desktop = nil
  }
  nonisolated static var computerTools: [JSONObject] {
    let string: JSONObject = ["type": "string"]
    func schema(
      _ name: String, _ description: String, _ properties: JSONObject, _ required: [String] = []
    ) -> JSONObject {
      [
        "name": name, "description": description,
        "inputSchema": [
          "type": "object", "properties": properties, "required": required,
          "additionalProperties": false,
        ],
      ]
    }
    let capture: JSONObject = [
      "app": string, "window_id": ["type": "integer"], "window_title": string,
      "target": ["type": "string", "enum": ["window", "screen", "all_screens", "menubar"]],
      "display_index": ["type": "integer", "minimum": 0],
      "path": string, "format": ["type": "string", "enum": ["png", "jpg", "data"]],
      "scale": ["type": "string", "enum": ["logical", "1x", "native", "retina", "2x"]],
      "retina": ["type": "boolean"],
      "max_dimension": ["type": "integer", "minimum": 320, "maximum": 4096],
      "region": [
        "type": "object",
        "properties": [
          "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"],
          "height": ["type": "number"],
        ], "required": ["x", "y", "width", "height"], "additionalProperties": false,
      ],
    ]
    let snapshot: JSONObject = ["snapshot_id": string, "target": string]
    return [
      schema(
        "window", "List or manage app windows; mutations require a fresh snapshot_id",
        [
          "action": string, "app": string, "snapshot_id": string, "x": ["type": "number"],
          "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"],
        ]),
      schema(
        "menu", "List or select application menus and menu extras",
        ["action": string, "app": string, "path": string, "title": string]),
      schema(
        "dock", "List or interact with Dock items",
        ["action": string, "app": string, "item": string, "path": string]),
      schema(
        "dialog", "Inspect a dialog or act on one of its fresh element selectors",
        [
          "action": string, "title": string, "app": string, "snapshot_id": string, "target": string,
          "text": string, "path": string, "filename": string, "button": string,
          "ensure_expanded": ["type": "boolean"],
        ]),
      schema(
        "move", "Move the pointer to a fresh selected element", snapshot, ["snapshot_id", "target"]),
      schema(
        "space", "List, switch or move a window to a Space",
        ["action": string, "id": ["type": "integer"], "snapshot_id": string]),
      schema(
        "image", "Capture an image of a screen or window inline",
        capture),
      schema("permissions", "Check macOS automation permissions", [:]),
      schema(
        "see", "Observe an app window; returns pixels, elements and a fresh snapshot_id",
        capture),
      schema(
        "inspect_ui", "Observe the target window’s accessibility tree and screenshot",
        capture),
      schema(
        "capture", "Capture the current window",
        capture),
      schema(
        "verify_state", "Read the current screen after an action",
        capture),
      schema(
        "click", "Click one element from the latest snapshot",
        snapshot.merging(["click_type": ["type": "string", "enum": ["single", "double", "right"]]])
        { _, new in new }, ["snapshot_id", "target"]),
      schema(
        "type", "Type into a selected element",
        snapshot.merging([
          "text": string, "clear": ["type": "boolean"],
          "delay_ms": ["type": "integer", "minimum": 0, "maximum": 1000],
        ]) { _, new in new },
        ["snapshot_id", "target", "text"]),
      schema(
        "set_value", "Set an accessibility control value",
        snapshot.merging(["value": string]) { _, new in new }, ["snapshot_id", "target", "value"]),
      schema(
        "select_text", "Select text inside an element",
        snapshot.merging(["text": string, "prefix": string, "suffix": string]) { _, new in new },
        ["snapshot_id", "target", "text"]),
      schema(
        "drag",
        "Drag between two unique element selectors in the same fresh window; coordinates forbidden. Foreground delivery supports native Mac drag-and-drop and focuses the target window; background is available for controls that support it. Inspect the result before retrying.",
        [
          "snapshot_id": string, "from": string, "to": string,
          "duration_ms": ["type": "integer", "minimum": 1, "maximum": 10000],
          "delivery": [
            "type": "string", "enum": ["foreground", "background"], "default": "foreground",
          ],
        ], ["snapshot_id", "from", "to"]),
      schema(
        "press", "Press a key combination in the observed window",
        ["snapshot_id": string, "keys": string], ["snapshot_id", "keys"]),
      schema(
        "paste", "Paste the clipboard into the observed window", ["snapshot_id": string],
        ["snapshot_id"]),
      schema(
        "scroll", "Scroll a selected element",
        snapshot.merging([
          "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
          "amount": ["type": "integer", "minimum": 1, "maximum": 100],
          "smooth": ["type": "boolean"],
          "delay_ms": ["type": "integer", "minimum": 0, "maximum": 1000],
        ]) { _, new in new }, ["snapshot_id", "target"]),
      schema(
        "clipboard", "Read or write the system clipboard",
        [
          "action": [
            "type": "string",
            "enum": ["read", "write", "get", "set", "clear", "status", "save", "restore"],
          ], "text": string, "prefer": string, "outputPath": string, "slot": string,
          "file_path": string, "data_base64": string, "uti": string, "alsoText": string,
        ]),
      schema(
        "app", "List, launch, activate or quit apps; list their windows",
        [
          "action": [
            "type": "string",
            "enum": [
              "list", "windows", "launch", "open", "relaunch", "activate", "quit", "hide", "unhide",
            ],
          ],
          "app": string, "url": string, "urls": ["type": "array", "items": string, "maxItems": 8],
          "activate": ["type": "boolean"], "wait": ["type": "boolean"],
          "wait_for_window": ["type": "boolean"], "new_instance": ["type": "boolean"],
          "force": ["type": "boolean"],
        ]),
      schema(
        "sleep", "Wait briefly for an application",
        ["seconds": ["type": "number", "minimum": 0, "maximum": 10]]),
    ]
  }
}
enum NativeFileOperation {
  static func run(_ name: String, _ path: String) throws -> JSONObject {
    switch name {
    case "read_binary":
      let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw SideportError("Cannot open binary file") }
      defer { Darwin.close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 1_048_576
      else { throw SideportError("Binary read requires a regular file up to 1 MiB") }
      let bytes =
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 1_048_577)
        ?? Data()
      guard bytes.count <= 1_048_576 else {
        throw SideportError("Binary read grew beyond its size limit")
      }
      return textResult(["data_base64": bytes.base64EncodedString(), "bytes": bytes.count])
    case "write_binary":
      var bytes = Data()
      while let chunk = try FileHandle.standardInput.read(upToCount: 16384), !chunk.isEmpty {
        guard bytes.count + chunk.count <= 16_777_216 else {
          throw SideportError("Binary write exceeds 16 MiB")
        }
        bytes.append(chunk)
      }
      let fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw SideportError("Cannot open binary destination") }
      defer { Darwin.close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
        ftruncate(fd, 0) == 0
      else { throw SideportError("Binary destination must be a regular file with no hard links") }
      try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: bytes)
      return textResult(["path": path, "written_bytes": bytes.count])
    case "read_file":
      let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw SideportError("Cannot open file") }
      defer { Darwin.close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG
      else { throw SideportError("Read requires a regular file") }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
      var data = try handle.read(upToCount: 1_048_576) ?? Data()
      let truncated = info.st_size > data.count
      if truncated {
        for _ in 0..<3 where String(data: data, encoding: .utf8) == nil { data.removeLast() }
      }
      guard let value = String(data: data, encoding: .utf8) else {
        throw SideportError("File must be UTF-8")
      }
      return textResult([
        "path": path, "content": value, "truncated": truncated, "read_bytes": data.count,
      ])
    case "list_directory":
      let entries = try FileManager.default.contentsOfDirectory(atPath: path)
      guard entries.count <= 10000 else { throw SideportError("Directory listing too large") }
      let listing = entries.sorted().map { entry -> JSONObject in
        let type =
          (try? FileManager.default.attributesOfItem(atPath: path + "/" + entry))?[.type]
          as? FileAttributeType
        return ["name": entry, "directory": type == .typeDirectory]
      }
      return textResult(["path": path, "entries": listing])
    case "write_file":
      var bytes = Data()
      while let chunk = try FileHandle.standardInput.read(upToCount: 16384), !chunk.isEmpty {
        guard bytes.count + chunk.count <= 524288 else { throw SideportError("Write is too large") }
        bytes.append(chunk)
      }
      guard let content = String(data: bytes, encoding: .utf8), content.utf8.count <= 524288 else {
        throw SideportError("Write is too large")
      }
      let fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw SideportError("Cannot open destination") }
      defer { Darwin.close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
        ftruncate(fd, 0) == 0
      else {
        throw SideportError("Destination must be a regular file with no hard links")
      }
      try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(
        contentsOf: Data(content.utf8))
      return textResult(["path": path, "written_bytes": content.utf8.count])
    default: throw SideportError("Unknown file operation")
    }
  }
}
