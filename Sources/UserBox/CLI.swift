import Foundation
import UserBoxCore
#if os(macOS)
import AppKit
import Security
import CommonCrypto
import Darwin

func cli(_ args: [String]) throws {
    guard let command = args.first else { throw UBError("Usage: userbox ctl status|launch APP|open PATH|type TEXT|click X Y [BUTTON]|scroll X Y N|key KEYSYM down|up|snapshot FILE.png") }
    var request = RPC(command)
    switch command {
    case "status": break
    case "launch","open","type": guard args.count == 2 else { throw UBError("Expected exactly one text argument") }; request.text = args[1]
    case "click","scroll":
        guard args.count >= 3,let x = Int(args[1]),let y = Int(args[2]) else { throw UBError("Invalid coordinates") }
        request.x = x; request.y = y; request.value = args.count > 3 ? Int(args[3]) : 1
    case "key":
        guard args.count == 3,let key = UInt32(args[1].replacingOccurrences(of:"0x",with:""),radix:args[1].hasPrefix("0x") ? 16 : 10),["down","up"].contains(args[2]) else { throw UBError("Invalid keysym or direction") }
        request.value = Int(key); request.down = args[2] == "down"
    case "snapshot": guard args.count == 2 else { throw UBError("Expected destination PNG path") }
    default: throw UBError("Unknown CLI command")
    }
    let s = try SocketStream.unix(path:"/tmp/userbox-\(getuid())/control.sock"); try s.requirePeer(uid:getuid()); try s.send(request)
    let reply = try s.receive(Reply.self); guard reply.ok else { throw UBError(reply.message) }
    if let image = reply.image,command == "snapshot" { try image.write(to:URL(fileURLWithPath:args[1]),options:.atomic) }
    print(reply.message)
}

#endif
