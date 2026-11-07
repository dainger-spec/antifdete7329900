import LumenCore
import SwiftUI

// Step 1 of stage 2: the sessions. The browser (step 2) and the proxy list (step 3) replace these.

struct BrowserView: View {
    let session: Session
    var body: some View {
        Text("Браузер сессии «\(session.name)»")
            .accessibilityIdentifier("browserPlaceholder")
            .navigationTitle(session.name)
    }
}

struct ProxiesView: View {
    var body: some View {
        Text("Список прокси").navigationTitle("Прокси")
    }
}

/// The web views of open sessions (step 2).
@MainActor
final class SessionRuntimes {
    static let shared = SessionRuntimes()
    func close(_ id: UUID) {}
}
