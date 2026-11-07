import LumenCore
import SwiftUI

/// A session opened: its browser. Opening it is what the card's "last opened" shows.
struct SessionScreen: View {
    @EnvironmentObject var model: AppModel
    let sessionID: UUID

    var body: some View {
        Group {
            if let session = model.session(sessionID) {
                BrowserView(session: session)
            } else {
                ContentUnavailableView("Сессия удалена", systemImage: "trash")
            }
        }
        .onAppear { model.markOpened(sessionID) }
    }
}
