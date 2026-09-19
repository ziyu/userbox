import Foundation
import UserBoxCore
#if os(macOS)
import AppKit
import Security
import CommonCrypto
import Darwin

func randomBytes(_ count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating:0,count:count)
    guard SecRandomCopyBytes(kSecRandomDefault,count,&bytes) == errSecSuccess else { throw UBError("System random generator failed") }; return bytes
}
func digest(_ bytes: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating:0,count:16); bytes.withUnsafeBytes { p in _ = CC_MD5(p.baseAddress,CC_LONG(bytes.count),&out) }; return out
}
func encrypt(_ bytes: [UInt8], _ key: [UInt8]) throws -> [UInt8] {
    guard key.count == 16,bytes.count % 16 == 0 else { throw UBError("Invalid AES block") }
    var output = [UInt8](repeating:0,count:bytes.count+16); var written = 0; let capacity = output.count
    let status = key.withUnsafeBytes { k in bytes.withUnsafeBytes { b in
        CCCrypt(CCOperation(kCCEncrypt),CCAlgorithm(kCCAlgorithmAES),CCOptions(kCCOptionECBMode),k.baseAddress,16,nil,
                b.baseAddress,bytes.count,&output,capacity,&written)
    }}
    guard status == kCCSuccess,written == bytes.count else { throw UBError("ARD encryption failed") }; return Array(output.prefix(written))
}
func loadConfig(_ username: String, witness: Bool = false) throws -> BoxConfig {
    guard username.range(of:"^ub_[a-z0-9_]{1,24}$",options:.regularExpression) != nil else { throw UBError("Box names must match ub_[a-z0-9_]{1,24}") }
    let path = "/Library/Application Support/UserBox/\(username)/config.json"
    // Open atomically without following a symlink and verify the inode we read.
    let fd = open(path,O_RDONLY|O_NOFOLLOW); guard fd >= 0 else { throw UBError("Run setup-macos.sh create \(username) first") }; defer { close(fd) }
    var st = stat(); guard fstat(fd,&st) == 0,st.st_uid == 0,st.st_mode & 0o022 == 0,st.st_size > 0,st.st_size < 8192 else { throw UBError("Configuration is not root-owned and protected") }
    let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
    let c = try JSONDecoder().decode(BoxConfig.self,from:handle.readToEnd() ?? Data())
    try c.validate(host:witness ? c.hostUID : getuid())
    guard c.username == username,let account = getpwnam(username),account.pointee.pw_uid == c.boxUID,
          !witness || getuid() == c.boxUID else { throw UBError("Box account identity mismatch") }
    return c
}
func callWitness(_ config: BoxConfig,_ request: RPC) throws -> Reply {
    let socket = try SocketStream.unix(path:config.socketPath); try socket.requirePeer(uid:config.boxUID)
    try socket.send(request); let reply = try socket.receive(Reply.self)
    guard reply.ok else { throw UBError(reply.message) }; return reply
}
func imageFor(_ frame: Frame) throws -> CGImage {
    guard let provider = CGDataProvider(data:Data(frame.bytes) as CFData),
          let image = CGImage(width:frame.width,height:frame.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:frame.width*4,
              space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipFirst.rawValue).union(.byteOrder32Little),
              provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw UBError("Cannot decode desktop frame") }; return image
}
func png(_ frame: Frame) throws -> Data {
    guard let data = NSBitmapImageRep(cgImage:try imageFor(frame)).representation(using:.png,properties:[:]) else { throw UBError("PNG encoding failed") }; return data
}

#endif
