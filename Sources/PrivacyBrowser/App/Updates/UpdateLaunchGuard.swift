import BrowserCore
import Foundation
import os

/// Before anything of the app runs, as a person opens it (main.swift): an update being installed
/// right now is not ended by this start (docs/UPDATES.md §3). The installer never swaps a bundle a
/// process runs from, so a Lumen opened while it works — a Dock click a moment after quitting — used
/// to end the install, and its next start said so in English, as an error (0.1.18's tester). Now
/// such a start steps aside (`UpdateStepAside`): it leaves word that Lumen is wanted
/// (`UpdateRelaunchWish`) and exits; the installer's window — the same "Installing the update"
/// window the app showed — comes to the front, and the version installed is the one that opens.
///
/// Only for a build with an updater, and only on the installer's own fresh word: a dead installer,
/// a stale marker, another copy of the app or this very version being installed start the app as
/// usual.
@MainActor
enum UpdateLaunchGuard {
    static func stepAsideIfInstalling() {
        guard let configuration = AppUpdater.Configuration.main() else { return }
        let log = Logger(subsystem: "PrivacyBrowser", category: "Updates")
        func decide() -> UpdateStepAside.Decision {
            UpdateStepAside.decide(marker: UpdateInstallMarker.read(from: configuration.staging),
                                   request: try? UpdateRequest.read(from: configuration.staging),
                                   appPath: configuration.app.path, build: configuration.build, now: Date(),
                                   isAlive: UpdateStepAside.isAlive)
        }
        var decision = decide()
        // The quit that asked started its installer a moment ago: its marker comes within a second.
        let until = Date().addingTimeInterval(UpdateStepAside.waitForMarker)
        while decision == .waitForInstaller, Date() < until {
            usleep(200_000)
            decision = decide()
        }
        guard decision == .stepAside else { return }
        do {
            try UpdateRelaunchWish(at: Date()).write(to: configuration.staging)
        } catch {
            // Without the wish nobody would start Lumen at the end: this start goes on instead.
            log.error("An update is being installed, and this start could not ask to be opened after it: \(error.logKind, privacy: .public)")
            return
        }
        log.notice("An update is being installed: this start steps aside, and the installer opens Lumen once it is done")
        exit(0)
    }
}
