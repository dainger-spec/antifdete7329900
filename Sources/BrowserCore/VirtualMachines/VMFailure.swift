import Foundation

/// Why a machine did not start, its macOS was not installed, or its state was not kept — as a
/// kind the app has words for in the person's language, with what to do about it.
///
/// The helper knows the error as the system gave it: a sentence in the system's words (shown as a
/// technical detail, as before) and, under it, a domain and a code. The kind is decided here, from
/// those alone, where it is tested: the domains and codes are Apple's — Virtualization's
/// (`VZErrorDomain`), Cocoa's, POSIX's — written as the numbers they are, because this file is
/// compiled where the frameworks are not. An error that is none of these has no kind, and is said
/// in the system's words alone, as it always was.
public enum VMFailureKind: String, Codable, Sendable, CaseIterable {
    /// This Mac's disk is full: a disk, a copy or a saved state could not be written.
    case noRoom
    /// Apple's limit of machines running at once on one Mac — which counts every app's machines,
    /// not Lumen's alone.
    case limit
    /// The machine's disk is not one the framework takes: damaged, or held by another program.
    case disk
    /// Files the machine is made of are missing or cannot be read.
    case files
    /// This machine's macOS does not run as a guest on this Mac as it is (its virtual Mac model is
    /// not supported: this Mac's macOS is older than the machine's).
    case notSupportedHere
    /// The framework refused the machine's hardware as the profile sets it.
    case configuration
    /// The machine has no disk yet, and the base system it is made from is not there.
    case noBase
    /// Apple could not be asked which macOS it offers.
    case catalog
    /// Apple offers no macOS that runs as a guest on this Mac now.
    case nothingOffered
    /// The restore image does not load: not one, damaged, or cut short.
    case image
    /// The restore image's macOS cannot be installed until this Mac's own software is updated.
    case needsUpdate
    /// The installation did not finish.
    case installation

    /// One error of a chain: its domain and code.
    public struct Cause: Equatable, Sendable {
        public var domain: String
        public var code: Int

        public init(domain: String, code: Int) {
            self.domain = domain
            self.code = code
        }
    }

    public static let virtualizationDomain = "VZErrorDomain"
    public static let cocoaDomain = "NSCocoaErrorDomain"
    public static let posixDomain = "NSPOSIXErrorDomain"

    /// The kind of one error by its domain and code; nil for one the app has no words for.
    public init?(domain: String, code: Int) {
        switch (domain, code) {
        // Virtualization (VZError.Code): invalid configuration 2, invalid disk image 5, the limit
        // of machines 6, out of disk space 8, not supported 10; the installation's: the catalog
        // 10001 and 10002, nothing offered 10003, the image 10004 and 10005, an update needed
        // 10006, the installation failed 10007.
        case (Self.virtualizationDomain, 2): self = .configuration
        case (Self.virtualizationDomain, 5): self = .disk
        case (Self.virtualizationDomain, 6): self = .limit
        case (Self.virtualizationDomain, 8): self = .noRoom
        case (Self.virtualizationDomain, 10): self = .notSupportedHere
        case (Self.virtualizationDomain, 10001), (Self.virtualizationDomain, 10002): self = .catalog
        case (Self.virtualizationDomain, 10003): self = .nothingOffered
        case (Self.virtualizationDomain, 10004), (Self.virtualizationDomain, 10005): self = .image
        case (Self.virtualizationDomain, 10006): self = .needsUpdate
        case (Self.virtualizationDomain, 10007): self = .installation
        // Cocoa: no such file 4 and 260, no permission 257 and 513, out of space 640.
        case (Self.cocoaDomain, 640): self = .noRoom
        case (Self.cocoaDomain, 4), (Self.cocoaDomain, 260), (Self.cocoaDomain, 257), (Self.cocoaDomain, 513): self = .files
        // POSIX: ENOSPC 28 and EDQUOT 69; ENOENT 2, EACCES 13, EPERM 1.
        case (Self.posixDomain, 28), (Self.posixDomain, 69): self = .noRoom
        case (Self.posixDomain, 2), (Self.posixDomain, 13), (Self.posixDomain, 1): self = .files
        default: return nil
        }
    }

    /// The kind of an error with those under it, the outermost first. A full disk anywhere in the
    /// chain is the reason, whatever the error over it says ("the installation failed", "the
    /// state was not saved"); otherwise the first error the app has words for.
    public static func of(_ chain: [Cause]) -> VMFailureKind? {
        let kinds = chain.compactMap { VMFailureKind(domain: $0.domain, code: $0.code) }
        return kinds.contains(.noRoom) ? .noRoom : kinds.first
    }

    /// The kind of an error as the helper has it: its own (`VMFailure`), or the system's by its
    /// domain and code and those of the errors under it.
    public static func of(_ error: Error) -> VMFailureKind? {
        if let own = error as? VMFailure { return own.kind }
        return of(causes(of: error))
    }

    /// The error's domain and code, then those of the errors under it (`NSUnderlyingErrorKey`), at
    /// most six deep.
    public static func causes(of error: Error) -> [Cause] {
        var chain: [Cause] = []
        var next: NSError? = error as NSError
        while let current = next, chain.count < 6 {
            chain.append(Cause(domain: current.domain, code: current.code))
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }
}

/// A failure the helper names itself: its kind, and its own words for the log and for the
/// technical detail under the app's.
public struct VMFailure: LocalizedError, Equatable, Sendable {
    public var kind: VMFailureKind
    public var message: String

    public init(_ kind: VMFailureKind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// What stands in the way of starting a machine on a Mac whose disk is nearly full, known before
/// the machine is started (`VMCenter.start`).
public enum VMStartRoom {
    /// The least free room a machine is started with. Its macOS writes from its first second —
    /// swap, caches, logs — to a disk that is a file on this Mac's, and this Mac's own memory for
    /// the machine is backed by the same disk; writes that fail because the disk is full are a
    /// disk that fails, to the macOS in the machine.
    public static let floorBytes: Int64 = 2 * VMRequirements.gibibyte

    public enum Problem: Equatable, Sendable {
        /// Less than `floorBytes` is free.
        case full(needed: Int64, free: Int64)
        /// The machine is not made yet, and the volume cannot clone a file: its disk is then a
        /// whole copy of the base's — `needed` with the floor — for which there is no room.
        case copy(needed: Int64, free: Int64)
    }

    /// `free`: the room on the library's volume, nil when the system does not say (nothing is
    /// then refused). `isMade`: the machine has its disk. `volumeClones`: the volume clones files
    /// (APFS); nil when the system does not say, taken as it does. `baseDiskBytes`: what the
    /// base's disk takes — what a whole copy of it would.
    public static func problem(free: Int64?, isMade: Bool, volumeClones: Bool?, baseDiskBytes: Int64) -> Problem? {
        guard let free else { return nil }
        if !isMade, volumeClones == false {
            let needed = max(0, baseDiskBytes) + floorBytes
            if free < needed { return .copy(needed: needed, free: free) }
        }
        return free < floorBytes ? .full(needed: floorBytes, free: free) : nil
    }
}
