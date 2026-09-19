import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Little-endian limbs. Used ONLY for the legacy ARD wire handshake on loopback.
// Not a general-purpose or constant-time cryptography implementation.
public struct BigNat: Equatable, Comparable {
    var limbs: [UInt32]
    public init(_ bytes: [UInt8]) {
        limbs = []; var word: UInt32 = 0; var shift = 0
        for b in bytes.reversed() { word |= UInt32(b) << shift; shift += 8
            if shift == 32 { limbs.append(word); word = 0; shift = 0 }
        }
        if shift > 0 { limbs.append(word) }; normalize()
    }
    public init(_ value: UInt32) { limbs = value == 0 ? [] : [value] }
    init(limbs: [UInt32]) { self.limbs = limbs; normalize() }
    mutating func normalize() { while limbs.last == 0 { limbs.removeLast() } }
    public static func < (a: Self, b: Self) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for i in a.limbs.indices.reversed() { if a.limbs[i] != b.limbs[i] { return a.limbs[i] < b.limbs[i] } }
        return false
    }
    func subtract(_ other: Self) -> Self {
        precondition(self >= other); var out = limbs; var borrow: UInt64 = 0
        for i in out.indices {
            let rhs = UInt64(i < other.limbs.count ? other.limbs[i] : 0) + borrow
            let lhs = UInt64(out[i]); out[i] = UInt32(truncatingIfNeeded: lhs &- rhs); borrow = lhs < rhs ? 1 : 0
        }; return Self(limbs: out)
    }
    func addMod(_ b: Self, _ modulus: Self) -> Self {
        var out = [UInt32](); var carry: UInt64 = 0
        for i in 0..<max(limbs.count, b.limbs.count) {
            let sum = UInt64(i < limbs.count ? limbs[i] : 0) + UInt64(i < b.limbs.count ? b.limbs[i] : 0) + carry
            out.append(UInt32(truncatingIfNeeded: sum)); carry = sum >> 32
        }
        if carry > 0 { out.append(UInt32(carry)) }; let sum = Self(limbs: out)
        return sum >= modulus ? sum.subtract(modulus) : sum
    }
    func timesMod(_ b: Self, _ modulus: Self) -> Self {
        var result = Self(0); var current = self
        for word in b.limbs { for bit in 0..<32 {
            if word & (UInt32(1) << bit) != 0 { result = result.addMod(current, modulus) }
            current = current.addMod(current, modulus)
        }}; return result
    }
    public func power(_ exponent: [UInt8], modulus: Self) throws -> Self {
        guard modulus > Self(2), self < modulus else { throw UBError("Invalid DH parameters") }
        var result = Self(1)
        for byte in exponent { for bit in (0..<8).reversed() {
            result = result.timesMod(result, modulus)
            if byte & (UInt8(1) << bit) != 0 { result = result.timesMod(self, modulus) }
        }}; return result
    }
    public func bytes(count: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        for w in limbs { out += [UInt8(truncatingIfNeeded: w), UInt8(truncatingIfNeeded: w >> 8), UInt8(truncatingIfNeeded: w >> 16), UInt8(truncatingIfNeeded: w >> 24)] }
        while out.last == 0 { out.removeLast() }
        guard out.count <= count else { throw UBError("DH integer overflow") }
        return Array(repeating: 0, count: count - out.count) + out.reversed()
    }
}
public enum ARD {
    public static func credentials(username: String, password: String, random: [UInt8]) throws -> [UInt8] {
        let u = Array(username.utf8), p = Array(password.utf8)
        guard !u.isEmpty, !p.isEmpty, u.count <= 63, p.count <= 63, !u.contains(0), !p.contains(0), random.count == 128 else {
            throw UBError("ARD requires a non-empty username/password of at most 63 UTF-8 bytes")
        }
        var output = random; output.replaceSubrange(0..<u.count, with: u); output[u.count] = 0
        output.replaceSubrange(64..<(64+p.count), with: p); output[64+p.count] = 0; return output
    }
}
