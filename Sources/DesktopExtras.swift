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
        try await menus.clickMenuItem(
          app: Self.string(args, "app"), itemPath: Self.string(args, "path"))
        latest = nil
        return textResult(["completed": true])
      case "click_extra":
        try await menus.clickMenuExtra(title: Self.string(args, "title"))
        latest = nil
        return textResult(["completed": true])
      default: throw SideportError("Unknown menu action")
      }
    }
    if tool == "dock" {
      let dock = DockService(feedbackClient: NoopAutomationFeedbackClient())
      switch args["action"] as? String ?? "list" {
      case "list": return textResult(try serialized(await dock.listDockItems(includeAll: true)))
      case "launch": try await dock.launchFromDock(appName: Self.string(args, "app"))
      case "menu", "right-click":
        try await dock.rightClickDockItem(
          appName: Self.string(args, "app"), menuItem: args["item"] as? String)
      case "hide": try await dock.hideDock()
      case "show": try await dock.showDock()
      case "add": try await dock.addToDock(path: Self.string(args, "path"), persistent: true)
      case "remove": try await dock.removeFromDock(appName: Self.string(args, "app"))
      default: throw SideportError("Unknown Dock action")
      }
      latest = nil
      return textResult(["completed": true])
    }
    if tool == "dialog" {
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
      switch action {
      case "close":
        try await windows.closeWindow(
          target: target, expectedIdentity: identity, allowForegroundFallback: false)
      case "minimize": try await windows.minimizeWindow(target: target, expectedIdentity: identity)
      case "restore": try await windows.restoreWindow(target: target, expectedIdentity: identity)
      case "maximize": try await windows.maximizeWindow(target: target, expectedIdentity: identity)
      case "focus":
        _ = try await windows.focusWindowActionResult(target: target, expectedIdentity: identity)
      case "move":
        guard let x = args["x"] as? Double, let y = args["y"] as? Double, x.isFinite, y.isFinite
        else { throw SideportError("Provide finite window coordinates") }
        try await windows.moveWindow(
          target: target, expectedIdentity: identity, to: CGPoint(x: x, y: y))
      case "resize":
        guard let width = args["width"] as? Double, let height = args["height"] as? Double,
          width > 0, height > 0, width <= 20000, height <= 20000
        else { throw SideportError("Provide bounded window dimensions") }
        try await windows.resizeWindow(
          target: target, expectedIdentity: identity, to: CGSize(width: width, height: height))
      case "set-bounds", "set_bounds":
        guard let x = args["x"] as? Double, let y = args["y"] as? Double,
          let width = args["width"] as? Double, let height = args["height"] as? Double,
          x.isFinite, y.isFinite, width > 0, height > 0, width <= 20000, height <= 20000
        else { throw SideportError("Provide finite window bounds up to 20000 points") }
        try await windows.setWindowBounds(
          target: target, expectedIdentity: identity,
          bounds: CGRect(x: x, y: y, width: width, height: height))
      default: throw SideportError("Unknown window action")
      }
      latest = nil
      return textResult(["completed": true])
    }
    if tool == "move" {
      let (result, _) = try retained(args)
      guard let identity = result.target.detectionContext?.windowMutationIdentity,
        SystemIdentityResolver.validateWindowMutationIdentity(identity)
      else { throw SideportError("Pointer target window changed; observe it again") }
      let element = try Self.select(
        Self.string(args, "target"), from: result.elements?.elements.all ?? [])
      try await automation.moveMouse(
        to: CGPoint(x: element.bounds.midX, y: element.bounds.midY), duration: 200, steps: 10,
        profile: .linear)
      latest = nil
      return textResult(["completed": true])
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
      return textResult(["completed": true])
    }
    return nil
  }
}
