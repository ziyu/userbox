import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public protocol ByteStream: AnyObject {
    func read(_ count: Int) throws -> [UInt8]
    func write(_ data: [UInt8]) throws
}
public extension ByteStream {
    func u8() throws -> UInt8 { try read(1)[0] }
    func u16() throws -> Int { let b = try read(2); return Int(b[0]) << 8 | Int(b[1]) }
    func u32() throws -> UInt32 { try read(4).reduce(0) { ($0 << 8) | UInt32($1) } }
}
public func be16(_ n: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)] }
public func be32(_ n: UInt32) -> [UInt8] { [UInt8(truncatingIfNeeded:n >> 24), UInt8(truncatingIfNeeded:n >> 16), UInt8(truncatingIfNeeded:n >> 8), UInt8(truncatingIfNeeded:n)] }

public final class SocketStream: ByteStream, @unchecked Sendable {
    public let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    public init(fd: Int32) throws {
        guard fd >= 0 else { throw UBError("Socket creation failed: \(errno)") }; self.fd = fd
        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        #if canImport(Darwin)
        var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        #endif
    }
    deinit { stop(); close(fd) }
    public func stop() { lock.lock(); defer { lock.unlock() }; if !stopped { stopped = true; shutdown(fd, Int32(SHUT_RDWR)) } }
    static var socketType: Int32 {
        #if canImport(Darwin)
        return SOCK_STREAM
        #else
        return Int32(SOCK_STREAM.rawValue)
        #endif
    }
    public static func loopback(port: UInt16 = 5900) throws -> SocketStream {
        let s = try SocketStream(fd: socket(AF_INET, socketType, 0))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw UBError("Cannot reach local Screen Sharing on 127.0.0.1:\(port) (errno \(errno))") }; return s
    }
    static func address(_ path: String) throws -> sockaddr_un {
        guard path.utf8.count < 100, !path.utf8.contains(0) else { throw UBError("Unix socket path is too long") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: Array(path.utf8) + [0]) }; return address
    }
    public static func unix(path: String) throws -> SocketStream {
        let s = try SocketStream(fd: socket(AF_UNIX, socketType, 0)); var addr = try address(path)
        let result = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw UBError("Session witness is not ready (errno \(errno))") }; return s
    }
    public static func listen(path: String) throws -> SocketStream {
        // Only the owner may remove a stale socket. Never follow a symlink here.
        var st = stat()
        if lstat(path, &st) == 0 {
            guard st.st_uid == geteuid(), st.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { throw UBError("Unsafe existing socket path") }
            if (try? unix(path: path)) != nil { throw UBError("Another UserBox process is already listening") }
            guard unlink(path) == 0 else { throw UBError("Cannot replace stale socket") }
        }
        let s = try SocketStream(fd: socket(AF_UNIX, socketType, 0)); var addr = try address(path)
        let result = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw UBError("Socket bind failed (errno \(errno))") }
        guard chmod(path, 0o660) == 0 else { throw UBError("Cannot protect socket") }
        #if canImport(Darwin)
        guard Darwin.listen(s.fd, 8) == 0 else { throw UBError("Socket listen failed") }
        #else
        guard Glibc.listen(s.fd, 8) == 0 else { throw UBError("Socket listen failed") }
        #endif
        return s
    }
    public func acceptClient() throws -> SocketStream { try SocketStream(fd: accept(fd, nil, nil)) }
    public func requirePeer(uid: UInt32) throws {
        #if canImport(Darwin)
        var actual: uid_t = 0, group: gid_t = 0
        guard getpeereid(fd, &actual, &group) == 0, actual == uid else { throw UBError("Unix socket peer identity mismatch") }
        #else
        struct Credentials { var pid: Int32 = 0; var uid: UInt32 = 0; var gid: UInt32 = 0 }
        var c = Credentials(); var size = socklen_t(MemoryLayout.size(ofValue: c))
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &c, &size) == 0, c.uid == uid else { throw UBError("Unix socket peer identity mismatch") }
        #endif
    }
    public func read(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= 64*1024*1024 else { throw UBError("Oversized wire payload") }
        var data = [UInt8](repeating: 0, count: count); var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), count-offset, 0) }
            if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw UBError("Connection closed or timed out") }; offset += n
        }; return data
    }
    public func write(_ data: [UInt8]) throws {
        var offset = 0
        while offset < data.count {
            #if canImport(Darwin)
            let flags: Int32 = 0
            #else
            let flags = Int32(MSG_NOSIGNAL)
            #endif
            let n = data.withUnsafeBytes { buffer in
                #if canImport(Darwin)
                return Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), data.count-offset, flags)
                #else
                return Glibc.send(fd, buffer.baseAddress!.advanced(by: offset), data.count-offset, flags)
                #endif
            }
            if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw UBError("Connection write failed") }; offset += n
        }
    }
    public func receive<T: Decodable>(_ type: T.Type) throws -> T {
        let size = try u32(); guard size > 0, size <= 32*1024*1024 else { throw UBError("RPC too large") }
        return try JSONDecoder().decode(type, from: Data(read(Int(size))))
    }
    public func send<T: Encodable>(_ value: T) throws {
        let d = try JSONEncoder().encode(value); guard d.count <= 32*1024*1024 else { throw UBError("RPC too large") }
        try write(be32(UInt32(d.count)) + d)
    }
}

