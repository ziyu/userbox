import Foundation
import UserBoxCore
#if os(macOS)
import AppKit
import Security
import CommonCrypto
import Darwin

// Runs as a LaunchAgent IN the Box user's Aqua login session, never via sudo -u
// or launchctl asuser as a substitute for an actual graphical login.
final class WitnessDelegate: NSObject, NSApplicationDelegate {
    let config: BoxConfig
    let instance = UUID().uuidString
    var panels: [NSPanel] = []
    var listener: SocketStream?
    init(_ config: BoxConfig) { self.config = config }
    func snapshot(nonce: String) throws -> Witness {
        guard let d = CGSessionCopyCurrentDictionary() as? [String:Any],
              let sessionUID = d["kCGSessionUserIDKey"] as? NSNumber,
              let console = d["kCGSessionOnConsoleKey"] as? NSNumber,
              let loggedIn = d["kCGSessionLoginDoneKey"] as? NSNumber,
              let screen = NSScreen.screens.first else { throw UBError("No valid graphical login session") }
        var st = stat(); guard stat("/dev/console",&st) == 0 else { throw UBError("Cannot identify host console") }
        let w = Witness(uid:getuid(),consoleUID:st.st_uid,sessionUID:sessionUID.uint32Value,onConsole:console.boolValue,
                        loginDone:loggedIn.boolValue,instance:instance,width:Int(screen.frame.width),height:Int(screen.frame.height),nonce:nonce)
        try w.validate(config,nonce:nonce); return w
    }
    func displayMarker(nonce: String) throws {
        guard nonce.count == 64,nonce.allSatisfy({$0.isHexDigit}),let screen = NSScreen.screens.first else { throw UBError("Invalid challenge") }
        if panels.isEmpty {
            for _ in 0..<2 {
                let p = NSPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
                p.level = .screenSaver; p.isOpaque = true; p.hasShadow = false; p.ignoresMouseEvents = true
                p.collectionBehavior = [.canJoinAllSpaces,.stationary,.fullScreenAuxiliary]; p.isReleasedWhenClosed = false
                panels.append(p)
            }
        }
        for i in 0..<2 {
            let x = i == 0 ? screen.frame.minX+18 : screen.frame.maxX-18-48
            let y = i == 0 ? screen.frame.maxY-18-48 : screen.frame.minY+18
            panels[i].setFrame(NSRect(x:x,y:y,width:48,height:48),display:true)
            let v = MarkerView(frame:NSRect(x:0,y:0,width:48,height:48)); v.colors = Marker.colors(nonce,corner:i)
            panels[i].contentView = v; panels[i].orderFrontRegardless(); v.display(); panels[i].displayIfNeeded()
        }
    }
    func handle(_ req: RPC,done: @escaping (Reply)->Void) {
        do {
            let nonce = req.command == "probe" ? req.text ?? "" : String(repeating:"0",count:64)
            let w = try snapshot(nonce:nonce)
            switch req.command {
            case "probe": try displayMarker(nonce:nonce); done(Reply(witness:w))
            case "launch":
                guard let name = req.text,name.count < 1024 else { throw UBError("Missing application") }
                let url: URL?
                if name.hasPrefix("/") {
                    let canonical = URL(fileURLWithPath:name).resolvingSymlinksInPath()
                    let roots = ["/Applications/","/System/Applications/","/System/Library/CoreServices/",NSHomeDirectory()+"/Applications/"]
                    guard canonical.pathExtension == "app",roots.contains(where:{canonical.path.hasPrefix($0)}) else { throw UBError("Application is outside installed application directories") }; url = canonical
                } else { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:name) }
                guard let url else { throw UBError("Application is not registered for the Box user") }
                let options = NSWorkspace.OpenConfiguration(); options.activates = true; options.addsToRecentItems = false
                NSWorkspace.shared.openApplication(at:url,configuration:options) { app,error in
                    done(Reply(ok:app != nil,message:error?.localizedDescription ?? "Application launched; pid=\(app?.processIdentifier ?? 0). Verify the resulting frame."))
                }
            case "open":
                guard let path = req.text,path.hasPrefix("/") else { throw UBError("An absolute file path is required") }
                let url = URL(fileURLWithPath:path).resolvingSymlinksInPath(); let p = url.path
                let roots = [NSHomeDirectory(),"/Users/Shared/UserBox/\(config.username)","/Applications","/System/Applications"]
                guard roots.contains(where:{p == $0 || p.hasPrefix($0+"/")}) else { throw UBError("File is outside the Box home and explicit shared directory") }
                guard FileManager.default.fileExists(atPath:p),NSWorkspace.shared.open(url) else { throw UBError("File open failed") }
                done(Reply(message:"Open request accepted in the Box session; verify the frame."))
            default: throw UBError("Unknown witness command")
            }
        } catch { panels.forEach{$0.orderOut(nil)}; done(Reply(ok:false,message:error.localizedDescription)) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            // Socket directory is created by setup, private to the host/Box group.
            listener = try SocketStream.listen(path:config.socketPath)
            guard chown(config.socketPath,config.boxUID,config.groupID) == 0 else { throw UBError("Cannot assign witness socket group") }
            let server = listener!
            DispatchQueue.global(qos:.userInitiated).async { [self] in
                while true {
                    do {
                        let client = try server.acceptClient(); try client.requirePeer(uid:config.hostUID)
                        let req = try client.receive(RPC.self)
                        let done = DispatchSemaphore(value:0)
                        DispatchQueue.main.async { self.handle(req) { reply in try? client.send(reply); done.signal() } }
                        _ = done.wait(timeout:.now()+10)
                    } catch { Thread.sleep(forTimeInterval:0.05) }
                }
            }
        } catch { fputs("UserBox witness: \(error.localizedDescription)\n",stderr); NSApp.terminate(nil) }
    }
}
final class MarkerView: NSView {
    var colors: [(UInt8,UInt8,UInt8)] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        for (i,c) in colors.enumerated() {
            NSColor(deviceRed:CGFloat(c.0)/255,green:CGFloat(c.1)/255,blue:CGFloat(c.2)/255,alpha:1).setFill()
            NSRect(x:CGFloat((i%8)*6),y:CGFloat((i/8)*6),width:6,height:6).fill()
        }
    }
}

#endif
