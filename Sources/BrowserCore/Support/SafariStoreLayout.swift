import Foundation

/// Safari's own stores in a profile's home: where Safari's frameworks, hosted in a profile's
/// process, keep its databases and property lists — and what a profile's process makes sure of
/// before Safari's chrome loads.
///
/// WHERE. In a profile's process the home is the profile's (`CFFIXED_USER_HOME`), so Safari's code
/// that keeps its state in its container (`NSHomeDirectory()/Library/Safari` in Safari, which is
/// sandboxed) and its code that keeps it in the account's `~/Library/Safari` (moved to the home by
/// `SafariPaths`) both land in the home's `Library/Safari`. A complete Safari data tree there —
/// the stores Safari opens, as another browser hosting Safari's chrome keeps them for each of its
/// profiles (docs/SAFARI_PROCESS.md, "Profile state in Safari's own file formats") — is `stores`.
///
/// WHAT IS MADE. Folders only: the home's Library folders an account's home always has, the folder
/// of each store and the stores that are folders. Safari's own code creates its databases and
/// property lists in them, with its own schemas: none is written here. A store found that is not
/// what it should be — a database without SQLite's header, one SQLite cannot open, a property list
/// that does not parse, a file where a folder belongs — is set aside beside itself
/// (`<name>.unreadable`, with its journal files), so that Safari's code makes a new one instead of
/// failing on it, and nothing of it is lost. A store or folder the owner cannot write is made
/// writable. A profile made before this existed gets what it lacks at its next launch.
///
/// Never the real Safari's data: only paths in the home given are looked at.
public enum SafariStoreLayout {
    public enum Kind: String, Codable, Sendable {
        case database, propertyList, folder
    }

    public struct Store: Codable, Equatable, Sendable {
        /// Relative to the home.
        public var path: String
        public var kind: Kind

        public init(_ path: String, _ kind: Kind) {
            self.path = path
            self.kind = kind
        }
    }

    /// The folder Safari's stores are in, relative to the home.
    public static let safariFolder = "Library/Safari"

    /// Safari's stores as a complete per-profile Safari data tree holds them.
    public static let stores: [Store] = [
        Store("Library/Safari/Bookmarks.plist", .propertyList),
        Store("Library/Safari/History.db", .database),
        Store("Library/Safari/Embeddings.db", .database),
        Store("Library/Safari/PerSitePreferences.db", .database),
        Store("Library/Safari/IgnoredSiriSuggestedSites.db", .database),
        Store("Library/Safari/CloudAutoFillCorrections.db", .database),
        Store("Library/Safari/NotifyMeWhen.db", .database),
        Store("Library/Safari/UserDefinedContentBlockers.db", .database),
        Store("Library/Safari/BlockedBannerHighlights.db", .database),
        Store("Library/Safari/TabSnapshots/Metadata.db", .database),
        Store("Library/Safari/Metadata Cache/LPLinkMetadata.db", .database),
        Store("Library/Safari/Favicon Cache/favicons.db", .database),
        Store("Library/Safari/Favicon Cache/favicons", .folder),
        Store("Library/Safari/TopSites.plist", .propertyList),
        Store("Library/Safari/Template Icons/CacheSettings.plist", .propertyList),
        Store("Library/Safari/Link Presentation Icons", .folder),
        Store("Library/Safari/LocalStorage", .folder),
        Store("Library/Safari/Databases/___IndexedDB", .folder),
        Store("Library/Safari/ResourceLoadStatistics/pcm.db", .database),
        Store("Library/Safari/ResourceLoadStatistics/observations.db", .database),
    ]

    /// The Library folders every account's home has, which a profile's new home did not: code that
    /// writes into one of them without making it first fails in a home that lacks it.
    public static let libraryFolders = [
        "Library", "Library/Application Support", "Library/Caches", "Library/Cookies", "Library/HTTPStorages",
        "Library/Logs", "Library/Preferences", "Library/WebKit", safariFolder,
    ]

    /// The folders `prepare` makes, parents before children.
    public static var folders: [String] {
        var all: [String] = []
        func add(_ path: String) {
            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty, parent != path { add(parent) }
            if !all.contains(path) { all.append(path) }
        }
        for folder in libraryFolders { add(folder) }
        for store in stores {
            add(store.kind == .folder ? store.path : (store.path as NSString).deletingLastPathComponent)
        }
        return all
    }

    /// A database's journal files, which go with it.
    public static let journalSuffixes = ["-wal", "-shm", "-journal"]
    /// What a store set aside is renamed to: `<name>` + this.
    public static let setAsideSuffix = ".unreadable"

    // MARK: Looking

    public struct Assessment: Codable, Equatable, Sendable {
        public var path: String
        public var kind: Kind
        public var exists = false
        public var bytes: Int64 = 0
        /// The owner can write it (a folder: and make files in it).
        public var writable = false
        /// It is what its kind says: a database that starts with SQLite's header (or is empty, which
        /// SQLite takes for a new database), a property list that parses, a folder.
        public var wellFormed = false
        /// What opening it answered, where the platform opens it (SQLite on the Mac): nil when not asked.
        public var opened: String?

        public init(path: String, kind: Kind) {
            self.path = path
            self.kind = kind
        }

        /// One line: "Library/Safari/History.db database: present 32768 B, writable, opens (5 tables)".
        public var line: String {
            guard exists else { return "\(path) \(kind.rawValue): missing" }
            var parts = ["present" + (kind == .folder ? "" : " \(bytes) B")]
            parts.append(writable ? "writable" : "NOT WRITABLE")
            if !wellFormed { parts.append("NOT A \(kind == .database ? "DATABASE" : kind == .propertyList ? "PROPERTY LIST" : "FOLDER")") }
            if let opened { parts.append(opened) }
            return "\(path) \(kind.rawValue): " + parts.joined(separator: ", ")
        }
    }

    /// SQLite's header: the first 16 bytes of every database file.
    static let sqliteHeader = Array("SQLite format 3\u{0}".utf8)

    /// How each of `stores` stands in `home`. `open` asks the platform whether a database opens, and
    /// what it found (nil: not asked).
    public static func assess(home: URL, open: ((URL) -> String?)? = nil) -> [Assessment] {
        stores.map { assess($0, home: home, open: open) }
    }

    public static func assess(_ store: Store, home: URL, open: ((URL) -> String?)? = nil) -> Assessment {
        var result = Assessment(path: store.path, kind: store.kind)
        let url = home.appendingPathComponent(store.path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return result }
        result.exists = true
        result.writable = FileManager.default.isWritableFile(atPath: url.path)
            && (!isFolder.boolValue || FileManager.default.isExecutableFile(atPath: url.path))
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
            result.bytes = size.int64Value
        }
        result.wellFormed = isWellFormed(url, kind: store.kind, isFolder: isFolder.boolValue)
        if store.kind == .database, result.wellFormed, let open { result.opened = open(url) }
        return result
    }

    /// Whether the item at `url` is what `kind` says.
    public static func isWellFormed(_ url: URL, kind: Kind, isFolder: Bool) -> Bool {
        switch kind {
        case .folder:
            return isFolder
        case .database:
            guard !isFolder, let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            let head = [UInt8]((try? handle.read(upToCount: sqliteHeader.count)) ?? Data())
            return head.isEmpty || head == sqliteHeader
        case .propertyList:
            guard !isFolder, let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
            return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) != nil
        }
    }

    // MARK: Making sure

    public struct Preparation: Codable, Equatable, Sendable {
        /// Folders made.
        public var made: [String] = []
        /// Folders and stores the owner could not write, made writable.
        public var madeWritable: [String] = []
        /// Stores that were not what they should be, set aside (`setAsideSuffix`).
        public var setAside: [String] = []
        /// What could not be done, with why.
        public var failed: [String] = []

        public init() {}

        public var isEmpty: Bool { made.isEmpty && madeWritable.isEmpty && setAside.isEmpty && failed.isEmpty }
    }

    /// Makes `folders` exist in `home`, every folder and store writable by its owner, and sets aside
    /// the stores that are not what they should be. `opens` asks the platform whether a database
    /// opens: false sets it aside, nil (could not tell — busy, say) leaves it. Run in a profile's own
    /// process before Safari's frameworks load, and again at every launch.
    public static func prepare(home: URL, opens: ((URL) -> Bool?)? = nil) -> Preparation {
        var report = Preparation()
        let manager = FileManager.default
        // A file where a store's folder belongs is set aside first, so that the folder can be made.
        for folder in folders {
            let url = home.appendingPathComponent(folder)
            var isFolder: ObjCBool = false
            if manager.fileExists(atPath: url.path, isDirectory: &isFolder) {
                if !isFolder.boolValue {
                    setAside(url, folder, into: &report)
                } else {
                    makeWritable(url, folder, isFolder: true, into: &report)
                    continue
                }
            }
            do {
                try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                report.made.append(folder)
            } catch {
                report.failed.append("\(folder): \(Self.reason(error))")
            }
        }
        for store in stores where store.kind != .folder {
            let url = home.appendingPathComponent(store.path)
            var isFolder: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            var good = isWellFormed(url, kind: store.kind, isFolder: isFolder.boolValue)
            if good, store.kind == .database, !isFolder.boolValue {
                makeWritable(url, store.path, isFolder: false, into: &report)
                for suffix in journalSuffixes where manager.fileExists(atPath: url.path + suffix) {
                    makeWritable(URL(fileURLWithPath: url.path + suffix), store.path + suffix, isFolder: false, into: &report)
                }
                if let opens, opens(url) == false { good = false }
            } else if good {
                makeWritable(url, store.path, isFolder: false, into: &report)
            }
            if !good { setAside(url, store.path, into: &report) }
        }
        return report
    }

    /// `url` (and, for a database, its journal files) renamed to `<name>.unreadable`, replacing one
    /// set aside before.
    private static func setAside(_ url: URL, _ path: String, into report: inout Preparation) {
        let manager = FileManager.default
        for suffix in [""] + journalSuffixes {
            let item = url.path + suffix
            guard manager.fileExists(atPath: item) else { continue }
            let aside = item + setAsideSuffix
            do {
                if manager.fileExists(atPath: aside) { try manager.removeItem(atPath: aside) }
                try manager.moveItem(atPath: item, toPath: aside)
                report.setAside.append(path + suffix)
            } catch {
                report.failed.append("\(path + suffix) could not be set aside: \(Self.reason(error))")
            }
        }
    }

    private static func makeWritable(_ url: URL, _ path: String, isFolder: Bool, into report: inout Preparation) {
        let manager = FileManager.default
        let canWrite = manager.isWritableFile(atPath: url.path) && (!isFolder || manager.isExecutableFile(atPath: url.path))
        guard !canWrite else { return }
        let current = ((try? manager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let wanted = current | (isFolder ? 0o700 : 0o600)
        do {
            try manager.setAttributes([.posixPermissions: wanted], ofItemAtPath: url.path)
            report.madeWritable.append(path)
        } catch {
            report.failed.append("\(path) could not be made writable: \(Self.reason(error))")
        }
    }

    /// An error as the log may have it: its domain and code, never a path.
    private static func reason(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
