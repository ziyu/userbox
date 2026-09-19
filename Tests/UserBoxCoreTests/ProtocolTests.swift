import XCTest
@testable import UserBoxCore

final class ProtocolTests: XCTestCase {
    // A synthetic 512-bit modulus is deliberately a protocol fixture, not a
    // cryptographic recommendation. CommonCrypto has separate native vectors.
    func connection() throws -> (RFBClient, MemoryStream) {
        let banner = Array("RFB 003.889\n".utf8)
        let prime = Array(repeating: UInt8(255), count: 64)
        let serverKey = Array(repeating: UInt8(0), count: 63) + [2]
        let security = [UInt8(1),30,0,2] + be16(64) + prime + serverKey + be32(0)
        let initMessage = be16(2) + be16(2) + Array(repeating: UInt8(0), count: 16) + be32(4) + Array("test".utf8)
        let wire = MemoryStream(banner + security + initMessage)
        let client = RFBClient(stream: wire)
        try client.handshake(username: "ub_demo", password: "fixture-only",
            random: { Array(repeating: 1, count: $0) },
            md5: { _ in Array(repeating: 0, count: 16) },
            aes: { credentials, key in
                XCTAssertEqual(key.count, 16)
                XCTAssertEqual(credentials.count, 128)
                XCTAssertEqual(Array(credentials.prefix(7)), Array("ub_demo".utf8))
                return Array(repeating: 0xab, count: 128)
            })
        return (client, wire)
    }
    func rectangle(x: Int = 0, y: Int = 0, w: Int, h: Int, encoding: Int32, data: [UInt8] = []) -> [UInt8] {
        be16(x) + be16(y) + be16(w) + be16(h) + be32(UInt32(bitPattern: encoding)) + data
    }
    func testHandshakeCredentialOrderingAndSharedMode() throws {
        let (client, wire) = try connection()
        XCTAssertEqual(client.frame?.width, 2)
        XCTAssertEqual(Array(wire.written[13..<141]), Array(repeating: 0xab, count: 128))
        XCTAssertEqual(wire.written[205], 1, "ClientInit must preserve other viewers")
        XCTAssertEqual(Array(wire.written[206..<210]), [0,0,0,0])
        XCTAssertTrue(wire.input.isEmpty)
    }
    func testRawFramebufferRoundTripAndPointerBounds() throws {
        let (client, wire) = try connection()
        wire.input = [0,0,0,1] + rectangle(w:2,h:2,encoding:0,data:Array(0..<16))
        XCTAssertEqual(try client.requestFrame().bytes, Array(0..<16))
        XCTAssertThrowsError(try client.pointer(x:2,y:0,buttons:1))
        try client.pointer(x:1,y:1,buttons:1)
        XCTAssertEqual(Array(wire.written.suffix(6)), [5,1,0,1,0,1])
    }
    func testDesktopResizeBeforeRawRectangle() throws {
        let (client, wire) = try connection()
        wire.input = [0,0,0,2] + rectangle(w:3,h:1,encoding:-223)
            + rectangle(w:3,h:1,encoding:0,data:Array(0..<12))
        let frame = try client.requestFrame()
        XCTAssertEqual(frame.width,3); XCTAssertEqual(frame.height,1)
        XCTAssertEqual(frame.bytes,Array(0..<12))
    }
    func testUnknownEncodingAndTruncatedPayloadFail() throws {
        let (client, wire) = try connection()
        wire.input = [0,0,0,1] + rectangle(w:1,h:1,encoding:99)
        XCTAssertThrowsError(try client.requestFrame())
        wire.input = [0,0,0,1] + rectangle(w:2,h:2,encoding:0,data:[0])
        XCTAssertThrowsError(try client.requestFrame())
    }
    func testBellAndClipboardAreNotHostActions() throws {
        let (client, wire) = try connection()
        wire.input = [2,3,0,0,0] + be32(4) + Array("text".utf8)
            + [0,0,0,1] + rectangle(w:2,h:2,encoding:0,data:Array(repeating:0,count:16))
        XCTAssertEqual(try client.requestFrame().bytes.count,16)
        XCTAssertTrue(wire.input.isEmpty)
    }
    func testInvalidIdentityRevokesPreviousProof() throws {
        let config = BoxConfig(username:"ub_demo",boxUID:502,hostUID:501,groupID:502,root:"/Library/Application Support/UserBox/ub_demo")
        var witness = Witness(uid:502,consoleUID:501,sessionUID:502,onConsole:false,loginDone:true,instance:"a",width:640,height:480,nonce:"n")
        var gate = ProofGate()
        try gate.accept(witness:witness,config:config,nonce:"n",pixelsMatch:true,now:10)
        witness.onConsole = true
        XCTAssertThrowsError(try gate.accept(witness:witness,config:config,nonce:"n",pixelsMatch:true,now:10.1))
        XCTAssertFalse(gate.permits(instance:"a",now:10.2))
    }
}
