import Foundation
import UserBoxCore
#if os(macOS)
import AppKit
import Security
import CommonCrypto
import Darwin

final class DesktopView: NSView, NSTextInputClient {
    var frameImage: CGImage?
    var engine: Engine?
    var manual = false
    var mask = 0
    var marked = NSAttributedString(string:"")
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { manual }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let image = frameImage else { return }
        let scale = min(bounds.width/CGFloat(image.width),bounds.height/CGFloat(image.height))
        let rect = NSRect(x:(bounds.width-CGFloat(image.width)*scale)/2,y:(bounds.height-CGFloat(image.height)*scale)/2,width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale)
        NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height)).draw(in:rect,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseMoved,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil))
    }
    func location(_ event: NSEvent) -> (Int,Int)? {
        guard let i = frameImage else { return nil }; let p = convert(event.locationInWindow,from:nil)
        return Frame.point(x:p.x,y:p.y,viewW:bounds.width,viewH:bounds.height,frameW:i.width,frameH:i.height)
    }
    func pointer(_ e: NSEvent) {
        guard manual,let p = location(e) else { return }; engine?.enqueue(RPC("pointer",x:p.0,y:p.1,value:mask),viewer:true)
    }
    override func mouseDown(with e: NSEvent) { guard manual else{return}; window?.makeFirstResponder(self); mask |= 1; pointer(e) }
    override func mouseUp(with e: NSEvent) { mask &= ~1; pointer(e) }
    override func rightMouseDown(with e: NSEvent) { mask |= 4; pointer(e) }
    override func rightMouseUp(with e: NSEvent) { mask &= ~4; pointer(e) }
    override func otherMouseDown(with e: NSEvent) { mask |= 2; pointer(e) }
    override func otherMouseUp(with e: NSEvent) { mask &= ~2; pointer(e) }
    override func mouseMoved(with e: NSEvent) { pointer(e) }
    override func mouseDragged(with e: NSEvent) { pointer(e) }
    override func rightMouseDragged(with e: NSEvent) { pointer(e) }
    override func scrollWheel(with e: NSEvent) {
        guard manual,let p = location(e),e.scrollingDeltaY != 0 else{return}
        engine?.enqueue(RPC("scroll",x:p.0,y:p.1,value:e.scrollingDeltaY > 0 ? 1 : -1),viewer:true)
    }
    let special: [UInt16:UInt32] = [36:0xff0d,48:0xff09,51:0xff08,53:0xff1b,117:0xffff,123:0xff51,124:0xff53,125:0xff54,126:0xff52,115:0xff50,119:0xff57,116:0xff55,121:0xff56,
        122:0xffbe,120:0xffbf,99:0xffc0,118:0xffc1,96:0xffc2,97:0xffc3,98:0xffc4,100:0xffc5,101:0xffc6,109:0xffc7,103:0xffc8,111:0xffc9]
    func key(_ value: UInt32,down: Bool) { engine?.enqueue(RPC("key",value:Int(value),down:down),viewer:true) }
    override func keyDown(with e: NSEvent) {
        guard manual else{return}
        if let k = special[e.keyCode] { key(k,down:true); return }
        if !e.modifierFlags.intersection([.command,.control]).isEmpty,let s = e.charactersIgnoringModifiers?.unicodeScalars.first { key(s.value,down:true); return }
        interpretKeyEvents([e])
    }
    override func keyUp(with e: NSEvent) {
        if let k = special[e.keyCode] { key(k,down:false) }
        else if !e.modifierFlags.intersection([.command,.control]).isEmpty,let s = e.charactersIgnoringModifiers?.unicodeScalars.first { key(s.value,down:false) }
    }
    override func flagsChanged(with e: NSEvent) {
        let map: [UInt16:(UInt32,NSEvent.ModifierFlags)] = [56:(0xffe1,.shift),60:(0xffe2,.shift),59:(0xffe3,.control),62:(0xffe4,.control),58:(0xffe9,.option),61:(0xffea,.option),55:(0xffeb,.command),54:(0xffec,.command)]
        if manual,let (code,flag) = map[e.keyCode] { key(code,down:e.modifierFlags.contains(flag)) }
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool { if manual,e.type == .keyDown { keyDown(with:e); return true }; return false }
    override func resignFirstResponder() -> Bool { engine?.enqueue(RPC("release"),viewer:true); return super.resignFirstResponder() }
    func insertText(_ string: Any,replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        engine?.enqueue(RPC("type",text:text),viewer:true); unmarkText()
    }
    func setMarkedText(_ string: Any,selectedRange: NSRange,replacementRange: NSRange) { marked = (string as? NSAttributedString) ?? NSAttributedString(string:string as? String ?? "") }
    func unmarkText() { marked = NSAttributedString(string:"") }
    func selectedRange() -> NSRange { NSRange(location:0,length:0) }
    func markedRange() -> NSRange { marked.length == 0 ? NSRange(location:NSNotFound,length:0) : NSRange(location:0,length:marked.length) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange,actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange,actualRange: NSRangePointer?) -> NSRect { window?.convertToScreen(convert(NSRect(x:20,y:20,width:1,height:20),to:nil)) ?? .zero }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {}
}

#endif
