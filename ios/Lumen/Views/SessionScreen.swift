import LumenCore
import SwiftUI

/// A session opened: its browser. Opening it is what the row's time shows.
struct SessionScreen: View {
    @EnvironmentObject var model: AppModel
    let sessionID: UUID

    var body: some View {
        Group {
            if let session = model.session(sessionID) {
                if case let .locked(reason) = model.lock(session) {
                    // No web view, no tab restored: nothing of this session reaches the network.
                    LockedSessionView(session: session, reason: reason, forProxy: model.lockedForProxy(session))
                        .navigationTitle(session.name)
                        .navigationBarTitleDisplayMode(.inline)
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

/// A session that does not open now (k-locked) — it worked through a proxy and may not use one, or
/// the plan does not reach it: why, in plain words, and that its data is kept. No red: this is the
/// protection working, not a fault. The way on: the account, or another proxy if its own was deleted.
struct LockedSessionView: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    let reason: String
    var forProxy = true
    @State private var showPlans = false
    @State private var choosingProxy = false
    @State private var chosen: UUID?

    /// Its proxy was deleted: another one opens it again.
    private var proxyGone: Bool { session.boundToProxy && model.proxy(session.proxyID) == nil && model.access.proxies }

    var body: some View {
        ContentUnavailableView {
            Label(L("Сессия заперта"), systemImage: "lock")
        } description: {
            Text(forProxy
                 ? L("%@ Сессия работала через прокси — без него она не откроется, чтобы сайты не увидели настоящий адрес iPhone. Данные сессии сохранены.", "\(reason)")
                 : reason + " " + L("Данные сессии сохранены."))
        } actions: {
            if proxyGone {
                Button(L("Выбрать прокси")) { choosingProxy = true }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier("lockedChooseProxy")
            } else {
                Button(L("Аккаунт")) { showPlans = true }
                    .buttonStyle(.bordered).controlSize(.large)
                    .accessibilityIdentifier("lockedAccount")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lockedSession")
        .sheet(isPresented: $showPlans) { PlansView() }
        .sheet(isPresented: $choosingProxy) { ProxyChooser(sessionID: session.id, chosen: $chosen) }
    }
}
