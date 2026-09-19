import Foundation
import UserBoxCore
#if os(macOS)
import AppKit
import Security
import CommonCrypto
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments.first == "ctl" { try cli(Array(arguments.dropFirst())) }
    else if arguments.first == "--witness",arguments.count == 2 {
        let delegate = WitnessDelegate(try loadConfig(arguments[1],witness:true)); let app = NSApplication.shared; app.delegate = delegate; withExtendedLifetime(delegate){app.run()}
    } else if arguments.first == "--crypto-self-test" {
        guard digest(Array("abc".utf8)).map({String(format:"%02x",$0)}).joined() == "900150983cd24fb0d6963f7d28e17f72",
              try encrypt(Array(repeating:0,count:16),Array(repeating:0,count:16)).map({String(format:"%02x",$0)}).joined() == "66e94bd4ef8a2c3b884cfa59ca342b2e" else { throw UBError("CommonCrypto self-test failed") }; print("CommonCrypto vectors passed")
    } else {
        let delegate = HostDelegate(); let app = NSApplication.shared; app.delegate = delegate; withExtendedLifetime(delegate){app.run()}
    }
} catch { fputs("UserBox: \(error.localizedDescription)\n",stderr); exit(1) }
#else
fputs("The UserBox desktop executable requires macOS 14+. Protocol and isolation tests run on Linux.\n",stderr)
exit(1)
#endif
