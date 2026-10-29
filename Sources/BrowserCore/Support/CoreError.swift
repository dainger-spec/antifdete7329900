import Foundation

public enum CoreError: Error, Equatable, CustomStringConvertible {
    /// AEAD authentication failed: wrong key/password, wrong AAD, or tampering.
    case authenticationFailed
    case wrongPassword
    case vaultAlreadyExists
    case vaultNotFound
    case corruptData(String)
    case cryptoFailure(String)
    case invalidConfiguration(String)
    case profileNotFound(UUID)
    case unsupportedFormat(String)
    /// A file a newer version of the app wrote: `what` declares format `found` (nil: not a number
    /// this version understands), this version reads up to `supported`. Nothing was read from it,
    /// and nothing is written over it (docs/UPDATES.md §4).
    case newerFormat(what: String, found: Int?, supported: Int)
    case unsafeArchivePath(String)
    case syncConflict(objectID: String, remoteRevision: Int)
    /// The sync server answered with an unexpected HTTP status (401/403 = bad token).
    case syncServer(status: Int, message: String)
    case io(String)
    /// Asked of a vault opened for one profile only (`ProfileGrant`, in that profile's own
    /// process): what is named needs the whole vault.
    case notGranted(String)

    public var description: String {
        switch self {
        case .authenticationFailed: return "Authentication failed (wrong key or data was modified)"
        case .wrongPassword: return "Wrong master password"
        case .vaultAlreadyExists: return "A vault already exists at this location"
        case .vaultNotFound: return "No vault found"
        case .corruptData(let detail): return "Corrupt data: \(detail)"
        case .cryptoFailure(let detail): return "Crypto failure: \(detail)"
        case .invalidConfiguration(let detail): return "Invalid configuration: \(detail)"
        case .profileNotFound(let id): return "Profile not found: \(id)"
        case .unsupportedFormat(let detail): return "Unsupported format: \(detail)"
        case .newerFormat(let what, let found, let supported):
            return "\(what) was written by a newer version of PrivacyBrowser (format \(found.map(String.init) ?? "unknown"), "
                + "this version reads up to \(supported)); nothing was read from it or written over it"
        case .unsafeArchivePath(let path): return "Archive contains unsafe path: \(path)"
        case .syncConflict(let objectID, let revision): return "Sync conflict on \(objectID) (remote revision \(revision))"
        case .syncServer(let status, let message):
            return "Sync server error \(status)\(message.isEmpty ? "" : ": \(message)")"
        case .io(let detail): return "I/O error: \(detail)"
        case .notGranted(let detail): return "Not available to a single profile's process: \(detail)"
        }
    }
}

extension CoreError: LocalizedError {
    public var errorDescription: String? { description }
}
