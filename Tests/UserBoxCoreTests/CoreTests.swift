import XCTest
@testable import UserBoxCore
final class CoreTests: XCTestCase {
    let c = BoxConfig(username:"ub_demo",boxUID:502,hostUID:501,groupID:502,root:"/Library/Application Support/UserBox/ub_demo")
    func witness(_ nonce: String = "test") -> Witness { Witness(uid:502,consoleUID:501,sessionUID:502,onConsole:false,loginDone:true,instance:"session-a",width:640,height:480,nonce:nonce) }
    func testConfigRejectsSameUserAndPathTraversal() throws {
        try c.validate(host:501); XCTAssertThrowsError(try c.validate(host:502))
        var bad = c; bad.boxUID = 501; XCTAssertThrowsError(try bad.validate(host:501))
        bad = c; bad.username = "../host"; XCTAssertThrowsError(try bad.validate(host:501))
        bad = c; bad.root = "/tmp/untrusted"; XCTAssertThrowsError(try bad.validate(host:501))
    }
    func testIsolationRejectsConsoleAndWrongIdentities() throws {
        try witness().validate(c,nonce:"test")
        var w = witness(); w.onConsole = true; XCTAssertThrowsError(try w.validate(c,nonce:"test"))
        w = witness(); w.sessionUID = 501; XCTAssertThrowsError(try w.validate(c,nonce:"test"))
        w = witness(); w.consoleUID = 503; XCTAssertThrowsError(try w.validate(c,nonce:"test"))
        w = witness(); w.loginDone = false; XCTAssertThrowsError(try w.validate(c,nonce:"test"))
        XCTAssertThrowsError(try witness().validate(c,nonce:"replay"))
    }
    func testProofExpiresAndRequiresPixels() throws {
        var gate = ProofGate(); let w = witness()
        XCTAssertFalse(gate.permits(instance:w.instance,now:0))
        try gate.accept(witness:w,config:c,nonce:"test",pixelsMatch:true,now:10)
        XCTAssertTrue(gate.permits(instance:w.instance,now:10.5)); XCTAssertFalse(gate.permits(instance:w.instance,now:10.81))
        XCTAssertFalse(gate.permits(instance:"new-session",now:10.5))
        XCTAssertThrowsError(try gate.accept(witness:w,config:c,nonce:"test",pixelsMatch:false,now:10.5))
        XCTAssertFalse(gate.permits(instance:w.instance,now:10.6))
    }
    func testDHSmallKnownAnswer() throws {
        let prime = BigNat(23)
        let a = try BigNat(5).power([6],modulus:prime), b = try BigNat(5).power([15],modulus:prime)
        XCTAssertEqual(try a.bytes(count:1),[8]); XCTAssertEqual(try b.bytes(count:1),[19])
        XCTAssertEqual(try b.power([6],modulus:prime).bytes(count:1),[2])
        XCTAssertEqual(try a.power([15],modulus:prime).bytes(count:1),[2])
    }
    func testDHMultiLimbKnownAnswer() throws {
        let modulus = BigNat([0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xc5])
        let answer = try BigNat([0x12,0x34,0x56,0x78,0x9a,0xbc,0xde,0xf0]).power([0x01,0x02,0x03],modulus:modulus).bytes(count:8)
        // Independent Python pow(base, exponent, modulus) vector.
        XCTAssertEqual(answer,[0x93,0xad,0xbd,0x5a,0x74,0x5a,0x9f,0xb4])
    }
    func testBigNatBounds() {
        XCTAssertThrowsError(try BigNat(30).power([2],modulus:BigNat(23)))
        XCTAssertThrowsError(try BigNat(256).bytes(count:1))
    }
    func testCredentialsNeverTruncateAndHaveTerminators() throws {
        let data = try ARD.credentials(username:"ub_demo",password:"秘密",random:Array(repeating:0xaa,count:128))
        XCTAssertEqual(Array(data.prefix(7)),Array("ub_demo".utf8)); XCTAssertEqual(data[7],0)
        XCTAssertEqual(Array(data[64..<70]),Array("秘密".utf8)); XCTAssertEqual(data[70],0)
        XCTAssertEqual(data[127],0xaa)
        XCTAssertThrowsError(try ARD.credentials(username:"ub_demo",password:String(repeating:"密",count:22),random:Array(repeating:0,count:128)))
        XCTAssertThrowsError(try ARD.credentials(username:"a\0b",password:"test",random:Array(repeating:0,count:128)))
    }
    func testRawAndOverlappingCopyRect() throws {
        var f = try Frame(width:4,height:1); try f.raw(x:0,y:0,w:4,h:1,bytes:Array(0..<16))
        try f.copy(x:1,y:0,w:3,h:1,sx:0,sy:0)
        XCTAssertEqual(f.bytes,[0,1,2,3,0,1,2,3,4,5,6,7,8,9,10,11])
        XCTAssertThrowsError(try f.raw(x:3,y:0,w:2,h:1,bytes:Array(repeating:0,count:8)))
        XCTAssertThrowsError(try Frame(width:16384,height:16384))
    }
    func testCoordinateLetterboxing() {
        let p = Frame.point(x:500,y:250,viewW:1000,viewH:500,frameW:640,frameH:480)
        XCTAssertEqual(p?.0,320); XCTAssertEqual(p?.1,240)
        XCTAssertNil(Frame.point(x:1,y:250,viewW:1000,viewH:500,frameW:640,frameH:480))
        XCTAssertNil(Frame.point(x:.nan,y:0,viewW:1000,viewH:500,frameW:640,frameH:480))
    }
    func markerFrame(_ w: Witness,scale: Int = 1) throws -> Frame {
        var f = try Frame(width:w.width*scale,height:w.height*scale)
        for corner in 0..<2 {
            for (i,c) in Marker.colors(w.nonce,corner:corner).enumerated() {
                let ox = corner == 0 ? Marker.inset : w.width-Marker.inset-Marker.side
                let oy = corner == 0 ? Marker.inset : w.height-Marker.inset-Marker.side
                let x = (ox+(i%8)*6+3)*scale,y = (oy+(i/8)*6+3)*scale
                try f.raw(x:x,y:y,w:1,h:1,bytes:[c.2,c.1,c.0,0])
            }
        }; return f
    }
    func testMarkersProveTwoCornersAndRejectReplay() throws {
        let w = witness("fresh-random-nonce"); let f = try markerFrame(w)
        XCTAssertTrue(Marker.matches(f,witness:w)); XCTAssertFalse(Marker.matches(f,witness:witness("old-nonce")))
        XCTAssertTrue(Marker.matches(try markerFrame(w,scale:2),witness:w))
        var bad = f; bad.bytes = Array(repeating:0,count:f.bytes.count); XCTAssertFalse(Marker.matches(bad,witness:w))
        bad = f; let p = ((w.height-18-48+3)*w.width+(w.width-18-48+3))*4; bad.bytes[p] = 255
        XCTAssertFalse(Marker.matches(bad,witness:w))
    }
    func testRPCSerialization() throws {
        let req = RPC("click",x:123,y:456,value:1)
        let decoded = try JSONDecoder().decode(RPC.self,from:JSONEncoder().encode(req))
        XCTAssertEqual(decoded.x,123); XCTAssertEqual(decoded.command,"click")
    }
    func testRFBRefusesUnauthenticatedConsole() {
        let wire = MemoryStream(Array("RFB 003.889\n".utf8)+[2,1,2])
        XCTAssertThrowsError(try RFBClient(stream:wire).handshake(username:"ub_demo",password:"test",random:{Array(repeating:0,count:$0)},md5:{$0},aes:{a,_ in a}))
        XCTAssertEqual(wire.written,Array("RFB 003.008\n".utf8))
    }
    func testRFBRejectsMaliciousDHSize() {
        let wire = MemoryStream(Array("RFB 003.889\n".utf8)+[1,30,0,2,0xff,0xff])
        XCTAssertThrowsError(try RFBClient(stream:wire).handshake(username:"ub_demo",password:"test",random:{Array(repeating:0,count:$0)},md5:{$0},aes:{a,_ in a}))
    }
    func testUnicodeKeyWireFormat() throws {
        let wire = MemoryStream([]); let rfb = RFBClient(stream:wire)
        try rfb.type("中\n")
        XCTAssertEqual(Array(wire.written.prefix(8)),[4,1,0,0,1,0,0x4e,0x2d])
        XCTAssertEqual(Array(wire.written.suffix(8)),[4,0,0,0,0,0,0xff,0x0d])
    }
}
final class MemoryStream: ByteStream {
    var input: [UInt8],written: [UInt8] = []
    init(_ input: [UInt8]) { self.input = input }
    func read(_ count: Int) throws -> [UInt8] { guard count >= 0,count <= input.count else { throw UBError("Fixture EOF") }; let r = Array(input.prefix(count)); input.removeFirst(count); return r }
    func write(_ data: [UInt8]) throws { written += data }
}
