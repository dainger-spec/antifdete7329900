#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A version of a profile's settings kept beside them: the other side of a sync conflict (R4), or a
/// version older than the server's that was put back here from a backup (R2). Each is a file of
/// its own — `config.bin.conflict`, then `-2`, `-3`, … — holding the version as `config.bin` held
/// it; none is written over, and none goes but by the person's own hand (docs/DESTRUCTIVE_PATHS.md).
/// The clocks decide only which version is the profile's settings; they never drop the other.
public struct KeptSettings: Equatable, Sendable {
    public enum Origin: String, Codable, Equatable, Sendable {
        /// This Mac's version: the other device's settings were newer.
        case thisMac
        /// Another device's version: this Mac's settings were newer.
        case otherDevice
        /// Older than the server's, put back on this Mac from a backup (R2): the server's stayed the
        /// profile's settings.
        case restored
        /// The settings this Mac had before the person chose a kept version instead.
        case replaced
        /// Kept before origins were recorded (`config.bin.conflict` of an earlier version).
        case unknown
    }

    /// The file's name in the profile's folder.
    public var file: String
    public var origin: Origin
    /// The Mac the version is from, when known: this Mac's name for its own versions.
    public var device: String?
    /// When it was kept.
    public var keptAt: Date
    /// The version itself; nil when it does not open (it is kept as it is, and shown so).
    public var configuration: ProfileConfiguration?
    /// When those settings were last changed (`ProfileConfiguration.settingsModifiedAt`).
    public var editedAt: Date? { configuration?.settingsModifiedAt }

    /// Past this many, the profile asks for its kept versions to be gone through; none is removed
    /// for it.
    public static let reviewAbove = 5

    public init(file: String, origin: Origin, device: String?, keptAt: Date, configuration: ProfileConfiguration?) {
        self.file = file
        self.origin = origin
        self.device = device
        self.keptAt = keptAt
        self.configuration = configuration
    }
}

/// What is recorded of each kept version besides the file itself (`config-versions.bin`). A file
/// without a record is still listed, its origin unknown.
struct KeptSettingsRecord: Codable, Equatable, Sendable {
    var file: String
    var origin: KeptSettings.Origin
    var device: String?
    var keptAt: Date
}

extension ProfileRepository {
    static let keptSettingsPrefix = "config.bin.conflict"

    func keptSettingsRecordsFile(for id: UUID) throws -> EncryptedDocumentFile<[KeptSettingsRecord]> {
        EncryptedDocumentFile(url: directory(for: id).appendingPathComponent("config-versions.bin"),
                              key: try profileKey(for: id).derive(info: "config-versions", salt: id.rawBytes),
                              aad: "config-versions:v1:\(id.uuidString)")
    }

    /// The number of a kept version's file (`config.bin.conflict` is 1), or nil for another file.
    static func keptSettingsNumber(_ name: String) -> Int? {
        if name == keptSettingsPrefix { return 1 }
        guard name.hasPrefix(keptSettingsPrefix + "-"), let number = Int(name.dropFirst(keptSettingsPrefix.count + 1)),
              number >= 2 else { return nil }
        return number
    }

    /// Keeps `sealed` — a version of the profile's settings, as `config.bin` holds it — beside them,
    /// in a file of its own that no other is written over. Returns its name.
    @discardableResult
    func keepSettingsVersion(_ sealed: Data, origin: KeptSettings.Origin, for id: UUID, at time: Date = Date()) throws -> String {
        let config = configURL(for: id)
        var number = 1
        while true {
            let name = number == 1 ? Self.keptSettingsPrefix : "\(Self.keptSettingsPrefix)-\(number)"
            if try SecureFile.createNew(sealed, at: config.deletingLastPathComponent().appendingPathComponent(name)) {
                record(KeptSettingsRecord(file: name, origin: origin, device: origin == .otherDevice ? nil : PasswordVault.deviceName,
                                          keptAt: time), for: id)
                return name
            }
            number += 1
        }
    }

    /// The record is what the list shows of a version beside the version itself; a version without
    /// one is shown all the same, so a record that cannot be written stops nothing.
    private func record(_ record: KeptSettingsRecord, for id: UUID) {
        guard let file = try? keptSettingsRecordsFile(for: id) else { return }
        var records = ((try? file.load()) ?? nil) ?? []
        records.removeAll { $0.file == record.file }
        records.append(record)
        try? file.save(records)
    }

    /// The profile's kept versions of its settings, oldest kept first.
    public func keptSettings(for id: UUID) -> [KeptSettings] {
        let folder = directory(for: id)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .compactMap { name in Self.keptSettingsNumber(name).map { (name, $0) } }
            .sorted { $0.1 < $1.1 }
        guard !names.isEmpty else { return [] }
        let records = Dictionary(((try? keptSettingsRecordsFile(for: id).load()) ?? nil ?? []).map { ($0.file, $0) },
                                 uniquingKeysWith: { $1 })
        let key = try? profileKey(for: id)
        return names.map { name, _ in
            let url = folder.appendingPathComponent(name)
            let configuration = key.flatMap { key in
                (try? SecureFile.read(url)).flatMap { try? Self.decodeConfiguration(AEAD.open($0, key: key, aad: Self.configAAD(id))) }
            }
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            let record = records[name]
            return KeptSettings(file: name, origin: record?.origin ?? .unknown, device: record?.device,
                                keptAt: record?.keptAt ?? modified ?? Date(timeIntervalSince1970: 0), configuration: configuration)
        }
    }

    /// The person chose the kept version `file` for the profile's settings: it is saved as a new
    /// edit of them (the newest, so that sync takes it everywhere), and the settings it replaces
    /// are kept in its file in its place — nothing is dropped. A version that does not open, or
    /// that a newer version of the app wrote, is refused.
    public func useKeptSettings(_ file: String, for id: UUID, at time: Date = Date()) throws {
        guard Self.keptSettingsNumber(file) != nil else { throw CoreError.invalidConfiguration("not a kept version: \(file)") }
        let key = try profileKey(for: id)
        let url = directory(for: id).appendingPathComponent(file)
        let chosen = try Self.decodeConfiguration(AEAD.open(SecureFile.read(url), key: key, aad: Self.configAAD(id)))
        let current = try loadConfiguration(id, key: key)
        let currentSealed = try SecureFile.read(configURL(for: id))
        var saved = chosen.keepingStoredState(of: current)
        saved.settingsModifiedAt = time
        try saveConfiguration(saved, for: id)
        try SecureFile.write(currentSealed, to: url)
        record(KeptSettingsRecord(file: file, origin: .replaced, device: PasswordVault.deviceName, keptAt: time), for: id)
    }

    /// The person removes the kept version `file`, having looked at it. One that does not open is
    /// never removed (docs/DESTRUCTIVE_PATHS.md): it is refused.
    public func removeKeptSettings(_ file: String, for id: UUID) throws {
        guard Self.keptSettingsNumber(file) != nil else { throw CoreError.invalidConfiguration("not a kept version: \(file)") }
        guard let kept = keptSettings(for: id).first(where: { $0.file == file }) else { return }
        guard kept.configuration != nil else {
            throw CoreError.corruptData("\(file) cannot be read; it is kept as it is")
        }
        try FileManager.default.removeItem(at: directory(for: id).appendingPathComponent(file))
        if let records = try? keptSettingsRecordsFile(for: id), let all = (try? records.load()) ?? nil {
            try? records.save(all.filter { $0.file != file })
        }
    }
}
