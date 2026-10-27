import BrowserCore
import Foundation
import WebKit

/// Puts imported cookies into a profile's WebKit cookie store and checks which ones it kept.
///
/// `WKHTTPCookieStore.setCookie` reports nothing: its completion only means the request reached
/// the network process, and a cookie CFNetwork refuses is simply not there. So the store is read
/// back afterwards and every imported cookie looked for by name, domain (host-only or not) and
/// path, with its value; those missing or different are returned as refused. A cookie that is not
/// HttpOnly cannot replace an HttpOnly one (WebKit keeps the old one, silently), so that one is
/// deleted first: an import replaces what the profile had.
@MainActor
enum CookieStoreImport {
    struct Result: Equatable {
        var stored: Int
        var refused: [ImportedCookie]
    }

    static func apply(_ cookies: [ImportedCookie], to store: WKHTTPCookieStore) async -> Result {
        let before = Dictionary(await allCookies(in: store).map { (identity(of: $0), $0) }, uniquingKeysWith: { first, _ in first })
        var refused: [ImportedCookie] = []
        var set: [ImportedCookie] = []
        for cookie in cookies {
            guard let httpCookie = httpCookie(for: cookie) else {
                refused.append(cookie)
                continue
            }
            if !cookie.httpOnly, let old = before[cookie.identity], old.isHTTPOnly {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    store.delete(old) { continuation.resume() }
                }
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.setCookie(httpCookie) { continuation.resume() }
            }
            set.append(cookie)
        }
        let after = Dictionary(await allCookies(in: store).map { (identity(of: $0), $0) }, uniquingKeysWith: { first, _ in first })
        refused += set.filter { after[$0.identity]?.value != $0.value }
        // On disk now: a profile stopped right after an import would otherwise seal its website
        // data before CFNetwork wrote the new cookies.
        await flush(store)
        return Result(stored: cookies.count - refused.count, refused: refused)
    }

    private static let flushSelector = NSSelectorFromString("_flushCookiesToDiskWithCompletionHandler:")

    /// Whether this WebKit can be asked to write its cookies to disk (self-test information).
    static var canFlush: Bool { WKHTTPCookieStore.instancesRespond(to: flushSelector) }

    /// Writes the store's cookies to disk now. CFNetwork keeps new cookies in memory and writes
    /// them later; there is no public API to make it, so this is WebKit's (`WKHTTPCookieStore
    /// (WKPrivate)`, the call Safari makes), used only when this WebKit has it, as the private
    /// `WKPreferences` in `BrowserSession`. Returns false without it.
    @discardableResult
    static func flush(_ store: WKHTTPCookieStore) async -> Bool {
        guard store.responds(to: flushSelector), let method = class_getInstanceMethod(type(of: store), flushSelector) else { return false }
        typealias Flush = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        let call = unsafeBitCast(method_getImplementation(method), to: Flush.self)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            call(store, flushSelector) { continuation.resume() }
        }
        return true
    }

    private static func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    /// As `ImportedCookie.identity`: a cookie store keeps one cookie per name, domain and path.
    private static func identity(of cookie: HTTPCookie) -> String {
        [cookie.name, cookie.domain.lowercased(), cookie.path].joined(separator: "\u{0}")
    }

    /// The `HTTPCookie` for an imported cookie: a domain without a leading dot is host-only; no
    /// expiry makes a session cookie; SameSite None or unspecified is left out (WebKit's default,
    /// as Safari sends such cookies cross-site).
    static func httpCookie(for cookie: ImportedCookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name, .value: cookie.value, .domain: cookie.storedDomain, .path: cookie.path,
        ]
        if cookie.secure { properties[.secure] = "TRUE" }
        if let expires = cookie.expires {
            properties[.expires] = expires
        } else {
            properties[.discard] = "TRUE"
        }
        if cookie.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch cookie.sameSite {
        case .some(.lax): properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case .some(.strict): properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        default: break
        }
        return HTTPCookie(properties: properties)
    }
}
