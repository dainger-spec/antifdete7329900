import AppKit
import SwiftUI
import VMControllerCore

/// Backs the menu-bar item: the saved profiles and how many profile VMs are
/// running right now (parsed from `tart list`).
@MainActor
final class MenuBarModel: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var runningCount = 0

    private let store = ProfileStore()
    private let environment: [String: String]

    init() {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LauncherEnvironment.searchPath(env["PATH"])
        environment = env
    }

    func reloadProfiles() {
        profiles = (try? store.list()) ?? []
    }

    /// Reload profiles and recount running VMs. Safe to call often; does nothing
    /// expensive beyond one `tart list`.
    func refresh() async {
        reloadProfiles()
        guard let tart = TartSetup.locate(searchPath: environment["PATH"] ?? "") else {
            runningCount = 0
            return
        }
        let result = try? await GroupProcess.run(tart, ["list"], environment: environment, timeout: 30)
        let output = (result?.lines ?? []).joined(separator: "\n")
        runningCount = TartOutput.runningVMNames(output, prefix: "pb-").count
    }
}

/// The menu shown from the menu-bar icon: a quick list of profiles (click to
/// launch), a running-VM count, and ways back to the main window.
struct MenuBarContent: View {
    @ObservedObject var launcher: LauncherModel
    @ObservedObject var menu: MenuBarModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if menu.profiles.isEmpty {
            Text("Нет профилей")
            Button("Создать профиль…") { activate() }
        } else {
            Text("Профили")
            ForEach(menu.profiles) { profile in
                Button(profile.name) { launch(profile) }
                    .disabled(!launcher.canStart)
            }
        }
        Divider()
        Text(menu.runningCount == 0 ? "Открытых профилей нет" : "Открыто профилей: \(menu.runningCount)")
        Divider()
        Button("Открыть окно") { activate() }
        Button("Обновить") { Task { await menu.refresh() } }
        Divider()
        Button("Выйти") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func launch(_ profile: Profile) {
        activate()
        if launcher.start(profile: profile) {
            openWindow(id: BrowserWindow.id)
        }
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "launcher")
    }
}

/// The menu-bar icon: fills in and shows a count while VMs are running.
struct MenuBarLabel: View {
    @ObservedObject var menu: MenuBarModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: menu.runningCount > 0 ? "shield.lefthalf.filled" : "shield")
            if menu.runningCount > 0 {
                Text("\(menu.runningCount)")
            }
        }
    }
}
