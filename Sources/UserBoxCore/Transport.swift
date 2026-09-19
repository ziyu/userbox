import Foundation
import CUserBox

public enum Wire {
    public static let maxJSON = 256 * 1024
    public static let maxPayload = 16 * 1024 * 1024
    public static func read(_ fd: Int32, count: Int, maximum: Int) throws -> Data {
        guard count >= 0, count <= maximum else { throw BoxError("Message exceeds protocol limit") }
        var data = Data(count: count)
        if count > 0 {
            let result = data.withUnsafeMutableBytes { ub_read_exact(fd, $0.baseAddress, count) }
            guard result == 0 else { throw BoxError("Socket closed or read deadline exceeded") }
        }
        return data
    }
    public static func write(_ fd: Int32, data: Data) throws {
        if !data.isEmpty {
            let result = data.withUnsafeBytes { ub_write_exact(fd, $0.baseAddress, data.count) }
            guard result == 0 else { throw BoxError("Socket closed or write deadline exceeded") }
        }
    }
    public static func receive<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
        let header = try read(fd, count: 4, maximum: 4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0 else { throw BoxError("Empty protocol envelope") }
        return try JSONDecoder().decode(type, from: read(fd, count: count, maximum: maxJSON))
    }
    public static func send<T: Encodable>(_ value: T, to fd: Int32) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maxJSON else { throw BoxError("Envelope exceeds limit") }
        let n = UInt32(data.count)
        try write(fd, data: Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]))
        try write(fd, data: data)
    }
}

/// One serialized RPC channel; all blocking I/O runs on a dedicated queue, not the UI executor.
public final class BoxConnection: @unchecked Sendable {
    public let config: BoxConfig
    private let queue = DispatchQueue(label: "io.userbox.rpc")
    private var fd: Int32 = -1
    private var pinnedSession: UInt32?
    public init(config: BoxConfig) { self.config = config }
    deinit { ub_close(fd) }
    public func close() {
        queue.async { [self] in ub_close(fd); fd = -1; pinnedSession = nil }
    }
    public func call(_ request: Request, payload: Data = Data()) async throws -> (Reply, Data) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try config.validate()
                    guard ub_uid() == config.hostUID else { throw BoxError("Run the controller as the configured host user, not root") }
                    if fd < 0 {
                        fd = ub_connect(config.socketPath)
                        guard fd >= 0 else { throw BoxError("Desktop helper is not connected. Start the dedicated graphical login first.") }
                        var uid: UInt32 = 0
                        guard ub_peer_uid(fd, &uid) == 0, uid == config.guestUID else {
                            throw BoxError("Socket peer is not the dedicated Box user")
                        }
                    }
                    guard request.payloadBytes == payload.count, payload.count <= Wire.maxPayload else {
                        throw BoxError("Invalid outgoing payload length")
                    }
                    try Wire.send(request, to: fd); try Wire.write(fd, data: payload)
                    let reply = try Wire.receive(Reply.self, from: fd)
                    guard reply.id == request.id else { throw BoxError("RPC response ID mismatch") }
                    let bytes = try Wire.read(fd, count: reply.payloadBytes, maximum: Wire.maxPayload)
                    // Even metadata/failure responses must originate from the expected session before display.
                    if let identity = reply.identity {
                        try identity.validate(for: config, pinnedSession: pinnedSession)
                        pinnedSession = identity.sessionID
                    } else if reply.ok { throw BoxError("Missing graphical session identity") }
                    if !reply.ok {
                        continuation.resume(throwing: BoxError(reply.error ?? "Desktop command failed")); return
                    }
                    continuation.resume(returning: (reply, bytes))
                } catch {
                    ub_close(fd); fd = -1; pinnedSession = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
