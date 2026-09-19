#if os(macOS)
import SwiftUI
import AppKit
import UserBoxCore

struct DesktopSurface: NSViewRepresentable {
    var image: NSImage?
    var controlling: Bool
    var send: (InputEvent) -> Void
    func makeNSView(context: Context) -> DesktopView { DesktopView() }
    func updateNSView(_ view: DesktopView, context: Context) {
        view.image = image; view.controlling = controlling; view.send = send; view.needsDisplay = true
    }
}
final class DesktopView: NSView, NSTextInputClient {
    var image: NSImage?
    var controlling = false
    var send: ((InputEvent) -> Void)?
    private var marked = NSAttributedString(string: "")
    private var rawKeys = Set<UInt16>()
    private var tracking: NSTrackingArea?
    private var lastMove: TimeInterval = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { controlling }
    var imageRect: NSRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if hasMarkedText() {
            marked.draw(at: NSPoint(x: 16, y: bounds.height - 38))
        }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area; super.updateTrackingAreas()
    }
    private func pointer(_ event: NSEvent, kind: String, button: Int = 0) {
        guard controlling, image != nil else { return }
        let rect = imageRect, position = convert(event.locationInWindow, from: nil)
        guard rect.width > 1, rect.height > 1 else { return }
        if kind == "down" && !rect.contains(position) { return }
        var input = InputEvent(kind: kind)
        input.x = min(1, max(0, (position.x - rect.minX) / rect.width))
        input.y = min(1, max(0, (position.y - rect.minY) / rect.height))
        input.button = button; input.clicks = max(1, min(3, event.clickCount))
        input.flags = UInt64(event.modifierFlags.rawValue); send?(input)
    }
    override func mouseDown(with event: NSEvent) { if controlling { window?.makeFirstResponder(self) }; pointer(event, kind: "down") }
    override func mouseUp(with event: NSEvent) { pointer(event, kind: "up") }
    override func mouseDragged(with event: NSEvent) { pointer(event, kind: "move") }
    override func rightMouseDown(with event: NSEvent) { pointer(event, kind: "down", button: 1) }
    override func rightMouseUp(with event: NSEvent) { pointer(event, kind: "up", button: 1) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event, kind: "move", button: 1) }
    override func otherMouseDown(with event: NSEvent) { pointer(event, kind: "down", button: 2) }
    override func otherMouseUp(with event: NSEvent) { pointer(event, kind: "up", button: 2) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event, kind: "move", button: 2) }
    override func mouseMoved(with event: NSEvent) {
        guard event.timestamp - lastMove > 1.0 / 60 else { return }; lastMove = event.timestamp; pointer(event, kind: "move")
    }
    override func scrollWheel(with event: NSEvent) {
        guard controlling else { return }
        var input = InputEvent(kind: "scroll")
        input.deltaX = Int(max(-1200, min(1200, event.scrollingDeltaX)))
        input.deltaY = Int(max(-1200, min(1200, event.scrollingDeltaY)))
        send?(input)
    }
    private func raw(_ event: NSEvent, down: Bool) {
        var input = InputEvent(kind: down ? "keyDown" : "keyUp")
        input.keyCode = event.keyCode; input.flags = UInt64(event.modifierFlags.rawValue); send?(input)
        if down { rawKeys.insert(event.keyCode) } else { rawKeys.remove(event.keyCode) }
    }
    override func keyDown(with event: NSEvent) {
        guard controlling else { return }
        let navigation: Set<UInt16> = [36, 48, 51, 53, 76, 115, 116, 117, 119, 121, 123, 124, 125, 126]
        if !event.modifierFlags.intersection([.command, .control]).isEmpty || (!hasMarkedText() && (navigation.contains(event.keyCode) || event.keyCode >= 96)) { raw(event, down: true) }
        else { interpretKeyEvents([event]) }
    }
    override func keyUp(with event: NSEvent) { if controlling && rawKeys.contains(event.keyCode) { raw(event, down: false) } }
    override func flagsChanged(with event: NSEvent) {
        guard controlling else { return }
        var input = InputEvent(kind: "flags"); input.keyCode = event.keyCode
        input.flags = UInt64(event.modifierFlags.rawValue); send?(input)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard controlling, window?.firstResponder === self, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        raw(event, down: true); return true
    }
    override func resignFirstResponder() -> Bool {
        if controlling { send?(InputEvent(kind: "release")) }
        rawKeys.removeAll(); return super.resignFirstResponder()
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard controlling else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        guard !text.isEmpty else { return }
        var input = InputEvent(kind: "text"); input.text = text; send?(input); unmarkText()
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        needsDisplay = true
    }
    func unmarkText() { marked = NSAttributedString(string: ""); needsDisplay = true }
    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = convert(NSRect(x: 16, y: bounds.height - 40, width: 2, height: 20), to: nil)
        return window?.convertToScreen(rect) ?? rect
    }
    override func doCommand(by selector: Selector) {
        let mapping: [String: UInt16] = ["insertNewline:": 36, "insertTab:": 48, "deleteBackward:": 51,
            "deleteForward:": 117, "cancelOperation:": 53, "moveLeft:": 123, "moveRight:": 124,
            "moveDown:": 125, "moveUp:": 126, "moveToBeginningOfDocument:": 115, "moveToEndOfDocument:": 119,
            "pageUp:": 116, "pageDown:": 121]
        guard controlling, let code = mapping[NSStringFromSelector(selector)] else { return }
        for kind in ["keyDown", "keyUp"] { var event = InputEvent(kind: kind); event.keyCode = code; send?(event) }
    }
}
#endif
