import Foundation
import WebKit

/// The WebKit data stores whose cookies the sync's run reads and writes (`CookieBridge`), held while
/// the app runs.
///
/// WebKit's cookie store does not keep its data store alive. A `WKWebsiteDataStore(forIdentifier:)`
/// made for one call and let go — the store of a session nothing has opened since the launch, such as
/// one the run has just made — ends before WebKit has done the call or kept its result: the run
/// counted the Mac's cookie as set, and the session opened without it (CI on 6a20b637 and 86087a19,
/// AccountTests: "Куки обновлены: 1", then the session's first page was sent no cookie). A read of
/// such a store is no surer. Held here from the run's first call, the store the run reads and writes
/// is the one the session then opens (`SessionRuntime`; WebKit, too, gives the live data store of an
/// identifier to whoever asks for it).
@MainActor
enum SyncedDataStores {
    private static var held: [UUID: WKWebsiteDataStore] = [:]

    /// The data store `storeID`, held from now on.
    static func store(_ storeID: UUID) -> WKWebsiteDataStore {
        if let store = held[storeID] { return store }
        let store = WKWebsiteDataStore(forIdentifier: storeID)
        held[storeID] = store
        return store
    }

    /// The data store `storeID` if one is held: a session's runtime opens that one.
    static func existing(_ storeID: UUID) -> WKWebsiteDataStore? { held[storeID] }

    /// Let go, before the store is removed with its session: WebKit refuses to remove a store in use.
    static func release(_ storeID: UUID) { held[storeID] = nil }
}
