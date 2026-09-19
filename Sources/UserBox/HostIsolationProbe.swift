#if os(macOS)
import AppKit

/// Samples only focus and pointer metadata on the main actor, never host keystrokes.
@MainActor final class HostIsolationProbe {
    private let initialApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
    private let initialCursor = NSEvent.mouseLocation
    private let window = NSApp.mainWindow
    private let initialFocus = NSApp.mainWindow?.firstResponder
    private(set) var appChanged = false
    private(set) var pointerChanged = false
    private(set) var focusChanged = false
    func sample() {
        appChanged = appChanged || NSWorkspace.shared.frontmostApplication?.processIdentifier != initialApp
        pointerChanged = pointerChanged || NSEvent.mouseLocation != initialCursor
        focusChanged = focusChanged || window?.firstResponder !== initialFocus
    }
}
#endif
