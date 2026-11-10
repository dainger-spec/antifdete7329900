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
                    // The launch: the mark on the ground, and what is going on under it.
                    ZStack {
                        EclipseBackground()
                        VStack(spacing: 28) {
                            LumenMark().fill(Theme.text).frame(width: 104, height: 104).accessibilityHidden(true)
                            Text(L("Подготовка…")).font(.system(size: 15)).foregroundStyle(Theme.tertiary)
                        }
                    }
                }
            }
            .environmentObject(model)
            // Eclipse is a dark look, whatever the iPhone's appearance; white is its accent.
            .preferredColorScheme(.dark)
            .tint(Theme.text)
            // Back in front: the account's decision again, and a fresh document if it is due.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.accountTick() }
            }
        }
    }
}
