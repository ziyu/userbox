import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct UBError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct BoxConfig: Codable {
    public var username: String
    public var boxUID: UInt32
    public var hostUID: UInt32
    public var groupID: UInt32
    public var root: String
    public init(username: String, boxUID: UInt32, hostUID: UInt32, groupID: UInt32, root: String) {
        self.username = username; self.boxUID = boxUID; self.hostUID = hostUID; self.groupID = groupID; self.root = root
    }
    public func validate(host: UInt32) throws {
        guard username.range(of: "^ub_[a-z0-9_]{1,24}$", options: .regularExpression) != nil,
              boxUID >= 501, hostUID >= 501, boxUID != hostUID, host == hostUID,
              root == "/Library/Application Support/UserBox/\(username)" else { throw UBError("Invalid or mismatched Box configuration") }
    }
    // Short socket paths avoid macOS's 104-byte sockaddr_un limit.
    public var socketPath: String { "/Users/Shared/.userbox-\(boxUID)/witness.sock" }
}
public struct Witness: Codable {
    public var uid: UInt32
    public var consoleUID: UInt32
    public var sessionUID: UInt32
    public var onConsole: Bool
    public var loginDone: Bool
    public var instance: String
    public var width: Int
    public var height: Int
    public var nonce: String
    public init(uid: UInt32, consoleUID: UInt32, sessionUID: UInt32, onConsole: Bool, loginDone: Bool,
                instance: String, width: Int, height: Int, nonce: String) {
        self.uid = uid; self.consoleUID = consoleUID; self.sessionUID = sessionUID; self.onConsole = onConsole
        self.loginDone = loginDone; self.instance = instance; self.width = width; self.height = height; self.nonce = nonce
    }
    public func validate(_ config: BoxConfig, nonce expected: String) throws {
        guard uid == config.boxUID, sessionUID == config.boxUID, consoleUID == config.hostUID,
              !onConsole, loginDone, !instance.isEmpty, nonce == expected,
              width >= 320, height >= 240, width <= 8192, height <= 8192 else {
            throw UBError("Session isolation check failed; no input was sent")
        }
    }
}
public struct RPC: Codable {
    public var command: String
    public var text: String?
    public var x: Int?
    public var y: Int?
    public var value: Int?
    public var down: Bool?
    public init(_ command: String, text: String? = nil, x: Int? = nil, y: Int? = nil, value: Int? = nil, down: Bool? = nil) {
        self.command = command; self.text = text; self.x = x; self.y = y; self.value = value; self.down = down
    }
}
public struct Reply: Codable {
    public var ok: Bool
    public var message: String
    public var witness: Witness?
    public var image: Data?
    public init(ok: Bool = true, message: String = "ok", witness: Witness? = nil, image: Data? = nil) {
        self.ok = ok; self.message = message; self.witness = witness; self.image = image
    }
}
public struct ProofGate {
    private var deadline: TimeInterval = 0
    private var instance: String?
    public init() {}
    public mutating func invalidate() { deadline = 0; instance = nil }
    public mutating func accept(witness: Witness, config: BoxConfig, nonce: String, pixelsMatch: Bool, now: TimeInterval) throws {
        invalidate()
        try witness.validate(config, nonce: nonce)
        guard pixelsMatch else { invalidate(); throw UBError("Desktop pixels do not match the isolated session") }
        instance = witness.instance; deadline = now + 0.8
    }
    public func permits(instance: String, now: TimeInterval) -> Bool { self.instance == instance && now < deadline }
}

