import Foundation
import UserBoxCore
#if os(macOS)
import AppKit
import Security
import CommonCrypto
import Darwin

final class Engine: @unchecked Sendable {
    let config: BoxConfig, identifier = UUID()
    private let lock = NSLock()
    private var stopped = false, state = "Disconnected", ready = false
    private var socket: SocketStream?
    private var manual = false
    private var deliveryPending = false
    private var pending: [(RPC,Bool,TimeInterval,(Reply)->Void)] = []
    private var keys = Set<UInt32>(), buttons: UInt8 = 0, point = (0,0)
    var onFrame: ((Frame)->Void)?
    var onState: ((String)->Void)?
    init(_ config: BoxConfig) { self.config = config }
    var status: String { lock.lock(); defer{lock.unlock()}; return state }
    var isStopped: Bool { lock.lock(); defer{lock.unlock()}; return stopped }
    func report(_ text: String,ready: Bool = false) {
        lock.lock(); state = text; self.ready = ready; lock.unlock()
        DispatchQueue.main.async { self.onState?(text) }
    }
    func enqueue(_ request: RPC,viewer: Bool,done: @escaping (Reply)->Void = {_ in}) {
        lock.lock()
        guard ready,!stopped,pending.count < 128 else { lock.unlock(); done(Reply(ok:false,message:"Desktop not verified, disconnected, or command queue full")); return }
        pending.append((request,viewer,ProcessInfo.processInfo.systemUptime+4,done)); lock.unlock()
    }
    func stop() {
        lock.lock(); stopped = true; ready = false; let s = socket; let p = pending; pending = []; lock.unlock()
        s?.stop(); p.forEach{$0.3(Reply(ok:false,message:"Disconnected; command cancelled"))}; report("Disconnected")
    }
    private func release(_ rfb: RFBClient) throws {
        for key in keys { try rfb.key(key,down:false) }; keys.removeAll()
        try rfb.pointer(x:point.0,y:point.1,buttons:0); buttons = 0
    }
    private func action(_ req: RPC,viewer: Bool,rfb: RFBClient,frame: Frame) throws -> Reply {
        if req.command == "snapshot" { return try Reply(image:png(frame)) }
        if req.command == "owner",viewer {
            guard req.text == "viewer" || req.text == "agent" else { throw UBError("Invalid owner") }
            try release(rfb); manual = req.text == "viewer"; return Reply(message:manual ? "Viewer owns input" : "Agent owns input")
        }
        guard viewer == manual else { throw UBError(manual ? "User has taken control; agent input is paused" : "Click Take Control before using the viewer") }
        switch req.command {
        case "launch","open": return try callWitness(config,req)
        case "pointer","click":
            guard let x = req.x,let y = req.y,let value = req.value,(0...7).contains(value) else { throw UBError("Invalid pointer request") }
            point = (x,y); buttons = UInt8(value); try rfb.pointer(x:x,y:y,buttons:buttons)
            if req.command == "click" { try rfb.pointer(x:x,y:y,buttons:0); buttons = 0 }
        case "scroll":
            guard let x = req.x,let y = req.y,let n = req.value,(-20...20).contains(n) else { throw UBError("Invalid scroll request") }
            for _ in 0..<abs(n) { try rfb.pointer(x:x,y:y,buttons:n > 0 ? 8 : 16); try rfb.pointer(x:x,y:y,buttons:0) }
        case "key":
            guard let value = req.value,value >= 0,value <= Int(UInt32.max),let down = req.down else { throw UBError("Invalid key request") }
            let k = UInt32(value); try rfb.key(k,down:down); if down { keys.insert(k) } else { keys.remove(k) }
        case "type": try rfb.type(req.text ?? "")
        case "release": try release(rfb)
        default: throw UBError("Unsupported command")
        }
        return Reply(message:"Input delivered; verify the next frame before claiming task success.")
    }
    func start(password: String) {
        DispatchQueue.global(qos:.userInitiated).async { [self] in
            do {
                let s = try SocketStream.loopback(); lock.lock(); socket = s; lock.unlock()
                let rfb = RFBClient(stream:s); report("Authenticating Box user with local Screen Sharing…")
                try rfb.handshake(username:config.username,password:password,random:randomBytes,md5:digest,aes:encrypt)
                var gate = ProofGate(); var verified = false
                let startupDeadline = ProcessInfo.processInfo.systemUptime+45
                while !isStopped {
                    let start = ProcessInfo.processInfo.systemUptime
                    do {
                        let nonce = try randomBytes(32).map{String(format:"%02x",$0)}.joined()
                        guard let w = try callWitness(config,RPC("probe",text:nonce)).witness else { throw UBError("Missing session witness") }
                        try w.validate(config,nonce:nonce)
                        // The witness draws a fresh challenge in its own desktop. Never
                        // display or accept input for frames before this match succeeds.
                        var frame = try rfb.requestFrame()
                        for _ in 0..<3 where !Marker.matches(frame,witness:w) {
                            Thread.sleep(forTimeInterval:0.04); frame = try rfb.requestFrame()
                        }
                        try gate.accept(witness:w,config:config,nonce:nonce,pixelsMatch:Marker.matches(frame,witness:w),now:ProcessInfo.processInfo.systemUptime)
                        guard !isStopped else { break }
                        verified = true; report("Verified · \(config.username) · \(frame.width)×\(frame.height) · \(manual ? "Viewer" : "Agent") owns input",ready:true)
                        lock.lock(); let shouldDeliver = !deliveryPending; deliveryPending = true; lock.unlock()
                        if shouldDeliver {
                            let delivered = frame
                            DispatchQueue.main.async {
                                if !self.isStopped { self.onFrame?(delivered) }
                                self.lock.lock(); self.deliveryPending = false; self.lock.unlock()
                            }
                        }
                        lock.lock(); let batch = pending; pending = []; lock.unlock()
                        for (req,viewer,deadline,done) in batch {
                            do {
                                guard !isStopped,ProcessInfo.processInfo.systemUptime < deadline else { throw UBError("Command cancelled or expired") }
                                guard let fresh = try callWitness(config,RPC("probe",text:nonce)).witness else { throw UBError("Lost session witness") }
                                try fresh.validate(config,nonce:nonce)
                                guard gate.permits(instance:fresh.instance,now:ProcessInfo.processInfo.systemUptime) else { throw UBError("Frame proof expired; retry command") }
                                done(try action(req,viewer:viewer,rfb:rfb,frame:frame))
                            } catch { done(Reply(ok:false,message:error.localizedDescription)) }
                        }
                    } catch {
                        gate.invalidate()
                        if verified || ProcessInfo.processInfo.systemUptime >= startupDeadline { throw error }
                        report("Waiting for isolated Aqua session: \(error.localizedDescription)")
                    }
                    Thread.sleep(forTimeInterval:max(0.02,0.2-(ProcessInfo.processInfo.systemUptime-start)))
                }
                s.stop()
            } catch {
                stop(); report("Stopped safely: \(error.localizedDescription)")
            }
        }
    }
}

#endif
