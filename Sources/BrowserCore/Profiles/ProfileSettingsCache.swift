import Foundation

extension ProfileRepository {
    /// What tells one stored version of a profile's settings (`config.bin`) from another without
    /// reading it: the file's volume and number, its size, and when it was last written. Every write
    /// of the file puts a new file in its place (`SecureFile.write`: a temporary file renamed over
    /// it) — here, in the profile's own process, by sync, by a kept version chosen — with a number
    /// of its own (APFS never gives a file a number another had) and a later time.
    public struct SettingsStamp: Hashable, Sendable {
        let device: Int64
        let file: UInt64
        let size: Int64
        let seconds: Int64
        let nanoseconds: Int64
    }

    /// The stamp of the profile's stored settings as they are now; nil when there is no such file.
    public func settingsStamp(_ id: UUID) -> SettingsStamp? {
        var info = stat()
        guard stat(configURL(for: id).path, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        #else
        let modified = info.st_mtim
        #endif
        return SettingsStamp(device: Int64(truncatingIfNeeded: info.st_dev), file: UInt64(truncatingIfNeeded: info.st_ino),
                             size: Int64(truncatingIfNeeded: info.st_size), seconds: Int64(truncatingIfNeeded: modified.tv_sec),
                             nanoseconds: Int64(truncatingIfNeeded: modified.tv_nsec))
    }
}

/// Something made from each profile's settings — what the Profiles window shows of them — kept for as
/// long as the stored settings are the same file (`ProfileRepository.SettingsStamp`). The window's
/// refresh, which runs after every launch, stop, edit and save, decrypted and decoded every
/// profile's settings on the main thread each time, a camera's image or video inside them
/// included; now only the settings that changed since are read. Settings that do not read are not
/// kept: they are read again next time, and fail as before. One owner, one thread.
public final class ProfileSettingsCache<Value> {
    private var entries: [UUID: (stamp: ProfileRepository.SettingsStamp, value: Value)] = [:]
    /// The repository the entries were read from: another one (a vault locked and opened again)
    /// starts empty.
    private weak var repository: ProfileRepository?

    public init() {}

    /// `make` of profile `id`'s settings as stored now: the value kept from an earlier call while the
    /// file is the same one, else the settings read (`loadConfiguration`, whose errors it throws)
    /// and the new value kept.
    public func value(of id: UUID, in repository: ProfileRepository, _ make: (ProfileConfiguration) throws -> Value) throws -> Value {
        if self.repository !== repository {
            entries.removeAll()
            self.repository = repository
        }
        // Taken before the read: a write while it reads leaves the file with another stamp, and the
        // next call reads again.
        let stamp = repository.settingsStamp(id)
        if let stamp, let entry = entries[id], entry.stamp == stamp { return entry.value }
        entries[id] = nil
        let value = try make(repository.loadConfiguration(id))
        if let stamp { entries[id] = (stamp, value) }
        return value
    }

    /// Only these profiles' entries are kept (the others are no longer listed).
    public func keep(only ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    /// Nothing is kept (the vault was locked: what the values hold goes with it).
    public func removeAll() {
        entries.removeAll()
        repository = nil
    }

    /// How many profiles have a value kept (the tests read it).
    public var count: Int { entries.count }
}
