import BrowserCore
import Foundation
import WebKit

/// Cookie import and export for a running profile, through its data store's
/// `WKHTTPCookieStore` (the only public way in and out of WebKit's cookie jar). Formats:
/// Netscape `cookies.txt` and the JSON of common browser extensions (`CookieTransfer`).
///
/// Imported cookies land only in this profile's store. Export writes the profile's cookies in
/// plain text — including login sessions — to a file the user chose; the UI says so.
@MainActor
enum CookieService {
    struct ImportResult: Equatable {
        var imported: Int
        var skipped: Int
    }

    static func importCookies(_ data: Data, into store: WKHTTPCookieStore, now: Date = Date()) async throws -> ImportResult {
        let parsed = try CookieTransfer.parse(data)
        var imported = 0
        var skipped = parsed.skipped
        for record in parsed.cookies {
            // An expired cookie would only delete one of the same name; leave existing ones alone.
            guard !record.isExpired(at: now), let cookie = record.httpCookie else {
                skipped += 1
                continue
            }
            await setCookie(cookie, in: store)
            imported += 1
        }
        Log.info("cookies", "imported \(imported), skipped \(skipped)")
        return ImportResult(imported: imported, skipped: skipped)
    }

    static func exportCookies(from store: WKHTTPCookieStore, format: CookieFormat) async throws -> (data: Data, count: Int) {
        let records = await allCookies(in: store).compactMap(CookieRecord.init)
            .sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
        let data: Data
        switch format {
        case .netscape: data = Data(CookieTransfer.exportNetscape(records).utf8)
        case .json: data = try CookieTransfer.exportJSON(records)
        }
        Log.info("cookies", "exported \(records.count)")
        return (data, records.count)
    }

    static func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    static func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.setCookie(cookie) { continuation.resume() }
        }
    }
}
