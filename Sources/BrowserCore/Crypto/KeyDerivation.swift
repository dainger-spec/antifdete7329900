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
/// Stored in plaintext in `vault.json` (salt and costs are not secret).
public struct KDFParameters: Codable, Equatable, Sendable {
    public var algorithm: String
    /// PBKDF2: iterations. Argon2id: passes over the memory (t).
    public var iterations: Int
    public var salt: Data
    /// Argon2id only: memory in KiB (m) and lanes (p). Absent for PBKDF2, so a PBKDF2 header
    /// encodes exactly as before Argon2id.
    public var memoryKiB: Int?
    public var parallelism: Int?

    public static let pbkdf2SHA256 = "pbkdf2-hmac-sha256"
    public static let argon2id = "argon2id"

    /// OWASP (2023) recommendation for PBKDF2-HMAC-SHA256 (vaults from before Argon2id).
    public static let recommendedIterations = 600_000

    /// New vaults and password changes: Argon2id with RFC 9106's second recommended option —
    /// 64 MiB, 3 passes, 4 lanes (a fraction of a second on a Mac).
    public static func recommended() -> KDFParameters {
        argon2idParameters(memoryKiB: 64 * 1024, passes: 3, lanes: 4)
    }

    public static func argon2idParameters(memoryKiB: Int, passes: Int, lanes: Int) -> KDFParameters {
        KDFParameters(algorithm: argon2id, iterations: passes, salt: secureRandomBytes(16),
                      memoryKiB: memoryKiB, parallelism: lanes)
    }

    /// PBKDF2-HMAC-SHA256: vaults from before Argon2id, and fast vaults for tests.
    public static func generate(iterations: Int = recommendedIterations) -> KDFParameters {
        KDFParameters(algorithm: pbkdf2SHA256, iterations: iterations, salt: secureRandomBytes(16))
    }

    public var isMemoryHard: Bool { algorithm == Self.argon2id }
}

/// Password → key derivation: Argon2id (memory-hard, `Argon2.swift`) for vaults created or
/// re-keyed by this version; PBKDF2-HMAC-SHA256 (CommonCrypto) for older ones, which the app
/// re-wraps under Argon2id the next time they are unlocked (`UnlockedVault.upgradeKDFIfNeeded`).
/// CryptoKit has no password KDF, and PBKDF2 is the only one in the macOS SDK; it is not
/// memory-hard, so a GPU tries far more PBKDF2 guesses per second than Argon2id ones.
public enum KeyDerivation {
    /// Upper bounds for a header's Argon2id costs: a header (also one fetched for sync) cannot
    /// make the app allocate more than 2 GiB (RFC 9106's first recommended option) or loop for long.
    static let maximumMemoryKiB = 2 * 1024 * 1024
    static let maximumPasses = 10
    static let maximumLanes = 16

    public static func deriveKey(password: String, parameters: KDFParameters) throws -> SymmetricKey {
        guard parameters.salt.count >= 16 else { throw CoreError.invalidConfiguration("weak KDF parameters") }
        // Normalise so the same password typed via different input methods
        // (composed vs decomposed Unicode) derives the same key.
        var passwordBytes = [UInt8](password.precomposedStringWithCanonicalMapping.utf8)
        defer { wipe(&passwordBytes) }
        var derived: [UInt8]
        switch parameters.algorithm {
        case KDFParameters.argon2id:
            guard let memory = parameters.memoryKiB, let lanes = parameters.parallelism,
                  (1...maximumPasses).contains(parameters.iterations), (1...maximumLanes).contains(lanes),
                  (8 * lanes...maximumMemoryKiB).contains(memory) else {
                throw CoreError.invalidConfiguration("Argon2id parameters out of range")
            }
            derived = Argon2id.hash(password: passwordBytes, salt: [UInt8](parameters.salt), passes: parameters.iterations,
                                    memoryKiB: memory, lanes: lanes, tagLength: 32)
        case KDFParameters.pbkdf2SHA256:
            guard parameters.iterations >= 1 else { throw CoreError.invalidConfiguration("weak KDF parameters") }
            var passwordData = Data(passwordBytes)
            defer { wipe(&passwordData) }
            var key = try pbkdf2SHA256(password: passwordData, salt: parameters.salt,
                                       iterations: parameters.iterations, keyLength: 32)
            derived = [UInt8](key)
            wipe(&key)
        default:
            throw CoreError.unsupportedFormat("KDF \(parameters.algorithm)")
        }
        defer { wipe(&derived) }
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
