import LumenCore
import SwiftUI

/// A session opened: its browser. Opening it is what the card's "last opened" shows.
struct SessionScreen: View {
    @EnvironmentObject var model: AppModel
    let sessionID: UUID

    var body: some View {
        Group {
            if let session = model.session(sessionID) {
                if case let .locked(reason) = model.lock(session) {
                    // No web view, no tab restored: nothing of this profile reaches the network.
                    LockedSessionView(reason: reason, forProxy: model.lockedForProxy(session)).navigationTitle(session.name)
                } else {
                    BrowserView(runtime: SessionRuntimes.shared.runtime(for: session, model: model))
                }
            } else {
                ContentUnavailableView(L("Сессия удалена"), systemImage: "trash")
            }
        }
        .onAppear { model.markOpened(sessionID) }
    }
}

/// A profile that does not open now — it lived behind a proxy and may not use one, or the plan does
/// not reach it: why, and that its data is kept.
struct LockedSessionView: View {
    let reason: String
    var forProxy = true

    var body: some View {
        ContentUnavailableView {
            Label(L("Профиль заперт"), systemImage: "lock.fill")
        } description: {
            Text(forProxy
                 ? L("%@ Этот профиль работал через прокси и без него не откроется: сайты увидели бы настоящий адрес устройства. Данные профиля сохранены.", "\(reason)")
                 : reason)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lockedSession")
    }
}
