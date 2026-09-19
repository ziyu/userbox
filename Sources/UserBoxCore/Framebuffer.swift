import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct Frame {
    public var width: Int; public var height: Int; public var bytes: [UInt8]
    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192, width*height <= 16_777_216 else { throw UBError("Invalid desktop dimensions") }
        self.width = width; self.height = height; self.bytes = Array(repeating: 0, count: width*height*4)
    }
    public mutating func raw(x: Int, y: Int, w: Int, h: Int, bytes incoming: [UInt8]) throws {
        try bounds(x,y,w,h); guard incoming.count == w*h*4 else { throw UBError("Invalid rectangle payload") }
        for row in 0..<h { let dst = ((y+row)*width+x)*4; let src = row*w*4; bytes.replaceSubrange(dst..<(dst+w*4), with: incoming[src..<(src+w*4)]) }
    }
    public mutating func copy(x: Int, y: Int, w: Int, h: Int, sx: Int, sy: Int) throws {
        try bounds(x,y,w,h); try bounds(sx,sy,w,h)
        var source: [UInt8] = []; source.reserveCapacity(w*h*4)
        for row in 0..<h { source += bytes[((sy+row)*width+sx)*4..<((sy+row)*width+sx+w)*4] }
        try raw(x:x,y:y,w:w,h:h,bytes:source)
    }
    public func bounds(_ x: Int,_ y: Int,_ w: Int,_ h: Int) throws {
        guard x >= 0,y >= 0,w >= 0,h >= 0,x <= width,y <= height,w <= width-x,h <= height-y else { throw UBError("Rectangle exceeds framebuffer") }
    }
    public static func point(x: Double,y: Double,viewW: Double,viewH: Double,frameW: Int,frameH: Int) -> (Int,Int)? {
        guard viewW > 0,viewH > 0,viewW.isFinite,viewH.isFinite,frameW > 0,frameH > 0,x.isFinite,y.isFinite else { return nil }
        let scale = min(viewW/Double(frameW),viewH/Double(frameH))
        let px = (x-(viewW-Double(frameW)*scale)/2)/scale, py = (y-(viewH-Double(frameH)*scale)/2)/scale
        guard px >= 0,py >= 0,px < Double(frameW),py < Double(frameH) else { return nil }; return (Int(px),Int(py))
    }
}
public enum Marker {
    public static let cells = 8, cell = 6, inset = 18, side = 48
    // The nonce is 32 random bytes encoded as hex. Eight-by-eight independent RGB cells.
    public static func colors(_ nonce: String, corner: Int) -> [(UInt8,UInt8,UInt8)] {
        var state: UInt64 = 14695981039346656037
        for b in nonce.utf8 { state = (state ^ UInt64(b)) &* 1099511628211 }; state ^= UInt64(corner+1)
        return (0..<64).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return (UInt8(40+state%176),UInt8(40+(state >> 8)%176),UInt8(40+(state >> 16)%176))
        }
    }
    public static func matches(_ frame: Frame, witness: Witness) -> Bool {
        // Check exact two-corner geometry, not a marker anywhere in an image. This
        // prevents an ordinary host window containing an old Box image from passing.
        guard witness.width > 0,witness.height > 0,frame.width % witness.width == 0, frame.height % witness.height == 0 else { return false }
        let s = frame.width / witness.width
        guard (1...3).contains(s),frame.height / witness.height == s else { return false }
        for corner in 0..<2 {
            let colors = colors(witness.nonce,corner:corner)
            let ox = corner == 0 ? inset : witness.width-inset-side
            let oy = corner == 0 ? inset : witness.height-inset-side
            for i in 0..<64 {
                let x = (ox+(i%8)*cell+cell/2)*s, y = (oy+(i/8)*cell+cell/2)*s
                guard x >= 0,y >= 0,x < frame.width,y < frame.height else { return false }
                let p = (y*frame.width+x)*4; let c = colors[i]
                if abs(Int(frame.bytes[p+2])-Int(c.0)) > 12 || abs(Int(frame.bytes[p+1])-Int(c.1)) > 12 || abs(Int(frame.bytes[p])-Int(c.2)) > 12 { return false }
            }
        }; return true
    }
}

