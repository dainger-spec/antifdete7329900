import SwiftUI
import UIKit

@main
struct LumenApp: App {
    @StateObject private var model = AppModel()

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
                    ProgressView("Подготовка…")
                }
            }
            .environmentObject(model)
        }
    }
}
