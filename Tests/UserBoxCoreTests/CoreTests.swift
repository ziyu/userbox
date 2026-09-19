import XCTest
import Foundation
import CUserBox
@testable import UserBoxCore

final class CoreTests: XCTestCase {
    let config = BoxConfig(name: "demo", username: "ub_demo", hostUID: 501, guestUID: 502)
    var identity: SessionIdentity {
        SessionIdentity(uid: 502, sessionUID: 502, sessionID: 100, consoleUID: 501, graphical: true, onConsole: false, loggedIn: true)
    }
    func testValidConfiguration() throws { try config.validate(); XCTAssertLessThan(config.socketPath.utf8.count, 104) }
    func testNamesRejectTraversal() {
        for value in ["", "../x", "a/b", "a b", "A", "x;id", "a\n", String(repeating: "a", count: 21)] { XCTAssertFalse(BoxConfig.validName(value), value) }
    }
    func testSameUIDRejected() { XCTAssertThrowsError(try BoxConfig(name: "demo", username: "ub_demo", hostUID: 501, guestUID: 501).validate()) }
    func testRootRejected() { XCTAssertThrowsError(try BoxConfig(name: "demo", username: "ub_demo", hostUID: 0, guestUID: 502).validate()) }
    func testArbitraryAccountRejected() { XCTAssertThrowsError(try BoxConfig(name: "demo", username: "existing_user", hostUID: 501, guestUID: 502).validate()) }
    func testSessionPasses() throws { try identity.validate(for: config, pinnedSession: 100) }
    func testConsoleSessionRejected() { var id = identity; id.onConsole = true; XCTAssertThrowsError(try id.validate(for: config)) }
    func testConsoleUIDChangesRejected() { var id = identity; id.consoleUID = 502; XCTAssertThrowsError(try id.validate(for: config)) }
    func testThirdUserConsoleRejected() { var id = identity; id.consoleUID = 503; XCTAssertThrowsError(try id.validate(for: config)) }
    func testLoginWindowRejected() { var id = identity; id.consoleUID = 0; XCTAssertThrowsError(try id.validate(for: config)) }
    func testSSHOrBackgroundContextRejected() { var id = identity; id.graphical = false; XCTAssertThrowsError(try id.validate(for: config)) }
    func testIncompleteLoginRejected() { var id = identity; id.loggedIn = false; XCTAssertThrowsError(try id.validate(for: config)) }
    func testSessionUIDMismatchRejected() { var id = identity; id.sessionUID = 501; XCTAssertThrowsError(try id.validate(for: config)) }
    func testProcessUIDMismatchRejected() { var id = identity; id.uid = 501; XCTAssertThrowsError(try id.validate(for: config)) }
    func testChangedSessionRejected() { XCTAssertThrowsError(try identity.validate(for: config, pinnedSession: 101)) }
    func testUnknownProtocolRejected() { var id = identity; id.protocolVersion = 2; XCTAssertThrowsError(try id.validate(for: config)) }
    func testMissingSessionRejected() { var id = identity; id.sessionID = 0; XCTAssertThrowsError(try id.validate(for: config)) }
    func testPointerBounds() {
        for (x, y) in [(Double.nan, 0), (0, Double.infinity), (-0.1, 0), (1.1, 0), (0, -1)] {
            var e = InputEvent(kind: "move"); e.x = x; e.y = y; XCTAssertThrowsError(try e.validate())
        }
    }
    func testPointerAndDragValid() throws { var e = InputEvent(kind: "down"); e.x = 0.5; e.y = 0.2; e.button = 1; e.clicks = 2; try e.validate() }
    func testUnicodeInput() throws { var e = InputEvent(kind: "text"); e.text = "你好 👨‍👩‍👧‍👦 café"; try e.validate() }
    func testOversizeTextRejected() { var e = InputEvent(kind: "text"); e.text = String(repeating: "中", count: 8192); XCTAssertThrowsError(try e.validate()) }
    func testUnknownInputRejected() { XCTAssertThrowsError(try InputEvent(kind: "global_hid").validate()) }
    func testInvalidKeyRejected() { var e = InputEvent(kind: "keyDown"); e.keyCode = 128; XCTAssertThrowsError(try e.validate()) }
    func testScrollBounded() { var e = InputEvent(kind: "scroll"); e.deltaY = Int.max; XCTAssertThrowsError(try e.validate()) }
    func testLeaseRoundTrip() throws {
        var s = LeaseState(); let t = try s.acquire(owner: "a", role: "agent", now: 0)
        try s.require(owner: "a", token: t, now: 1); XCTAssertTrue(s.release(owner: "a"))
        XCTAssertThrowsError(try s.require(owner: "a", token: t, now: 2))
    }
    func testAgentCannotStealLease() throws {
        var s = LeaseState(); _ = try s.acquire(owner: "human", role: "human", now: 0)
        XCTAssertThrowsError(try s.acquire(owner: "agent", role: "agent", now: 1))
    }
    func testHumanTakeoverRevokesPreviousToken() throws {
        var s = LeaseState(); let old = try s.acquire(owner: "agent", role: "agent", now: 0)
        _ = try s.acquire(owner: "human", role: "human", now: 1)
        XCTAssertThrowsError(try s.require(owner: "agent", token: old, now: 2))
    }
    func testWrongConnectionCannotUseToken() throws {
        var s = LeaseState(); let t = try s.acquire(owner: "a", role: "agent", now: 0)
        XCTAssertThrowsError(try s.require(owner: "b", token: t, now: 1))
    }
    func testExpiredLeaseRejected() throws {
        var s = LeaseState(); let t = try s.acquire(owner: "a", role: "agent", now: 0)
        XCTAssertThrowsError(try s.require(owner: "a", token: t, now: 15)); XCTAssertTrue(s.expire(now: 15)); XCTAssertNil(s.owner)
    }
    func testOldOwnerCannotReleaseNewLease() throws {
        var s = LeaseState(); _ = try s.acquire(owner: "a", role: "agent", now: 0)
        _ = try s.acquire(owner: "b", role: "human", now: 1); XCTAssertFalse(s.release(owner: "a")); XCTAssertEqual(s.owner, "b")
    }
    func testFileTraversalRejected() {
        for name in ["../x", "/tmp/x", ".", "..", "a/b", "a\\b", "a:b", "x\n", ""] { XCTAssertThrowsError(try SafeFiles.filename(name)) }
    }
    func testNativeFilename() throws { XCTAssertEqual(try SafeFiles.filename("测试 文件.txt"), "测试 文件.txt") }
    func testFramingLimitsBeforeAllocation() { XCTAssertThrowsError(try Wire.read(-1, count: Int.max, maximum: Wire.maxPayload)); XCTAssertThrowsError(try Wire.read(-1, count: -1, maximum: Wire.maxPayload)) }
    func testWireAndOSPeerCredentials() throws {
        let path = "/tmp/ub-\(UUID().uuidString.prefix(12)).sock"
        let server = ub_listen(path); XCTAssertGreaterThanOrEqual(server, 0)
        guard server >= 0 else { return }
        defer { ub_close(server); try? FileManager.default.removeItem(atPath: path) }
        let connected = expectation(description: "peer")
        DispatchQueue.global().async {
            let fd = ub_accept(server); defer { ub_close(fd) }
            var uid: UInt32 = .max
            XCTAssertEqual(ub_peer_uid(fd, &uid), 0); XCTAssertEqual(uid, ub_uid())
            do { let req = try Wire.receive(Request.self, from: fd); try Wire.send(Reply(id: req.id), to: fd) }
            catch { XCTFail(error.localizedDescription) }
            connected.fulfill()
        }
        let client = ub_connect(path); XCTAssertGreaterThanOrEqual(client, 0); defer { ub_close(client) }
        let request = Request("status"); try Wire.send(request, to: client)
        let reply = try Wire.receive(Reply.self, from: client); XCTAssertEqual(reply.id, request.id)
        wait(for: [connected], timeout: 3)
    }
    func testListenDoesNotDeleteRegularFile() throws {
        let url = URL(fileURLWithPath: "/tmp/ub-file-\(UUID().uuidString)")
        try Data("preserve".utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertLessThan(ub_listen(url.path), 0); XCTAssertEqual(try String(contentsOf: url), "preserve")
    }
}
