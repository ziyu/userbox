import Foundation
import CUserBox

public struct BoxError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct BoxConfig: Codable, Equatable {
    public var version: Int = 1
    public let name: String
    public let username: String
    public let hostUID: UInt32
    public let guestUID: UInt32
    public init(name: String, username: String, hostUID: UInt32, guestUID: UInt32) {
        self.name = name; self.username = username; self.hostUID = hostUID; self.guestUID = guestUID
    }
    public var socketPath: String { "/Users/Shared/UserBox/\(name)/run/control.sock" }
    public var configPath: String { Self.path(for: name) }
    public static func path(for name: String) -> String { "/Library/Application Support/UserBox/boxes/\(name).json" }
    public static func validName(_ name: String) -> Bool {
        name.range(of: "\\A[a-z][a-z0-9_]{0,19}\\z", options: .regularExpression) != nil
    }
    public func validate() throws {
        guard version == 1, Self.validName(name), username == "ub_" + name,
              hostUID >= 501, guestUID >= 501, hostUID != guestUID else {
            throw BoxError("Invalid UserBox configuration or non-isolated account IDs")
        }
    }
    public static func load(_ name: String) throws -> BoxConfig {
        guard validName(name) else { throw BoxError("Invalid box name") }
        let path = Self.path(for: name)
        guard ub_secure_config(path) == 1 else { throw BoxError("Configuration must be a root-owned, non-writable regular file: \(path)") }
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try config.validate()
        guard config.name == name else { throw BoxError("Configuration name mismatch") }
        return config
    }
}

public struct SessionIdentity: Codable, Equatable {
    public var protocolVersion: Int = 1
    public var uid: UInt32
    public var sessionUID: UInt32
    public var sessionID: UInt32
    public var consoleUID: UInt32
    public var graphical: Bool
    public var onConsole: Bool
    public var loggedIn: Bool
    public var screenRecording: Bool
    public var accessibility: Bool
    public init(uid: UInt32, sessionUID: UInt32, sessionID: UInt32, consoleUID: UInt32,
                graphical: Bool, onConsole: Bool, loggedIn: Bool,
                screenRecording: Bool = false, accessibility: Bool = false) {
        self.uid = uid; self.sessionUID = sessionUID; self.sessionID = sessionID
        self.consoleUID = consoleUID; self.graphical = graphical; self.onConsole = onConsole
        self.loggedIn = loggedIn; self.screenRecording = screenRecording; self.accessibility = accessibility
    }
    public func validate(for config: BoxConfig, pinnedSession: UInt32? = nil) throws {
        try config.validate()
        guard protocolVersion == 1, uid == config.guestUID, sessionUID == config.guestUID,
              uid != config.hostUID, consoleUID == config.hostUID, !onConsole,
              graphical, loggedIn, sessionID != 0 else {
            throw BoxError("Not the expected off-console graphical user session. Control is blocked.")
        }
        if let pinnedSession, pinnedSession != sessionID {
            throw BoxError("The graphical session changed. Reconnect explicitly before controlling it.")
        }
    }
}

public struct InputEvent: Codable {
    public var kind: String
    public var x: Double? = nil
    public var y: Double? = nil
    public var button: Int? = nil
    public var clicks: Int? = nil
    public var keyCode: UInt16? = nil
    public var flags: UInt64? = nil
    public var text: String? = nil
    public var deltaX: Int? = nil
    public var deltaY: Int? = nil
    public init(kind: String) { self.kind = kind }
    public func validate() throws {
        switch kind {
        case "move", "down", "up":
            guard let x, let y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
                  (0...2).contains(button ?? 0), (1...3).contains(clicks ?? 1) else { throw BoxError("Invalid pointer coordinates/button") }
        case "keyDown", "keyUp":
            guard let keyCode, keyCode <= 127 else { throw BoxError("Invalid macOS virtual key code") }
        case "flags": break
        case "text":
            guard let text, !text.isEmpty, text.utf8.count <= 8192 else { throw BoxError("Text must be 1...8192 UTF-8 bytes") }
        case "scroll":
            guard (-1200...1200).contains(deltaX ?? 0), (-1200...1200).contains(deltaY ?? 0) else {
                throw BoxError("Scroll delta exceeds limit")
            }
        case "release": break
        default: throw BoxError("Unsupported input event")
        }
    }
}

public struct AppInfo: Codable, Identifiable {
    public let name: String
    public let path: String
    public let bundleID: String
    public var id: String { path }
    public init(name: String, path: String, bundleID: String) { self.name = name; self.path = path; self.bundleID = bundleID }
}
public struct FrameInfo: Codable {
    public let width: Int
    public let height: Int
    public let sequence: UInt64
    public init(width: Int, height: Int, sequence: UInt64) { self.width = width; self.height = height; self.sequence = sequence }
}
public struct Request: Codable {
    public var id: String = UUID().uuidString
    public var action: String
    public var lease: String? = nil
    public var role: String? = nil
    public var appPath: String? = nil
    public var filename: String? = nil
    public var event: InputEvent? = nil
    public var payloadBytes: Int = 0
    public init(_ action: String) { self.action = action }
}
public struct Reply: Codable {
    public var id: String
    public var ok: Bool = true
    public var error: String? = nil
    public var identity: SessionIdentity? = nil
    public var lease: String? = nil
    public var frame: FrameInfo? = nil
    public var applications: [AppInfo]? = nil
    public var result: String? = nil
    public var payloadBytes: Int = 0
    public init(id: String) { self.id = id }
}

public struct LeaseState {
    public private(set) var owner: String? = nil
    public private(set) var role: String? = nil
    public private(set) var token: String? = nil
    public private(set) var expiry: Double = 0
    public init() {}
    public mutating func acquire(owner: String, role: String, now: Double) throws -> String {
        guard role == "human" || role == "agent" else { throw BoxError("Unknown control role") }
        // Only an explicit human takeover can preempt another live controller.
        if let previous = self.owner, previous != owner, now < expiry, role != "human" {
            throw BoxError("Another controller holds this desktop. Agent takeover denied.")
        }
        let value = UUID().uuidString
        self.owner = owner; self.role = role; token = value; expiry = now + 15
        return value
    }
    public mutating func require(owner: String, token: String?, now: Double) throws {
        guard self.owner == owner, self.token != nil, token == self.token, now < expiry else {
            throw BoxError("Control lease missing, expired or revoked")
        }
        expiry = now + 15
    }
    public mutating func release(owner: String) -> Bool {
        guard self.owner == owner else { return false }
        self.owner = nil; role = nil; token = nil; expiry = 0; return true
    }
    public mutating func expire(now: Double) -> Bool {
        guard let owner, now >= expiry else { return false }
        return release(owner: owner)
    }
}

public enum SafeFiles {
    public static func filename(_ name: String) throws -> String {
        guard !name.isEmpty, name.utf8.count <= 200, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw BoxError("A single safe filename is required")
        }
        return name
    }
}
