import Darwin
import Foundation

// A kernel-held lock serializes connection startup and dependency replacement
// across app instances. It is released by the OS even when its owner crashes.
final class ControllerLease {
  private var descriptor: Int32 = -1
  init(_ root: String) throws {
    let candidate = open(
      root + "/work/controller-operation.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard candidate >= 0 else { throw SideportError("Cannot lock Sideport’s controller") }
    var record = flock()
    record.l_type = Int16(F_WRLCK)
    record.l_whence = Int16(SEEK_SET)
    guard fcntl(candidate, F_SETLK, &record) == 0 else {
      Darwin.close(candidate)
      throw SideportError("Another Sideport connection or update is using this controller")
    }
    descriptor = candidate
  }
  deinit { Darwin.close(descriptor) }
}
