import BrowserCore
import Foundation
import WebKit

/// Between a profile's WebKit cookie store and its synced cookies (`CookieJarDocument`,
/// `cookies.bin`; docs/SYNC_FORMAT.md): reads the store's persistent cookies as the document
/// keeps them, and makes the store hold the document. `ProfileManager` records what a run changed
/// at stop, and applies the document at launch, before the first page loads.
@MainActor
enum CookieStoreSync {
    /// The store's persistent cookies. Session cookies never sync: they end with the run.
    static func persistentCookies(in store: WKHTTPCookieStore) async -> [ImportedCookie] {
        await allCookies(in: store).compactMap(cookie(from:))
    }

    /// Every cookie of the store a file can hold, session cookies included (`anyCookie`).
    static func exportableCookies(in store: WKHTTPCookieStore) async -> [ImportedCookie] {
        await allCookies(in: store).compactMap(anyCookie(from:))
    }

    /// A store cookie as the document keeps it; nil for a session cookie, and for a partitioned
    /// (CHIPS) one: WebKit marks those with its partition (`StoragePartition`), which the public
    /// API cannot set on the other device, and unpartitioned the cookie would reach more sites
    /// (as for an import).
    static func cookie(from cookie: HTTPCookie) -> ImportedCookie? {
        guard !cookie.isSessionOnly, cookie.expiresDate != nil else { return nil }
        return anyCookie(from: cookie)
    }

    /// A store cookie, session cookies included (an export: `CookieExport`); nil for a
    /// partitioned one, which no file format can tie to its top-level site.
    static func anyCookie(from cookie: HTTPCookie) -> ImportedCookie? {
        if let partition = cookie.properties?[HTTPCookiePropertyKey("StoragePartition")] as? String, !partition.isEmpty { return nil }
        let expires = cookie.isSessionOnly ? nil : cookie.expiresDate
        let stored = cookie.domain.lowercased()
        let hostOnly = !stored.hasPrefix(".")
        var sameSite: ImportedCookie.SameSite?
        if cookie.sameSitePolicy == HTTPCookieStringPolicy.sameSiteLax { sameSite = .lax }
        if cookie.sameSitePolicy == HTTPCookieStringPolicy.sameSiteStrict { sameSite = .strict }
        return ImportedCookie(name: cookie.name, value: cookie.value, domain: hostOnly ? stored : String(stored.dropFirst()),
                              hostOnly: hostOnly, path: cookie.path, expires: expires, secure: cookie.isSecure,
                              httpOnly: cookie.isHTTPOnly, sameSite: sameSite)
    }

    struct Applied: Equatable {
        var set: Int
        var deleted: Int
        /// Cookies of the document the store did not keep (it stays in the document).
        var refused: [ImportedCookie]
    }

    /// Makes `store` hold the document: its cookies set where the store has none or another
    /// version, its deletions deleted. Store cookies the document does not know are left alone.
    static func apply(_ document: CookieJarDocument, to store: WKHTTPCookieStore) async -> Applied {
        var inStore: [CookieKey: HTTPCookie] = [:]
        var persistent: [ImportedCookie] = []
        for httpCookie in await allCookies(in: store) {
            guard let cookie = cookie(from: httpCookie) else { continue }
            persistent.append(cookie)
            inStore[CookieKey(cookie)] = httpCookie
        }
        let changes = document.changes(over: persistent)
        for cookie in changes.delete {
            guard let httpCookie = inStore[CookieKey(cookie)] else { continue }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.delete(httpCookie) { continuation.resume() }
            }
        }
        var refused: [ImportedCookie] = []
        if !changes.set.isEmpty {
            // Checks what the store kept, replaces HttpOnly cookies, writes to disk.
            refused = await CookieStoreImport.apply(changes.set, to: store).refused
        } else if !changes.delete.isEmpty {
            await CookieStoreImport.flush(store)
        }
        return Applied(set: changes.set.count - refused.count, deleted: changes.delete.count, refused: refused)
    }

    private static func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }
}
