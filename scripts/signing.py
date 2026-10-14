"""Unlock the dedicated signing keychain without placing its password in argv."""
import ctypes


def unlock(identity):
    security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
    core = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    security.SecKeychainOpen.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    security.SecKeychainOpen.restype = ctypes.c_int32
    security.SecKeychainUnlock.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_bool]
    security.SecKeychainUnlock.restype = ctypes.c_int32
    security.SecKeychainSetUserInteractionAllowed.argtypes = [ctypes.c_bool]
    core.CFRelease.argtypes = [ctypes.c_void_p]
    reference = ctypes.c_void_p()
    security.SecKeychainSetUserInteractionAllowed(False)
    status = security.SecKeychainOpen(identity['keychain'].encode(), ctypes.byref(reference))
    if status:
        raise RuntimeError(f'Cannot open the dedicated signing keychain (status {status})')
    secret = ctypes.create_string_buffer(identity['password'].encode())
    try:
        status = security.SecKeychainUnlock(reference, len(secret.value), secret, True)
        if status:
            raise RuntimeError(f'Cannot unlock the dedicated signing keychain (status {status})')
    finally:
        ctypes.memset(secret, 0, ctypes.sizeof(secret))
        core.CFRelease(reference)
