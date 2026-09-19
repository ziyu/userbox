import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class RFBClient {
    public let stream: ByteStream
    public private(set) var frame: Frame?
    public init(stream: ByteStream) { self.stream = stream }
    public func handshake(username: String, password: String,
                          random: (Int) throws -> [UInt8], md5: ([UInt8]) -> [UInt8],
                          aes: ([UInt8],[UInt8]) throws -> [UInt8]) throws {
        let version = String(bytes: try stream.read(12),encoding:.ascii)
        guard ["RFB 003.889\n","RFB 003.008\n"].contains(version) else { throw UBError("Not a supported Apple Screen Sharing server") }
        try stream.write(Array("RFB 003.008\n".utf8))
        let count = Int(try stream.u8()); guard count > 0 else { throw UBError("Screen Sharing rejected the connection") }
        let types = try stream.read(count)
        guard types.contains(30) else { throw UBError("Apple user authentication (type 30) is unavailable; refusing console/password-only fallback") }
        try stream.write([30])
        let generator = try stream.read(2), length = try stream.u16()
        guard (64...256).contains(length) else { throw UBError("Unsupported ARD key size") }
        let prime = BigNat(try stream.read(length)), server = BigNat(try stream.read(length))
        guard prime > BigNat(3),server > BigNat(1),server < prime.subtract(BigNat(1)) else { throw UBError("Invalid server DH public key") }
        var exponent = try random(32); guard exponent.count == 32 else { throw UBError("RNG failed") }; exponent[0] |= 0x80
        let pub = try BigNat(generator).power(exponent,modulus:prime).bytes(count:length)
        var shared = try server.power(exponent,modulus:prime).bytes(count:length)
        var packed = try ARD.credentials(username:username,password:password,random:random(128))
        let encrypted = try aes(packed,md5(shared)); packed = Array(repeating:0,count:128); shared = Array(repeating:0,count:length)
        guard encrypted.count == 128 else { throw UBError("ARD encryption failed") }; try stream.write(encrypted+pub)
        guard try stream.u32() == 0 else { throw UBError("Screen Sharing authentication failed; check this Box account's access") }
        try stream.write([1]) // Shared connection: never disconnect another viewer.
        let w = try stream.u16(), h = try stream.u16(); _ = try stream.read(16)
        let nameLength = try stream.u32(); guard nameLength <= 65536 else { throw UBError("Invalid desktop name length") }; _ = try stream.read(Int(nameLength))
        frame = try Frame(width:w,height:h)
        // 32-bit little-endian BGRX, true colour. No lossy encoding, clipboard, audio,
        // resize requests or host-global input APIs.
        try stream.write([0,0,0,0,32,24,0,1,0,255,0,255,0,255,16,8,0,0,0,0])
        let encodings: [Int32] = [0,1,-223,-224,-239]
        try stream.write([2,0]+be16(encodings.count)+encodings.flatMap { be32(UInt32(bitPattern:$0)) })
    }
    public func requestFrame() throws -> Frame {
        guard let f = frame else { throw UBError("Not connected") }
        try stream.write([3,0]+be16(0)+be16(0)+be16(f.width)+be16(f.height))
        for _ in 0..<64 {
            switch try stream.u8() {
            case 0:
                _ = try stream.u8(); let count = try stream.u16(); guard count <= 8192 else { throw UBError("Too many rectangles") }
                for _ in 0..<count {
                    let x = try stream.u16(), y = try stream.u16(), w = try stream.u16(), h = try stream.u16()
                    let encoding = Int32(bitPattern:try stream.u32())
                    if encoding == -224 { break }
                    switch encoding {
                    case 0: try frame!.bounds(x,y,w,h); let bytes = try stream.read(w*h*4); try frame!.raw(x:x,y:y,w:w,h:h,bytes:bytes)
                    case 1: let sx = try stream.u16(), sy = try stream.u16(); try frame!.copy(x:x,y:y,w:w,h:h,sx:sx,sy:sy)
                    case -223: frame = try Frame(width:w,height:h)
                    case -239: guard w <= 512,h <= 512 else { throw UBError("Oversized remote cursor") }; _ = try stream.read(w*h*4+((w+7)/8)*h)
                    default: throw UBError("Unsupported framebuffer encoding: \(encoding)")
                    }
                }; return frame!
            case 2: continue // Bell deliberately not forwarded to the host.
            case 3: _ = try stream.read(3); let n = try stream.u32(); guard n <= 1_048_576 else { throw UBError("Clipboard payload too large") }; _ = try stream.read(Int(n))
            default: throw UBError("Unsupported server message")
            }
        }; throw UBError("Server did not produce a framebuffer")
    }
    public func pointer(x: Int,y: Int,buttons: UInt8) throws {
        guard let f = frame,x >= 0,y >= 0,x < f.width,y < f.height else { throw UBError("Pointer outside Box") }
        try stream.write([5,buttons]+be16(x)+be16(y))
    }
    public func key(_ keysym: UInt32,down: Bool) throws { try stream.write([4,down ? 1 : 0,0,0]+be32(keysym)) }
    public func type(_ text: String) throws {
        guard text.utf8.count <= 8192 else { throw UBError("Text is too long") }
        for s in text.unicodeScalars {
            let k: UInt32 = s.value == 10 ? 0xff0d : s.value == 9 ? 0xff09 : s.value < 256 ? s.value : 0x01000000 | s.value
            try key(k,down:true); try key(k,down:false)
        }
    }
}
