#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif
import Foundation

/// Parameters needed to re-derive the key-encryption key from the master password.
/// Stored in plaintext in `vault.json` (salt and iteration count are not secret).
public struct KDFParameters: Codable, Equatable, Sendable {
    public var algorithm: String
    public var iterations: Int
    public var salt: Data

    public static let pbkdf2SHA256 = "pbkdf2-hmac-sha256"

    /// OWASP (2023) recommendation for PBKDF2-HMAC-SHA256.
    public static let recommendedIterations = 600_000

    public static func generate(iterations: Int = recommendedIterations) -> KDFParameters {
        KDFParameters(algorithm: pbkdf2SHA256, iterations: iterations, salt: secureRandomBytes(16))
    }
}

/// Password → key derivation.
///
/// LIMITATION: CryptoKit offers no password-hashing function. PBKDF2 (CommonCrypto) is the only
/// password KDF in the macOS SDK; it is not memory-hard. A memory-hard KDF (Argon2id / scrypt) would be preferable
/// against GPU attackers and can be swapped in behind `KDFParameters.algorithm`
/// (e.g. via libsodium) without changing the vault format.
public enum KeyDerivation {
    public static func deriveKey(password: String, parameters: KDFParameters) throws -> SymmetricKey {
        guard parameters.algorithm == KDFParameters.pbkdf2SHA256 else {
            throw CoreError.unsupportedFormat("KDF \(parameters.algorithm)")
        }
        guard parameters.iterations >= 1, parameters.salt.count >= 16 else {
            throw CoreError.invalidConfiguration("weak KDF parameters")
        }
        // Normalise so the same password typed via different input methods
        // (composed vs decomposed Unicode) derives the same key.
        let passwordBytes = Data(password.precomposedStringWithCanonicalMapping.utf8)
        let derived = try pbkdf2SHA256(password: passwordBytes, salt: parameters.salt,
                                       iterations: parameters.iterations, keyLength: 32)
        return SymmetricKey(data: derived)
    }

    static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyLength: Int) throws -> Data {
        #if canImport(CommonCrypto)
        var derived = Data(count: keyLength)
        let status: Int32 = derived.withUnsafeMutableBytes { derivedPtr in
            password.withUnsafeBytes { passwordPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength)
                }
            }
        }
        guard status == kCCSuccess else { throw CoreError.cryptoFailure("PBKDF2 status \(status)") }
        return derived
        #else
        return portablePBKDF2SHA256(password: password, salt: salt, iterations: iterations, keyLength: keyLength)
        #endif
    }

    /// RFC 8018 PBKDF2 on top of HMAC-SHA256. Used where CommonCrypto is unavailable
    /// (Linux CI). Produces identical output to CommonCrypto (verified against RFC 7914 §11 vectors in tests).
    static func portablePBKDF2SHA256(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let key = SymmetricKey(data: password)
        var output = Data()
        var blockIndex: UInt32 = 1
        while output.count < keyLength {
            var saltAndIndex = salt
            withUnsafeBytes(of: blockIndex.bigEndian) { saltAndIndex.append(contentsOf: $0) }
            var u = Data(HMAC<SHA256>.authenticationCode(for: saltAndIndex, using: key))
            var block = [UInt8](u)
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for (i, byte) in u.enumerated() { block[i] ^= byte }
                }
            }
            output.append(contentsOf: block)
            blockIndex += 1
        }
        return output.prefix(keyLength)
    }
}
