import AppKit
import BrowserCore
import Foundation
import os

/// The child process of one profile: `PrivacyBrowser --profile-session <uuid>`.
///
/// Started by the manager process (`ProfileProcess`, which explains why), and given the vault's
/// master key on its standard input — nothing else: the profile to run is in `argv`, the language,
/// locale and time zone are in `argv` and the environment where the system reads them at process
/// start, and the key is the one thing that must not be visible to other processes.
///
/// It then does what the manager used to do in-process: open the vault, launch that one profile
/// with its own `ProfileManager` (proxy lookup, decrypting the WebKit data, cookies, window), and
/// on the way out seal it. Quit, ⌘Q and the `SIGTERM` the manager sends all end up in the same
/// place, because sealing is the one thing that must not be skipped.
@MainActor
enum ProfileSessionHost {
    private static let log = Logger(subsystem: "PrivacyBrowser", category: "ProfileSession")
    private static var delegate: Delegate?

    /// Tells the manager something. One line on standard output, prefixed so that Safari's own
    /// output on the same stream is not read as ours.
    static func send(_ event: ProfileEvent) {
        guard let data = ProfileChannel.encode(event, prefix: ProfileChannel.eventPrefix) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }

    static func start(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--profile-session"),
              arguments.indices.contains(index + 1),
              let profileID = UUID(uuidString: arguments[index + 1]) else {
            FileHandle.standardError.write(Data("--profile-session needs a profile id\n".utf8))
            exit(2)
        }
        // Everything after the key on this stream is commands from the manager.
        guard let key = readMasterKey() else {
            FileHandle.standardError.write(Data("--profile-session expects the vault master key on stdin\n".utf8))
            exit(2)
        }
        // Before NSApplication exists: hosting Safari's chrome means this process has to *be* the
        // kind of application its chrome expects, starting with NSApp itself.
        if SafariChromeHost.prepareForChildProcess() {
            log.notice("Safari's chrome is hosted in this process")
        }
        let delegate = Delegate(profileID: profileID, masterKeyMaterial: key)
        Self.delegate = delegate
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    /// The master key: 32 bytes and end of file. Read before anything else happens, so that a
    /// manager that died meanwhile cannot leave this process waiting with a window open.
    private static func readMasterKey() -> Data? {
        var key = Data()
        while key.count < 32 {
            guard let chunk = try? FileHandle.standardInput.read(upToCount: 32 - key.count), !chunk.isEmpty else { break }
            key.append(chunk)
        }
        return key.count == 32 ? key : nil
    }

    @MainActor
    private final class Delegate: NSObject, NSApplicationDelegate {
        private let profileID: UUID
        private var masterKeyMaterial: Data
        private var manager: ProfileManager?
        private var quitCoordinator: QuitCoordinator?
        private var terminationSource: DispatchSourceSignal?

        init(profileID: UUID, masterKeyMaterial: Data) {
            self.profileID = profileID
            self.masterKeyMaterial = masterKeyMaterial
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            // The manager asks this process to quit with SIGTERM, whose default action would kill
            // it with the profile's data lying decrypted. Routed into the normal quit instead.
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            terminationSource = source

            ProfileChannel.readLines(from: FileHandle.standardInput) { [weak self] line in
                guard let command = ProfileChannel.decode(ProfileCommand.self, from: line) else { return }
                self?.handle(command)
            }
            do {
                let vault = try MasterVault.open(in: AppEnvironment.vaultDirectory, masterKeyMaterial: masterKeyMaterial)
                masterKeyMaterial.withUnsafeMutableBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    memset_s(base, bytes.count, 0, bytes.count)
                }
                let repository = try ProfileRepository(vault: vault)
                let manager = ProfileManager(repository: repository)
                manager.onError = { message in
                    ProfileSessionHost.log.error("\(message, privacy: .public)")
                    // Shown by the manager, which is where the user is looking.
                    ProfileSessionHost.send(.error(message))
                }
                // The profile's last window closed: this process exists for that profile only, so
                // it quits — and quitting is what seals the data.
                manager.onReturnToProfiles = { MainActor.assumeIsolated { NSApp.terminate(nil) } }
                self.manager = manager
                quitCoordinator = QuitCoordinator(
                    hasActivity: { manager.hasActivity },
                    lockForQuit: {
                        manager.prepareForQuit()
                        await manager.shutDown()
                    },
                    terminate: { NSApp.terminate(nil) })
                Task { @MainActor in
                    do {
                        try await manager.launch(self.profileID)
                        ProfileSessionHost.send(.running)
                    } catch {
                        ProfileSessionHost.log.error("Launching \(self.profileID.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                        NSApp.terminate(nil)
                    }
                }
            } catch {
                ProfileSessionHost.log.error("Could not open the vault for \(self.profileID.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                exit(3)
            }
        }

        /// What the manager asked for. Anything that needs the profile's session waits until it
        /// exists: a command can arrive while the launch is still running.
        private func handle(_ command: ProfileCommand) {
            switch command {
            case .stop:
                NSApp.terminate(nil)
            case .activate:
                NSApp.activate(ignoringOtherApps: true)
                manager?.session(for: profileID)?.bringToFront()
            case .showLibrary(let section):
                guard let section = LibraryView.Section(rawValue: section) else { return }
                manager?.showLibrary(profileID, section: section)
            case .showPasswords:
                // The password window is the manager's own screen; from here the most it can do is
                // bring the profile forward so the two are not fighting over the front.
                NSApp.activate(ignoringOtherApps: true)
            case .importCookies(let cookies):
                Task { @MainActor [weak self] in
                    guard let self, let manager = self.manager else { return }
                    let outcome = try? await manager.importCookies(cookies, into: self.profileID)
                    switch outcome {
                    case .applied(let stored, let refused):
                        ProfileSessionHost.send(.cookiesImported(accepted: stored, refused: refused.count))
                    case .queued(let queued):
                        ProfileSessionHost.send(.cookiesImported(accepted: queued, refused: 0))
                    case nil:
                        ProfileSessionHost.send(.error(L("cookies.error.busy")))
                    }
                }
            case .startWarmUp(let plan):
                _ = manager?.startWarmUp(profileID, plan: plan)
            }
        }

        /// Closing the window must not quit before the data is sealed; the quit path does that.
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            quitCoordinator?.shouldTerminate(sender) ?? .terminateNow
        }
    }
}
