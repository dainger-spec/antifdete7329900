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
            LaunchRoot()
            .environmentObject(model)
            // Dark, as the app has always been; the light theme behind its flag (Theme.colorScheme).
            // Over a site's light page the window goes light, as Safari's does.
            .preferredColorScheme(model.lightPageShown ? .light : Theme.colorScheme)
            // Back in front: the account's decision again, and a fresh document if it is due.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.accountTick() }
            }
        }
    }
}

/// The launch (p13-launch) and the way out of it: iOS shows the launch screen (UILaunchScreen: the
/// mark, white, on LaunchBackground); its copy, the same image at the same place, stays over the app
/// until the app is ready, then fades away, the mark growing a little as it goes (without the growth
/// when Reduce Motion is on).
struct LaunchRoot: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var curtain = true
    @State private var lifting = false

    var body: some View {
        ZStack {
            if model.ready { SessionsView() }
            if curtain {
                // The whole screen, not the safe area: iOS centres the launch image on the screen.
                ZStack {
                    Color("LaunchBackground")
                    Image("LaunchLogo")
                        .scaleEffect(lifting && !reduceMotion ? 1.18 : 1)
                }
                .ignoresSafeArea()
                .opacity(lifting ? 0 : 1)
                .allowsHitTesting(!lifting)
                .accessibilityHidden(true)
                .zIndex(1)
            }
        }
        .onChange(of: model.ready, initial: true) { _, ready in
            guard ready, !lifting else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.25 : 0.45)) {
                lifting = true
            } completion: {
                curtain = false
            }
        }
    }
}
