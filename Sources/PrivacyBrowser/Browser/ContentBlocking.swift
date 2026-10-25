import BrowserCore
import Foundation
import WebKit

/// Compiles a profile's `TrackerBlockingSettings` into a `WKContentRuleList`.
///
/// NATIVE: WebKit's content-blocker engine evaluates the list for every load of every tab and
/// popup of the profile — before the request leaves the browser, in the web content and network
/// processes. Lists are attached per `WKUserContentController`, i.e. per profile session, so each
/// profile blocks according to its own settings.
///
/// The compiled list lives in a private `WKContentRuleListStore` under the temporary directory,
/// one folder per running profile, and is deleted when the profile stops: the allow-list and the
/// custom domains are the profile's settings and are otherwise only stored encrypted. Leftovers of
/// a crash are deleted at the next unlock.
///
/// PLATFORM LIMITATION: WebKit reports nothing about what it blocked (no per-request callback or
/// counter for apps), so the UI cannot show blocked-request counts.
@MainActor
enum ContentBlocking {
    static var rootDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pb-content-rules", isDirectory: true)
    }

    static func storeDirectory(for profileID: UUID) -> URL {
        rootDirectory.appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    /// nil when the settings block nothing.
    static func compile(_ settings: TrackerBlockingSettings, profileID: UUID) async throws -> WKContentRuleList? {
        guard let json = ContentBlockerRules.json(for: settings) else { return nil }
        let directory = storeDirectory(for: profileID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let optionalStore: WKContentRuleListStore? = WKContentRuleListStore(url: directory)
        guard let store = optionalStore else { throw CoreError.io("content rule list store unavailable") }
        let identifier = ContentBlockerRules.identifier(for: json)
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: CoreError.invalidConfiguration(
                        "tracker blocking rules did not compile: \(error?.localizedDescription ?? "unknown error")"))
                }
            }
        }
    }

    static func removeStore(for profileID: UUID) {
        try? FileManager.default.removeItem(at: storeDirectory(for: profileID))
    }

    /// Only while no profile runs (at unlock and after lock).
    static func removeAllStores() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
