import Foundation
import CommonCrypto
import zlib

// MARK: - CRC-32

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        return c
    }

    /// Continue a standard CRC-32. Start with `crc = 0`. Uses zlib, which has a hardware-accelerated
    /// CRC on Apple chips (the old table loop ran byte by byte).
    static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        guard var p = bytes.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return crc }
        var c = uLong(crc)
        var left = bytes.count
        while left > 0 {
            let n = min(left, Int(UInt32.max >> 1))
            c = zlib.crc32(c, p, uInt(n))
            p += n; left -= n
        }
        return UInt32(truncatingIfNeeded: c)
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        Array(bytes).withUnsafeBytes { update(0, $0) }
    }
}

// MARK: - Decryptors

protocol Decryptor: AnyObject {
    /// Decrypts in place. Called with consecutive pieces of the payload.
    func decrypt(_ buf: inout [UInt8])
}

/// Traditional PKWARE encryption ("ZipCrypto").
final class ZipCryptoDecryptor: Decryptor {
    private var k0: UInt32 = 0x1234_5678
    private var k1: UInt32 = 0x2345_6789
    private var k2: UInt32 = 0x3456_7890

    /// `header` is the 12-byte encryption header; `check` is the expected value of its last byte.
    init(password: [UInt8], header: [UInt8], check: UInt8) throws {
        for b in password { update(b) }
        var h = header
        decrypt(&h)
        guard h[11] == check else { throw UnpackError.wrongPassword }
    }

    private func update(_ b: UInt8) {
        CRC32.table.withUnsafeBufferPointer { t in
            k0 = t[Int((k0 ^ UInt32(b)) & 0xFF)] ^ (k0 >> 8)
            k1 = (k1 &+ (k0 & 0xFF)) &* 134_775_813 &+ 1
            k2 = t[Int((k2 ^ (k1 >> 24)) & 0xFF)] ^ (k2 >> 8)
        }
    }

    /// Hot loop: keys in locals, raw pointers, no per-byte array copies or bounds checks.
    /// (The old loop fetched the CRC table array once per byte, which retained/released it every byte.)
    func decrypt(_ buf: inout [UInt8]) {
        var a = k0, b = k1, c = k2
        CRC32.table.withUnsafeBufferPointer { tb in
            let t = tb.baseAddress!
            buf.withUnsafeMutableBufferPointer { bp in
                guard let p = bp.baseAddress else { return }
                for i in 0..<bp.count {
                    let s = c | 2
                    let plain = p[i] ^ UInt8(truncatingIfNeeded: (s &* (s ^ 1)) >> 8)
                    a = t[Int((a ^ UInt32(plain)) & 0xFF)] ^ (a >> 8)
                    b = (b &+ (a & 0xFF)) &* 134_775_813 &+ 1
                    c = t[Int((c ^ (b >> 24)) & 0xFF)] ^ (c >> 8)
                    p[i] = plain
                }
            }
        }
        k0 = a; k1 = b; k2 = c
    }
}

/// WinZip AES (AE-1 / AE-2): PBKDF2-HMAC-SHA1 (1000 rounds), AES-CTR with a
/// little-endian counter starting at 1, HMAC-SHA1 over the ciphertext.
final class WinZipAESDecryptor: Decryptor {
    static func saltLength(strength: UInt8) -> Int? { [1: 8, 2: 12, 3: 16][strength] }
    static func keyLength(strength: UInt8) -> Int? { [1: 16, 2: 24, 3: 32][strength] }

    private var cryptor: CCCryptorRef?
    private var hmac = CCHmacContext()
    private var counter: UInt64 = 0
    private var keystream = [UInt8](repeating: 0, count: 16)
    private var ksPos = 16

    init(password: [UInt8], salt: [UInt8], verifier: [UInt8], keyLength: Int) throws {
        var derived = [UInt8](repeating: 0, count: 2 * keyLength + 2)
        let status = password.withUnsafeBytes { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000,
                &derived, derived.count)
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw UnpackError.corrupt("key derivation failed") }
        guard Array(derived[(2 * keyLength)...]) == verifier else { throw UnpackError.wrongPassword }

        let encKey = Array(derived[0..<keyLength])
        let macKey = Array(derived[keyLength..<(2 * keyLength)])
        let cs = CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                 CCOptions(kCCOptionECBMode), encKey, keyLength, nil, &cryptor)
        guard cs == CCCryptorStatus(kCCSuccess) else { throw UnpackError.corrupt("AES setup failed") }
        CCHmacInit(&hmac, CCHmacAlgorithm(kCCHmacAlgSHA1), macKey, keyLength)
    }

    deinit { if let c = cryptor { CCCryptorRelease(c) } }

    /// Encrypt `blocks` consecutive counter values into `out`.
    private func makeKeystream(blocks: Int, into out: inout [UInt8]) {
        var ctr = [UInt8](repeating: 0, count: blocks * 16)
        var c = counter
        ctr.withUnsafeMutableBytes { p in
            for b in 0..<blocks {
                c &+= 1
                p.storeBytes(of: c.littleEndian, toByteOffset: b * 16, as: UInt64.self)
            }
        }
        counter = c
        let n = blocks * 16
        out = [UInt8](repeating: 0, count: n)
        var moved = 0
        CCCryptorUpdate(cryptor, ctr, n, &out, n, &moved)
    }

    func decrypt(_ buf: inout [UInt8]) {
        CCHmacUpdate(&hmac, buf, buf.count)
        var i = 0
        // Use up keystream left from the previous call.
        while i < buf.count && ksPos < 16 {
            buf[i] ^= keystream[ksPos]; i += 1; ksPos += 1
        }
        // Whole blocks in one AES call.
        let full = (buf.count - i) / 16
        if full > 0 {
            var ks = [UInt8]()
            makeKeystream(blocks: full, into: &ks)
            let start = i
            buf.withUnsafeMutableBytes { bp in
                ks.withUnsafeBytes { kp in
                    // 8 bytes at a time instead of one.
                    let words = full * 2
                    for w in 0..<words {
                        let o = start + w * 8
                        let x = bp.loadUnaligned(fromByteOffset: o, as: UInt64.self)
                            ^ kp.loadUnaligned(fromByteOffset: w * 8, as: UInt64.self)
                        bp.storeBytes(of: x, toByteOffset: o, as: UInt64.self)
                    }
                }
            }
            i += full * 16
        }
        // Partial tail block; keep the rest for next time.
        if i < buf.count {
            makeKeystream(blocks: 1, into: &keystream)
            ksPos = 0
            while i < buf.count { buf[i] ^= keystream[ksPos]; i += 1; ksPos += 1 }
        }
    }

    /// First 10 bytes of the HMAC, to compare against the stored authentication code.
    func authCode() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CCHmacFinal(&hmac, &out)
        return Array(out[0..<10])
    }
}
