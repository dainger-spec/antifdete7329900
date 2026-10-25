import Foundation

/// Where WebKit keeps the on-disk data of `WKWebsiteDataStore(forIdentifier:)` stores.
///
/// PLATFORM LIMITATION: Apple does not document this layout. It is observed behaviour of
/// macOS 14/15, relative to the app's Library directory (`~/Library`, or
/// `~/Library/Containers/<bundle-id>/Data/Library` inside the App Sandbox):
///
/// | Data                     | Not sandboxed                                       | Sandboxed                                  |
/// |--------------------------|-----------------------------------------------------|--------------------------------------------|
/// | General storage          | `WebKit/<bundle-id>/WebsiteDataStore/<UUID>`        | `WebKit/WebsiteDataStore/<UUID>`           |
/// | Network cache            | `Caches/<bundle-id>/WebKit/WebsiteDataStore/<UUID>` | `Caches/WebKit/WebsiteDataStore/<UUID>`    |
///
/// (WebKit omits the bundle ID when the process has a container.) Because the layout is not
/// guaranteed, directories are *discovered* by name — WebKit names them after the store
/// UUID — and only the translation between the two known layouts relies on the table.
/// The app's `--self-test` mode verifies both on the running macOS version.
public struct WebKitDataLayout: Equatable, Sendable {
    public let library: URL
    public let bundleID: String
    public let sandboxed: Bool

    /// Directory names that follow the root directly in the sandboxed layout.
    private static let sandboxedSecondComponent = ["WebKit": "WebsiteDataStore", "Caches": "WebKit"]
    static let searchDepth = 4

    public init(library: URL, bundleID: String, sandboxed: Bool) {
        self.library = library.standardizedFileURL
        self.bundleID = bundleID
        self.sandboxed = sandboxed
    }

    /// Subtrees searched for a store's directories. Inside the sandbox the whole container
    /// belongs to this app; outside it only the bundle-ID subtrees do.
    public var searchRoots: [URL] {
        if sandboxed {
            return [library.appendingPathComponent("WebKit", isDirectory: true),
                    library.appendingPathComponent("Caches", isDirectory: true)]
        }
        return [library.appendingPathComponent("WebKit/\(bundleID)", isDirectory: true),
                library.appendingPathComponent("Caches/\(bundleID)", isDirectory: true)]
    }

    /// Every directory named after `profileID` (case-insensitive) below the search roots.
    /// Symlinks are never followed.
    public func discoverDirectories(for profileID: UUID) -> [URL] {
        let target = profileID.uuidString.lowercased()
        var found: [URL] = []
        var seen = Set<String>()
        for root in searchRoots {
            Self.search(root, target: target, depth: 0, found: &found, seen: &seen)
        }
        return found.sorted { $0.path < $1.path }
    }

    private static func search(_ directory: URL, target: String, depth: Int, found: inout [URL], seen: inout Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let child = directory.appendingPathComponent(name, isDirectory: true)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: child.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { continue } // lstat
            if name.lowercased() == target {
                if seen.insert(child.path).inserted { found.append(child) }
            } else if depth < searchDepth {
                search(child, target: target, depth: depth + 1, found: &found, seen: &seen)
            }
        }
    }

    /// Archive root label of a discovered directory: its path relative to Library with
    /// "/" → "|" (labels are single path components).
    public func label(for directory: URL) throws -> String {
        let base = library.path.hasSuffix("/") ? library.path : library.path + "/"
        let path = directory.standardizedFileURL.path
        guard path.hasPrefix(base) else { throw CoreError.unsafeArchivePath(path) }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "|")
    }

    /// Where an archived root is restored in *this* layout.
    ///
    /// Labels written by the other layout are translated (bundle-ID component removed or
    /// inserted), so archives sealed by a non-sandboxed build restore correctly in the
    /// sandboxed build and vice versa. Labels are validated: known root, no traversal, and
    /// the last component must be the profile's UUID.
    public func destination(forLabel label: String, profileID: UUID) throws -> URL {
        var components = label.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 3,
              let root = components.first, let marker = Self.sandboxedSecondComponent[root],
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }),
              components.last?.lowercased() == profileID.uuidString.lowercased() else {
            throw CoreError.unsafeArchivePath(label)
        }
        // Normalise to the sandboxed form (no bundle-ID component)…
        if components[1] != marker {
            components.remove(at: 1)
            guard components.count >= 3, components[1] == marker else { throw CoreError.unsafeArchivePath(label) }
        }
        // …then add this build's bundle ID if not sandboxed.
        if !sandboxed {
            components.insert(bundleID, at: 1)
        }
        return components.reduce(library) { $0.appendingPathComponent($1, isDirectory: true) }
    }
}
