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
                    LockedSessionView(reason: reason).navigationTitle(session.name)
                } else {
                    BrowserView(runtime: SessionRuntimes.shared.runtime(for: session, model: model))
                }
            } else {
                ContentUnavailableView("Сессия удалена", systemImage: "trash")
            }
        }
        .onAppear { model.markOpened(sessionID) }
    }
}

/// A profile that lived behind a proxy and may not use one now: why, and that its data is kept.
struct LockedSessionView: View {
    let reason: String

    var body: some View {
        ContentUnavailableView {
            Label("Профиль заперт", systemImage: "lock.fill")
        } description: {
            Text("\(reason) Этот профиль работал через прокси и без него не откроется: сайты увидели бы настоящий адрес устройства. Данные профиля сохранены.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lockedSession")
    }
}
