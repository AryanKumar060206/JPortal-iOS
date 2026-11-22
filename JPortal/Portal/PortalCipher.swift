import CommonCrypto
import Foundation

/// the portal's clock lives in india, every key and header is built from IST dates
let IST = TimeZone(secondsFromGMT: 5 * 3600 + 30 * 60)!

/// the 7 char date fingerprint baked into every key and LocalName header:
/// d0 m0 y0 weekday d1 m1 y1, weekday js style (sunday = 0), always in IST.
func dateSeq(_ at: Date) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = IST
    let c = cal.dateComponents([.day, .month, .year, .weekday], from: at)
    let dd = Array(String(format: "%02d", c.day ?? 1))
    let mm = Array(String(format: "%02d", c.month ?? 1))
    let yy = Array(String(format: "%02d", (c.year ?? 2000) % 100))
    let weekday = (c.weekday ?? 1) - 1
    return "\(dd[0])\(mm[0])\(yy[0])\(weekday)\(dd[1])\(mm[1])\(yy[1])"
}

/// aes-128-cbc with a key that rotates daily. the iv never changes, yes really.
enum PortalCipher {
    private static let iv = Array("dcek9wb8frty1pnm".utf8)
    private static let alnum = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    private static func key(_ at: Date) -> [UInt8] { Array("qa8y\(dateSeq(at))ty1pn".utf8) }

    private static func crypt(_ op: CCOperation, _ input: [UInt8], at: Date) -> [UInt8]? {
        let key = key(at)
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, input, input.count, &out, out.count, &moved
        )
        guard status == kCCSuccess else { return nil }
        return Array(out.prefix(moved))
    }

    static func encrypt(_ plain: String, at: Date) -> String {
        Data(crypt(CCOperation(kCCEncrypt), Array(plain.utf8), at: at) ?? []).base64EncodedString()
    }

    static func decrypt(_ encoded: String, at: Date) -> String? {
        guard let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
              let plain = crypt(CCOperation(kCCDecrypt), Array(raw), at: at) else { return nil }
        return String(bytes: plain, encoding: .utf8)
    }

    private static func noise(_ n: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<n).map { _ in alnum[Int.random(in: 0..<alnum.count, using: &rng)] })
    }

    /// without it the server answers 200 with an empty body
    static func localName(_ at: Date) -> String { encrypt(noise(4) + dateSeq(at) + noise(5), at: at) }
}
