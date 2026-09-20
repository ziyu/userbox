import XCTest
@testable import UserBoxCore

final class FramebufferTests: XCTestCase {
    // Distinct channels catch partial-pixel copies as well as incorrect row offsets.
    private func pixels(_ values: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        for value in values {
            let pixel: [UInt8] = [value, value | 0x80, value | 0x40, 0xff]
            result.append(contentsOf: pixel)
        }
        return result
    }

    private func makeFrame() throws -> Frame {
        var frame = try Frame(width: 4, height: 4)
        let values: [UInt8] = Array(1...16)
        try frame.raw(x: 0, y: 0, w: 4, h: 4, bytes: pixels(values))
        return frame
    }

    func testCopyUsesFramebufferStrideForMultipleRows() throws {
        var frame = try makeFrame()
        try frame.copy(x: 2, y: 2, w: 2, h: 2, sx: 0, sy: 0)
        XCTAssertEqual(frame.bytes, pixels([
            1, 2, 3, 4,
            5, 6, 7, 8,
            9, 10, 1, 2,
            13, 14, 5, 6,
        ]))
    }

    func testHorizontalOverlapInBothDirections() throws {
        var right = try makeFrame()
        try right.copy(x: 1, y: 0, w: 3, h: 2, sx: 0, sy: 0)
        XCTAssertEqual(right.bytes, pixels([
            1, 1, 2, 3,
            5, 5, 6, 7,
            9, 10, 11, 12,
            13, 14, 15, 16,
        ]))

        var left = try makeFrame()
        try left.copy(x: 0, y: 0, w: 3, h: 2, sx: 1, sy: 0)
        XCTAssertEqual(left.bytes, pixels([
            2, 3, 4, 4,
            6, 7, 8, 8,
            9, 10, 11, 12,
            13, 14, 15, 16,
        ]))
    }

    func testVerticalOverlapInBothDirections() throws {
        var down = try makeFrame()
        try down.copy(x: 0, y: 1, w: 4, h: 3, sx: 0, sy: 0)
        XCTAssertEqual(down.bytes, pixels([
            1, 2, 3, 4,
            1, 2, 3, 4,
            5, 6, 7, 8,
            9, 10, 11, 12,
        ]))

        var up = try makeFrame()
        try up.copy(x: 0, y: 0, w: 4, h: 3, sx: 0, sy: 1)
        XCTAssertEqual(up.bytes, pixels([
            5, 6, 7, 8,
            9, 10, 11, 12,
            13, 14, 15, 16,
            13, 14, 15, 16,
        ]))
    }

    func testTwoDimensionalOverlapInBothDirections() throws {
        var downRight = try makeFrame()
        try downRight.copy(x: 1, y: 1, w: 3, h: 3, sx: 0, sy: 0)
        XCTAssertEqual(downRight.bytes, pixels([
            1, 2, 3, 4,
            5, 1, 2, 3,
            9, 5, 6, 7,
            13, 9, 10, 11,
        ]))

        var upLeft = try makeFrame()
        try upLeft.copy(x: 0, y: 0, w: 3, h: 3, sx: 1, sy: 1)
        XCTAssertEqual(upLeft.bytes, pixels([
            6, 7, 8, 4,
            10, 11, 12, 8,
            14, 15, 16, 12,
            13, 14, 15, 16,
        ]))
    }

    func testCopyToSameRectangleIsUnchanged() throws {
        var frame = try makeFrame()
        let original = frame.bytes
        try frame.copy(x: 1, y: 1, w: 2, h: 2, sx: 1, sy: 1)
        XCTAssertEqual(frame.bytes, original)
        try frame.copy(x: 0, y: 0, w: 4, h: 4, sx: 0, sy: 0)
        XCTAssertEqual(frame.bytes, original)
    }

    func testZeroAreaCopiesAtEdgesAreNoOps() throws {
        var frame = try makeFrame()
        let original = frame.bytes
        try frame.copy(x: 4, y: 0, w: 0, h: 4, sx: 4, sy: 0)
        XCTAssertEqual(frame.bytes, original)
        try frame.copy(x: 0, y: 4, w: 4, h: 0, sx: 0, sy: 4)
        XCTAssertEqual(frame.bytes, original)
        try frame.copy(x: 4, y: 4, w: 0, h: 0, sx: 4, sy: 4)
        XCTAssertEqual(frame.bytes, original)
    }

    func testInvalidCopiesDoNotMutateFramebuffer() throws {
        typealias Rect = (x: Int, y: Int, w: Int, h: Int, sx: Int, sy: Int)
        let invalid: [Rect] = [
            (3, 0, 2, 1, 0, 0), // destination width
            (0, 3, 1, 2, 0, 0), // destination height
            (0, 0, 2, 1, 3, 0), // source width
            (0, 0, 1, 2, 0, 3), // source height
            (-1, 0, 1, 1, 0, 0),
            (0, -1, 1, 1, 0, 0),
            (0, 0, 1, 1, -1, 0),
            (0, 0, 1, 1, 0, -1),
            (0, 0, -1, 1, 0, 0),
            (0, 0, 1, -1, 0, 0),
            (0, 0, Int.max, 1, 0, 0),
            (0, 0, 1, Int.max, 0, 0),
        ]
        for rect in invalid {
            var frame = try makeFrame()
            let original = frame.bytes
            XCTAssertThrowsError(try frame.copy(
                x: rect.x, y: rect.y, w: rect.w, h: rect.h,
                sx: rect.sx, sy: rect.sy
            ))
            XCTAssertEqual(frame.bytes, original)
        }
    }
}
