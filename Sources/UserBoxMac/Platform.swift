#if os(macOS)
import AppKit
import CoreGraphics
import UserBoxCore
import CUserBox

public enum MacIdentity {
    public static func current() throws -> SessionIdentity {
        var sid: UInt32 = 0, uid: UInt32 = 0
        var graphic: Int32 = 0, console: Int32 = 0, logged: Int32 = 0
        guard ub_session(&sid, &uid, &graphic, &console, &logged) == 0 else {
            throw BoxError("Unable to establish an Aqua security session identity")
        }
        return SessionIdentity(uid: ub_uid(), sessionUID: uid, sessionID: sid,
            consoleUID: ub_console_uid(), graphical: graphic != 0, onConsole: console != 0,
            loggedIn: logged != 0, screenRecording: CGPreflightScreenCaptureAccess(),
            accessibility: AXIsProcessTrusted())
    }
    public static func guardSession(_ config: BoxConfig, pinned: UInt32? = nil) throws -> SessionIdentity {
        let identity = try current(); try identity.validate(for: config, pinnedSession: pinned); return identity
    }
}
#else
public enum MacPlatformUnavailable {}
#endif
