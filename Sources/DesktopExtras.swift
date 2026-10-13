import AppKit
import PeekabooAutomationKit
import PeekabooFoundation

extension NativeDesktop {
  func serialized<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
  }
  func extra(_ tool: String, _ args: JSONObject) async throws -> JSONObject? {
    if tool == "menu" {
      let menus = MenuService(
        applicationService: applications, feedbackClient: NoopAutomationFeedbackClient())
      switch args["action"] as? String ?? "list" {
      case "list":
        return textResult(try serialized(await menus.listMenus(for: Self.string(args, "app"))))
      case "extras": return textResult(try serialized(await menus.listMenuExtras()))
      case "click":
        let result = try await menus.clickMenuItemActionResult(
          app: Self.string(args, "app"), itemPath: Self.string(args, "path"))
        latest = nil
        return Self.actionResult(result.outcome, operation: "menu")
      case "click_extra":
        let result = try await menus.clickMenuExtraActionResult(title: Self.string(args, "title"))
        latest = nil
        return Self.actionResult(result.outcome, operation: "menu")
      default: throw SideportError("Unknown menu action")
      }
    }
    if tool == "dock" {
      let dock = DockService(feedbackClient: NoopAutomationFeedbackClient())
      var outcome: DesktopActionOutcome?
      switch args["action"] as? String ?? "list" {
      case "list": return textResult(try serialized(await dock.listDockItems(includeAll: true)))
      case "launch":
        outcome = try await dock.launchFromDockActionResult(appName: Self.string(args, "app"))
          .outcome
      case "menu", "right-click":
        outcome = try await dock.rightClickDockItemActionResult(
          appName: Self.string(args, "app"), menuItem: args["item"] as? String
        ).outcome
      case "hide": outcome = try await dock.hideDockActionResult().outcome
      case "show": outcome = try await dock.showDockActionResult().outcome
      case "add": try await dock.addToDock(path: Self.string(args, "path"), persistent: true)
      case "remove": try await dock.removeFromDock(appName: Self.string(args, "app"))
      default: throw SideportError("Unknown Dock action")
      }
      latest = nil
      return Self.actionResult(outcome, operation: "dock")
    }
    if tool == "dialog" {
      if ["file", "file-picker", "file_picker"].contains(args["action"] as? String ?? "") {
        let (observed, _) = try retained(args)
        defer { latest = nil }
        guard let identity = observed.target.detectionContext?.windowMutationIdentity,
          SystemIdentityResolver.validateWindowMutationIdentity(identity),
          let window = observed.target.window?.windowID
        else { throw SideportError("Observe the exact file dialog again") }
        let dialogs = DialogService(
          applicationService: applications, feedbackClient: NoopAutomationFeedbackClient())
        let result = try await dialogs.handleFileDialog(
          try DialogFileExecutionRequest(
            target: DialogTargetSelector(windowID: Int(window)), path: args["path"] as? String,
            filename: args["filename"] as? String, actionButton: args["button"] as? String,
            ensureExpanded: args["ensure_expanded"] as? Bool ?? false))
        return Self.actionResult(result.outcome, operation: "file dialog")
      }
      if args["action"] as? String == "click" { return try await call("click", args) }
      if ["type", "input"].contains(args["action"] as? String ?? "") {
        return try await call("type", args)
      }
      if args["action"] as? String == "dismiss" {
        var input = args
        input["keys"] = "escape"
        return try await call("press", input)
      }
      guard ["inspect", "info", "list"].contains(args["action"] as? String ?? "inspect") else {
        throw SideportError(
          "Unsupported dialog action; observe the dialog and use its element selectors")
      }
      let dialog = DialogService(
        applicationService: applications, feedbackClient: NoopAutomationFeedbackClient())
      return textResult(
        try serialized(
          await dialog.findActiveDialog(
            windowTitle: args["title"] as? String, appName: args["app"] as? String)))
    }
    if tool == "window" {
      let windows = WindowManagementService(
        applicationService: applications, feedbackClient: NoopAutomationFeedbackClient())
      let action = args["action"] as? String ?? "list"
      if action == "list" {
        let result = try await windows.listWindows(
          target: (args["app"] as? String).map { .application($0) } ?? .frontmost)
        return textResult(try serialized(result))
      }
      let (result, _) = try retained(args)
      defer { latest = nil }
      guard let identity = result.target.detectionContext?.windowMutationIdentity,
        let id = result.target.window?.windowID
      else { throw SideportError("Window actions require a recent exact window observation") }
      let target = WindowTarget.windowId(Int(id))
      var outcome: DesktopActionOutcome?
      switch action {
      case "close":
        outcome = try await windows.closeWindowActionResult(
          target: target, expectedIdentity: identity, allowForegroundFallback: false
        ).outcome
      case "minimize":
        outcome = try await windows.minimizeWindowActionResult(
          target: target, expectedIdentity: identity
        ).outcome
      case "restore":
        outcome = try await windows.restoreWindowActionResult(
          target: target, expectedIdentity: identity
        ).outcome
      case "maximize":
        outcome = try await windows.maximizeWindowActionResult(
          target: target, expectedIdentity: identity
        ).outcome
      case "focus":
        outcome = try await windows.focusWindowActionResult(
          target: target, expectedIdentity: identity
        ).outcome
      case "move":
        guard let x = args["x"] as? Double, let y = args["y"] as? Double, x.isFinite, y.isFinite
        else { throw SideportError("Provide finite window coordinates") }
        outcome = try await windows.moveWindowActionResult(
          target: target, expectedIdentity: identity, to: CGPoint(x: x, y: y)
        ).outcome
      case "resize":
        guard let width = args["width"] as? Double, let height = args["height"] as? Double,
          width > 0, height > 0, width <= 20000, height <= 20000
        else { throw SideportError("Provide bounded window dimensions") }
        outcome = try await windows.resizeWindowActionResult(
          target: target, expectedIdentity: identity, to: CGSize(width: width, height: height)
        ).outcome
      case "set-bounds", "set_bounds":
        guard let x = args["x"] as? Double, let y = args["y"] as? Double,
          let width = args["width"] as? Double, let height = args["height"] as? Double,
          x.isFinite, y.isFinite, width > 0, height > 0, width <= 20000, height <= 20000
        else { throw SideportError("Provide finite window bounds up to 20000 points") }
        outcome = try await windows.setWindowBoundsActionResult(
          target: target, expectedIdentity: identity,
          bounds: CGRect(x: x, y: y, width: width, height: height)
        ).outcome
      default: throw SideportError("Unknown window action")
      }
      latest = nil
      return Self.actionResult(outcome, operation: "window " + action)
    }
    if tool == "move" {
      let (result, _) = try retained(args)
      guard let identity = result.target.detectionContext?.windowMutationIdentity,
        SystemIdentityResolver.validateWindowMutationIdentity(identity)
      else { throw SideportError("Pointer target window changed; observe it again") }
      let element = try Self.select(
        Self.string(args, "target"), from: result.elements?.elements.all ?? [])
      let moved = try await automation.moveMouseWithOutcome(
        to: CGPoint(x: element.bounds.midX, y: element.bounds.midY), duration: 200, steps: 10,
        profile: .linear)
      latest = nil
      return Self.actionResult(moved.outcome, operation: "move pointer")
    }
    if tool == "space" {
      let spaces = SpaceManagementService(feedbackClient: NoopAutomationFeedbackClient())
      let action = args["action"] as? String ?? "list"
      if action == "list" {
        return textResult(
          spaces.getAllSpaces().map {
            ["id": $0.id, "type": $0.type.rawValue, "active": $0.isActive, "name": $0.name ?? ""]
              as JSONObject
          })
      }
      guard let id = args["id"] as? UInt64, spaces.getAllSpaces().contains(where: { $0.id == id })
      else { throw SideportError("Unknown Space; list current Spaces first") }
      if action == "switch" {
        try await spaces.switchToSpace(id)
      } else if action == "move_window" || action == "move-window" {
        let (result, _) = try retained(args)
        guard let window = result.target.window?.windowID,
          let identity = result.target.detectionContext?.windowMutationIdentity,
          SystemIdentityResolver.validateWindowMutationIdentity(identity)
        else {
          throw SideportError("Observe the window first")
        }
        try spaces.moveWindowToSpace(windowID: UInt32(window), spaceID: id)
      } else {
        throw SideportError("Unknown Space action")
      }
      latest = nil
      return Self.actionResult(nil, operation: "space " + action)
    }
    return nil
  }
}
