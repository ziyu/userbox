import Foundation
import UserBoxCore
#if os(macOS)
import AppKit
import Security
import CommonCrypto
import Darwin

final class HostDelegate: NSObject,NSApplicationDelegate,NSWindowDelegate {
    var window: NSWindow!
    var desktop = DesktopView()
    var username = NSTextField(string:"ub_demo")
    var password = NSSecureTextField(string:"")
    var statusLabel = NSTextField(wrappingLabelWithString:"Prepare a Box account, enable Screen Sharing for that account, then connect.")
    var appName = NSTextField(string:"com.apple.TextEdit")
    var ownerButton = NSButton()
    var engine: Engine?
    var apiListener: SocketStream?
    let apiPath = "/tmp/userbox-\(getuid())/control.sock"
    func button(_ title: String,_ action: Selector) -> NSButton { NSButton(title:title,target:self,action:action) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "UserBox — native macOS desktop"; window.delegate = self; window.minSize = NSSize(width:780,height:520)
        username.placeholderString = "Box username"; password.placeholderString = "Box account password (not your host password)"
        username.widthAnchor.constraint(equalToConstant:130).isActive = true; password.widthAnchor.constraint(equalToConstant:260).isActive = true
        let row = NSStackView(views:[username,password,button("Connect",#selector(connect)),button("Disconnect",#selector(disconnect)),button("Sharing Settings",#selector(settings))])
        ownerButton = button("Take Control",#selector(toggleOwner))
        let tools = NSStackView(views:[ownerButton,button("Finder",#selector(finder)),appName,button("Launch App",#selector(launch)),button("Shared Files",#selector(sharedFiles))])
        tools.distribution = .fill; appName.widthAnchor.constraint(greaterThanOrEqualToConstant:200).isActive = true
        let stack = NSStackView(views:[row,tools,statusLabel,desktop]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:14),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-14),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:14),stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-14),desktop.widthAnchor.constraint(equalTo:stack.widthAnchor),desktop.heightAnchor.constraint(greaterThanOrEqualToConstant:300),statusLabel.widthAnchor.constraint(equalTo:stack.widthAnchor)])
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        do { try startAPI() } catch { statusLabel.stringValue = error.localizedDescription }
    }
    @objc func connect() {
        guard engine == nil || engine!.isStopped else { statusLabel.stringValue = "Disconnect the current Box first."; return }
        do {
            let c = try loadConfig(username.stringValue); let secret = password.stringValue; password.stringValue = ""
            _ = try ARD.credentials(username:c.username,password:secret,random:Array(repeating:0,count:128))
            let e = Engine(c); engine = e; desktop.engine = e; desktop.manual = false; desktop.frameImage = nil; desktop.needsDisplay = true; ownerButton.title = "Take Control"
            e.onState = { [weak self,weak e] text in guard let self,let e,self.engine === e else{return}; self.statusLabel.stringValue = text
                if e.isStopped { self.desktop.frameImage = nil; self.desktop.needsDisplay = true; self.desktop.manual = false }
            }
            e.onFrame = { [weak self,weak e] frame in guard let self,let e,self.engine === e else{return}; self.desktop.frameImage = try? imageFor(frame); self.desktop.needsDisplay = true }
            e.start(password:secret)
        } catch { statusLabel.stringValue = error.localizedDescription }
    }
    @objc func disconnect() { engine?.stop(); desktop.frameImage = nil; desktop.manual = false; desktop.needsDisplay = true }
    @objc func settings() { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.Sharing-Settings.extension")!) }
    @objc func toggleOwner() {
        let target = !desktop.manual
        engine?.enqueue(RPC("owner",text:target ? "viewer" : "agent"),viewer:true) { [weak self] r in DispatchQueue.main.async {
            guard let self else{return}; self.statusLabel.stringValue = r.message
            if r.ok { self.desktop.manual = target; self.ownerButton.title = target ? "Return to Agent" : "Take Control"; self.window.makeFirstResponder(target ? self.desktop : nil) }
        }}
    }
    func sendUI(_ request: RPC) {
        guard desktop.manual else { statusLabel.stringValue = "Click Take Control to launch or interact with apps from this window."; return }
        engine?.enqueue(request,viewer:true) { [weak self] r in DispatchQueue.main.async { self?.statusLabel.stringValue = r.message } }
    }
    @objc func finder() { sendUI(RPC("launch",text:"com.apple.finder")) }
    @objc func launch() { sendUI(RPC("launch",text:appName.stringValue)) }
    @objc func sharedFiles() { if let c = engine?.config { sendUI(RPC("open",text:"/Users/Shared/UserBox/\(c.username)")) } }
    func windowDidResignKey(_ notification: Notification) { engine?.enqueue(RPC("release"),viewer:true) }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { engine?.stop(); apiListener?.stop(); unlink(apiPath) }
    func startAPI() throws {
        let dir = "/tmp/userbox-\(getuid())"
        if mkdir(dir,0o700) != 0 && errno != EEXIST { throw UBError("Cannot create local API directory") }
        var st = stat(); guard lstat(dir,&st) == 0,st.st_uid == getuid(),st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),st.st_mode & 0o077 == 0 else { throw UBError("Unsafe local API directory") }
        let listener = try SocketStream.listen(path:apiPath); apiListener = listener
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            while true {
                do {
                    let client = try listener.acceptClient(); try client.requirePeer(uid:getuid()); let request = try client.receive(RPC.self)
                    let done = DispatchSemaphore(value:0)
                    DispatchQueue.main.async {
                        guard let self,let e = self.engine else { try? client.send(Reply(ok:false,message:"No Box connected")); done.signal(); return }
                        if request.command == "status" { try? client.send(Reply(message:e.status)); done.signal(); return }
                        e.enqueue(request,viewer:false) { reply in try? client.send(reply); done.signal() }
                    }
                    if done.wait(timeout:.now()+6) == .timedOut { client.stop() }
                } catch { Thread.sleep(forTimeInterval:0.05) }
            }
        }
    }
}

#endif
