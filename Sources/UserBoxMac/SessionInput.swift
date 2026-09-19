#if os(macOS)
import AppKit
import UserBoxCore

/// No HID tap, no event posting from the host process, no global-input fallback.
@MainActor final class SessionInput {
    let config: BoxConfig
    let pinned: UInt32
    private let source = CGEventSource(stateID: .privateState)
    private var keys = Set<UInt16>()
    private var buttons = Set<Int>()
    private var point = CGPoint.zero
    private var flags = CGEventFlags()
    init(config: BoxConfig, pinned: UInt32) { self.config = config; self.pinned = pinned }
    private func post(_ event: CGEvent?) throws {
        let identity = try MacIdentity.guardSession(config, pinned: pinned)
        guard identity.accessibility else { throw BoxError("Grant Accessibility to UserBox Session in the Box account") }
        guard let event else { throw BoxError("Could not allocate an input event") }
        event.post(tap: .cgSessionEventTap)
    }
    func send(_ input: InputEvent, bounds: CGRect) throws {
        try input.validate()
        switch input.kind {
        case "move", "down", "up":
            guard bounds.width > 0, bounds.height > 0 else { throw BoxError("Capture a frame before sending pointer input") }
            point = CGPoint(x: bounds.minX + input.x! * max(0, bounds.width - 1),
                            y: bounds.minY + input.y! * max(0, bounds.height - 1))
            let b = input.button ?? 0
            let button: CGMouseButton = b == 0 ? .left : b == 1 ? .right : .center
            let type: CGEventType
            if input.kind == "down" { type = b == 0 ? .leftMouseDown : b == 1 ? .rightMouseDown : .otherMouseDown }
            else if input.kind == "up" { type = b == 0 ? .leftMouseUp : b == 1 ? .rightMouseUp : .otherMouseUp }
            else if buttons.contains(0) { type = .leftMouseDragged }
            else if buttons.contains(1) { type = .rightMouseDragged }
            else if buttons.contains(2) { type = .otherMouseDragged }
            else { type = .mouseMoved }
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.flags = CGEventFlags(rawValue: input.flags ?? flags.rawValue)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(input.clicks ?? 1))
            try post(event)
            if input.kind == "down" { buttons.insert(b) }
            if input.kind == "up" { buttons.remove(b) }
        case "keyDown", "keyUp":
            let key = input.keyCode!, down = input.kind == "keyDown"
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = CGEventFlags(rawValue: input.flags ?? flags.rawValue)
            try post(event)
            if down { keys.insert(key) } else { keys.remove(key) }
        case "flags":
            flags = CGEventFlags(rawValue: input.flags ?? 0)
            let event = CGEvent(keyboardEventSource: source, virtualKey: input.keyCode ?? 56, keyDown: false)
            event?.type = .flagsChanged; event?.flags = flags; try post(event)
        case "text":
            // Each Character preserves surrogate pairs / composed Unicode sequences.
            for character in input.text! {
                let units = Array(String(character).utf16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    units.withUnsafeBufferPointer { p in
                        if let base = p.baseAddress { event?.keyboardSetUnicodeString(stringLength: p.count, unicodeString: base) }
                    }
                    event?.flags = []; try post(event)
                }
            }
        case "scroll":
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                wheel1: Int32(input.deltaY ?? 0), wheel2: Int32(input.deltaX ?? 0), wheel3: 0)
            event?.flags = flags; try post(event)
        case "release": try releaseAll()
        default: throw BoxError("Invalid input event")
        }
    }
    func releaseAll() throws {
        defer { keys.removeAll(); buttons.removeAll(); flags = [] }
        // If the user switched sessions, do not inject even cleanup events into a console desktop.
        _ = try MacIdentity.guardSession(config, pinned: pinned)
        for key in keys { try post(CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)) }
        for b in buttons {
            try post(CGEvent(mouseEventSource: source, mouseType: b == 0 ? .leftMouseUp : b == 1 ? .rightMouseUp : .otherMouseUp,
                             mouseCursorPosition: point, mouseButton: b == 0 ? .left : b == 1 ? .right : .center))
        }
        if !flags.isEmpty {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false)
            event?.type = .flagsChanged; event?.flags = []; try post(event)
        }
    }
}
#endif
