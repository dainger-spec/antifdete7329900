import SwiftUI

@main
struct LumenApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.ready {
                    SessionsView()
                } else {
                    ProgressView("Подготовка…")
                }
            }
            .environmentObject(model)
        }
    }
}
