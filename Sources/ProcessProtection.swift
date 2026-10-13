import Darwin
import Foundation
import LocalAuthentication
import Security

@_silgen_name("bootstrap_look_up")
private func lookupService(
  _ bootstrap: mach_port_t, _ name: UnsafePointer<CChar>, _ port: UnsafeMutablePointer<mach_port_t>
) -> kern_return_t

enum ProcessProtection {
  static func serviceProbe(_ name: String) -> JSONObject {
    var bootstrap: mach_port_t = 0
    guard
      task_get_special_port(mach_task_self_, Int32(TASK_BOOTSTRAP_PORT), &bootstrap) == KERN_SUCCESS
    else {
      return ["available": false]
    }
    defer { mach_port_deallocate(mach_task_self_, bootstrap) }
    var port: mach_port_t = 0
    let status = name.withCString { lookupService(bootstrap, $0, &port) }
    if port != 0 { mach_port_deallocate(mach_task_self_, port) }
    return ["available": status == KERN_SUCCESS, "status": Int(status)]
  }
  static func keychainProbe(_ service: String) -> JSONObject {
    let authentication = LAContext()
    authentication.interactionNotAllowed = true
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: authentication,
    ]
    var result: CFTypeRef?
    return ["status": Int(SecItemCopyMatching(query as CFDictionary, &result))]
  }
  static func credentialSafe(_ path: String) -> Bool {
    var code: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
      let code,
      SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        == errSecSuccess
    else { return false }
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        == errSecSuccess,
      let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? NSNumber
    else { return false }
    // CS_RESTRICT omits a protected process's environment from foreign
    // KERN_PROCARGS reads; CS_RUNTIME prevents ordinary debugger injection.
    return flags.uint32Value & 0x10800 == 0x10800
  }

  static func environmentProbe(_ pid: pid_t) -> JSONObject {
    var mib = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), pid]
    var size = 1_048_576
    var bytes = [UInt8](repeating: 0, count: size)
    let readable = sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0
    let synthetic =
      readable
      && String(decoding: bytes.prefix(size), as: UTF8.self)
        .contains("SYNTHETIC-PRIVATE-CREDENTIAL")
    return ["readable": readable, "synthetic_present": synthetic]
  }
}
