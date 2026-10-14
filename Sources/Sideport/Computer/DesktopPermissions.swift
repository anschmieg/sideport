import Foundation

extension NativeDesktop {
  func permissionStatus() async -> JSONObject {
    [
      // A ScreenCaptureKit "live check" can itself ask for direct screen access.
      // Permission polling must remain a cheap, non-interactive preflight.
      "screen_recording": permissions.checkScreenRecordingPermission(),
      "accessibility": permissions.checkAccessibilityPermission(),
      "event_synthesis": permissions.checkPostEventPermission(),
    ]
  }

  /// Only call after the user has approved computer control. A permission request
  /// must leave time for the native alert or Settings interaction to complete.
  func requestPermissions() async throws -> JSONObject {
    let before = await permissionStatus()
    guard !requestedNativePermissions else { return before }
    requestedNativePermissions = true
    var requested = false
    if before["accessibility"] as? Bool != true {
      permissions.requestAccessibilityPermission()
      requested = true
    }
    if before["screen_recording"] as? Bool != true {
      permissions.requestScreenRecordingPermission()
      requested = true
    }
    if before["event_synthesis"] as? Bool != true {
      permissions.requestPostEventPermission()
      requested = true
    }
    guard requested else { return before }
    // Avoid checking immediately and reporting failure while the user is still
    // approving the request. Cached event permissions may require a relaunch.
    try await Task.sleep(nanoseconds: 3_000_000_000)
    let deadline = Date().addingTimeInterval(20)
    var current = await permissionStatus()
    while current.values.contains(where: { $0 as? Bool != true }), Date() < deadline {
      try await Task.sleep(nanoseconds: 500_000_000)
      current = await permissionStatus()
    }
    return current
  }
}
