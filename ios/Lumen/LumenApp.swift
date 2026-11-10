import LumenCore
import SwiftUI
import UIKit

@main
struct LumenApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Text fields offer a clear button while editing, as Safari's address bar does: a long
        // address goes in one touch (and the tests replace one the way a person would).
        UITextField.appearance().clearButtonMode = .whileEditing
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if model.ready {
                    SessionsView()
                } else {
                    ProgressView(L("Подготовка…"))
                }
            }
            .environmentObject(model)
            // Back in front: the account's decision again, and a fresh document if it is due.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.accountTick() }
            }
        }
    }
}
