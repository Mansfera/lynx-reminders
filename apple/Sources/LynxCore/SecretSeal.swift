import CommonCrypto
import CryptoKit
import Foundation

/// A secret sealed with a PIN on the device, as the server stores it (SPEC §7b). The server never sees the PIN or
/// the secret. Same format on Android (`SecretSeal.kt`); `shared/vectors/secret-seal.json` checks both.
public struct SealedSecret: Codable, Equatable, Sendable {
    public var v: Int
    public var kdf: String
    public var iter: Int
    public var salt: String
    public var nonce: String
    /// AES-GCM ciphertext followed by the 16-byte tag, base64.
    public var box: String

    public init(v: Int = 1, kdf: String = "pbkdf2-sha256", iter: Int, salt: String, nonce: String, box: String) {
        self.v = v
        self.kdf = kdf
        self.iter = iter
        self.salt = salt
        self.nonce = nonce
        self.box = box
    }
}

/// PBKDF2-HMAC-SHA256(NFC(PIN), 16-byte salt, 600 000 rounds) → AES-256-GCM over the secret, with `context`
/// (`lynx/claude-key/v1/<user id>`) as associated data so a blob can't be moved to another account.
public enum SecretSeal {
    public static let iterations = 600_000
    /// PINs and passphrases shorter than this are refused.
    public static let minimumPINLength = 6

    public enum Failure: LocalizedError, Equatable {
        case wrongPIN
        case unsupported
        case shortPIN

        public var errorDescription: String? {
            switch self {
            case .wrongPIN: "That PIN doesn't unlock the key."
            case .unsupported: "This key was synced by a newer version of Lynx."
            case .shortPIN: "Use at least \(SecretSeal.minimumPINLength) characters."
            }
        }
    }

    public static func contextForClaudeKey(user: UUID) -> String { "lynx/claude-key/v1/\(user.uuidString.lowercased())" }

    public static func seal(_ secret: String, pin: String, context: String, iterations: Int = iterations,
                            salt: Data? = nil, nonce: Data? = nil) throws -> SealedSecret {
        guard pin.count >= minimumPINLength else { throw Failure.shortPIN }
        let salt = salt ?? random(16)
        let key = derive(pin, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(Data(secret.utf8), using: key, nonce: AES.GCM.Nonce(data: nonce ?? random(12)),
                                      authenticating: Data(context.utf8))
        return SealedSecret(iter: iterations, salt: salt.base64EncodedString(),
                            nonce: Data(sealed.nonce).base64EncodedString(),
                            box: (sealed.ciphertext + sealed.tag).base64EncodedString())
    }

    public static func open(_ s: SealedSecret, pin: String, context: String) throws -> String {
        guard s.v == 1, s.kdf == "pbkdf2-sha256", s.iter > 0, s.iter <= 10_000_000,
              let salt = Data(base64Encoded: s.salt), let nonce = Data(base64Encoded: s.nonce),
              let box = Data(base64Encoded: s.box), box.count >= 16 else { throw Failure.unsupported }
        let key = derive(pin, salt: salt, iterations: s.iter)
        do {
            let sb = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: box.dropLast(16), tag: box.suffix(16))
            let plain = try AES.GCM.open(sb, using: key, authenticating: Data(context.utf8))
            guard let text = String(data: plain, encoding: .utf8) else { throw Failure.wrongPIN }
            return text
        } catch {
            throw Failure.wrongPIN
        }
    }

    static func derive(_ pin: String, salt: Data, iterations: Int) -> SymmetricKey {
        SymmetricKey(data: pbkdf2(Data(pin.precomposedStringWithCanonicalMapping.utf8), salt: salt, iterations: iterations))
    }

    static func pbkdf2(_ password: Data, salt: Data, iterations: Int, length: Int = 32) -> Data {
        var out = Data(count: length)
        _ = out.withUnsafeMutableBytes { o in
            password.withUnsafeBytes { p in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         p.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         o.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        return out
    }

    static func random(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
    }
}
