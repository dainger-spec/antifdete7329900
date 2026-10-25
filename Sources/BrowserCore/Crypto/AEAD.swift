#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Authenticated encryption used for every small encrypted object on disk
/// (vault key wrap, profile index, profile configuration, password vault, sync envelopes).
///
/// AES-256-GCM with a random 96-bit nonce. Output is the CryptoKit "combined"
/// representation: `nonce (12) || ciphertext || tag (16)`.
///
/// Every call site passes associated data (AAD) that binds the ciphertext to its
/// purpose and owner (e.g. `"profile-config:v1:<uuid>"`), so a ciphertext copied
/// from one file/profile into another fails authentication instead of decrypting.
public enum AEAD {
    public static func seal(_ plaintext: Data, key: SymmetricKey, aad: String) throws -> Data {
        do {
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(aad.utf8))
            // `combined` is only nil for non-standard nonce sizes; we always use the default 12 bytes.
            guard let combined = box.combined else { throw CoreError.cryptoFailure("AES-GCM combined representation unavailable") }
            return combined
        } catch let error as CoreError {
            throw error
        } catch {
            throw CoreError.cryptoFailure("seal failed: \(error)")
        }
    }

    public static func open(_ combined: Data, key: SymmetricKey, aad: String) throws -> Data {
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw CoreError.corruptData("malformed AES-GCM box")
        }
        do {
            return try AES.GCM.open(box, using: key, authenticating: Data(aad.utf8))
        } catch {
            // Wrong key, wrong AAD, or tampered ciphertext — indistinguishable by design.
            throw CoreError.authenticationFailed
        }
    }
}

/// Cryptographically secure random bytes.
/// `SystemRandomNumberGenerator` is backed by arc4random_buf on Apple platforms
/// and getrandom(2) on Linux; both are CSPRNGs.
public func secureRandomBytes(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    var bytes = Data(count: count)
    for index in 0..<count {
        bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
    }
    return bytes
}

extension SymmetricKey {
    /// Raw key bytes. Only used for key wrapping; never logged or persisted unencrypted.
    var rawBytes: Data {
        withUnsafeBytes { Data($0) }
    }

    /// HKDF-SHA256 subkey derivation. `info` names the purpose so that keys for
    /// different purposes are cryptographically independent.
    func derive(info: String, salt: Data = Data()) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: self, salt: salt, info: Data(info.utf8), outputByteCount: 32)
    }
}

// NOTE (platform limitation): Swift/CryptoKit provide no API to reliably zero key
// material in memory. `SymmetricKey` is backed by heap storage that is released
// (but not guaranteed to be overwritten) when the last reference goes away. The
// at-rest guarantees in this project are about data on disk; an attacker who can
// read the memory of the running, unlocked process can recover keys.
