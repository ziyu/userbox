#if os(macOS)
import AppKit
import UserBoxCore
import UserBoxMac

@MainActor final class SessionDelegate: NSObject, NSApplicationDelegate {
    var service: SessionService?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: "--box"), args.indices.contains(index + 1) else {
                throw BoxError("Usage: UserBoxSession --box NAME")
            }
            let config = try BoxConfig.load(args[index + 1])
            service = try SessionService(config: config); try service?.start()
        } catch {
            // Configuration errors only; no desktop contents, credentials, or keystrokes.
            fputs("UserBox Session: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }
}
let app = NSApplication.shared
let delegate = SessionDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
#else
print("UserBoxSession requires macOS 13 or later")
#endif
