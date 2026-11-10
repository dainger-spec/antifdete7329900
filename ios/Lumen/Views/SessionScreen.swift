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
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(EclipseBackground())
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
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(Theme.warn)
                .frame(width: 92, height: 92)
                .background(Theme.warn.opacity(0.12), in: Circle())
                .overlay(Circle().strokeBorder(Theme.warn.opacity(0.3), lineWidth: 0.5))
                .accessibilityHidden(true)
            Text(L("Профиль заперт")).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text).padding(.top, 8)
            Text(forProxy
                 ? L("%@ Этот профиль работал через прокси и без него не откроется: сайты увидели бы настоящий адрес устройства. Данные профиля сохранены.", "\(reason)")
                 : reason)
                .font(.system(size: 16)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(EclipseBackground())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lockedSession")
    }
}
