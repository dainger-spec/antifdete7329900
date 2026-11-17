#if arch(arm64)
import AppKit
import BrowserCore
import Foundation
import MachineCover
import SwiftUI

/// A SwiftUI view over the machine's screen that takes every click and scroll on it while it is
/// up, and none once it is going (`passesEvents`). NSHostingView answers AppKit's hit test for
/// itself where none of its content does: inside its frame that is what is wanted here; outside
/// it (the title bar) it answers nothing.
final class CoverHost<Content: View>: NSHostingView<Content> {
    var passesEvents = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !passesEvents, !isHiddenOrHasHiddenAncestor, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
}

/// A machine's screen in its window, and the cover over it while a start's settings are put in
/// place. While covered the machine's own view is hidden — a hidden view takes no event, and its
/// tracking areas none either — and this view is the window's first responder: every key, and
/// every key equivalent, ends here. Nothing reaches the guest.
final class MachineScreen: NSView {
    var covered = false

    override var acceptsFirstResponder: Bool { covered }
    override func keyDown(with event: NSEvent) { if !covered { super.keyDown(with: event) } }
    override func keyUp(with event: NSEvent) { if !covered { super.keyUp(with: event) } }
    override func flagsChanged(with event: NSEvent) { if !covered { super.flagsChanged(with: event) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { covered || super.performKeyEquivalent(with: event) }
}

/// The cover over a profile's machine's screen from the start of its macOS until its guest says
/// this start's settings are in (docs/VM.md, "The start's cover"): what the person opened before
/// that — Safari, in the base's language — stayed as it was opened.
///
/// The helper reads the guest's status file itself, once a second, off the main thread and as a
/// file of the guest's (`VMShareFile`), and `VMStartCover` decides from it: the step the cover
/// names, "Show the screen" after a minute, and when it goes — the guest's word, the person's
/// click, or the limits. A machine shown as a browser is let in once Safari is open: the runner
/// puts Safari over the machine's screen first (`onSafariOpen`), then calls `reveal`.
@MainActor
final class StartCover {
    private let model: MachineCoverModel
    private let host: CoverHost<MachineCoverView>
    private weak var screen: MachineScreen?
    private weak var machineView: NSView?
    private let statusURL: URL
    private let revision: String
    private let browserMode: Bool
    private let startedAt: Date
    private var watching: Task<Void, Never>?
    /// Up: neither going nor gone.
    private(set) var isUp = true
    /// The guest says Safari is open in a machine shown as a browser.
    var onSafariOpen: (() -> Void)?

    /// Puts the cover over `machineView` in `screen` at once.
    init(screen: MachineScreen, machineView: NSView, request: VMHelperRequest, statusURL: URL, startedAt: Date) {
        self.screen = screen
        self.machineView = machineView
        self.statusURL = statusURL
        revision = request.settingsRevision ?? ""
        browserMode = request.browserMode == true
        self.startedAt = startedAt
        let model = MachineCoverModel(name: request.windowTitle, texts: MachineCoverTexts(request.texts))
        self.model = model
        host = CoverHost(rootView: MachineCoverView(model: model, reducesMotion: request.reducesMotion == true))
        model.showScreen = { [weak self] in self?.personAsked() }

        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: screen.topAnchor),
            host.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
        ])
        machineView.isHidden = true
        screen.covered = true
        screen.window?.makeFirstResponder(screen)
        HelperIO.log("cover: up until the guest says this start's settings are in")
        watch()
    }

    /// The status file, once a second, until the cover goes.
    private func watch() {
        let url = statusURL
        watching = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let (status, written) = await Task.detached(priority: .utility) { () -> (VMGuestStatus?, Date?) in
                    // The time first: a file put in place meanwhile is then taken as older, not newer.
                    let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                    return (try? VMGuestStatus.read(from: url).get(), written)
                }.value
                guard let self, self.isUp, !Task.isCancelled else { return }
                self.take(status, written: written)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func take(_ status: VMGuestStatus?, written: Date?) {
        let state = VMStartCover.state(status: status, written: written, startedAt: startedAt, revision: revision,
                                       browserMode: browserMode, now: Date())
        if model.stage != state.stage { model.stage = state.stage }
        if model.offersReveal != state.offersReveal { model.offersReveal = state.offersReveal }
        guard let reveal = state.reveal else { return }
        stopWatching()
        let seconds = Int(Date().timeIntervalSince(startedAt).rounded())
        switch reveal {
        case .timedOut:
            HelperIO.log("cover: the guest did not say its settings are in after \(seconds) s (at \(state.stage.rawValue)); "
                + "the screen is shown as it is")
            self.reveal(note: model.texts.timedOut)
        case .ready, .applied:
            HelperIO.log("cover: the guest says this start's settings are in, after \(seconds) s (\(reveal.rawValue))")
            if browserMode, let onSafariOpen {
                // Safari is put over the machine's screen by keys made for its view: the view is
                // shown again under the cover, which still takes every click.
                model.stage = .ready
                machineView?.isHidden = false
                onSafariOpen()
            } else {
                self.reveal()
            }
        }
    }

    /// "Show the screen": the person's choice, whatever the guest is at.
    private func personAsked() {
        guard isUp else { return }
        HelperIO.log("cover: the person asked for the screen after \(Int(Date().timeIntervalSince(startedAt).rounded())) s, "
            + "at \(model.stage.rawValue)")
        reveal()
    }

    /// The machine is shutting down or being put to sleep: the cover stays as it is, and is no
    /// longer taken away.
    func halt() {
        stopWatching()
    }

    private func stopWatching() {
        watching?.cancel()
        watching = nil
    }

    /// Gives the machine's screen to the person: its view shown and taking the keys at once, the
    /// cover's dashes filled, its words gone and the cover faded into the screen under it
    /// (`MachineCoverTiming`), then taken away. `note`: a word about why, at the top for a while.
    func reveal(note: String? = nil) {
        guard isUp else { return }
        isUp = false
        stopWatching()
        model.stage = .ready
        model.offersReveal = false
        model.leaving = true
        host.passesEvents = true
        machineView?.isHidden = false
        screen?.covered = false
        if let machineView { machineView.window?.makeFirstResponder(machineView) }
        let host = self.host
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(MachineCoverTiming.gone * 1_000_000_000))
            host.removeFromSuperview()
        }
        if let note, let screen { show(note, in: screen) }
    }

    /// A word over the machine's screen for eight seconds; it takes no click.
    private func show(_ note: String, in screen: MachineScreen) {
        let noteHost = CoverHost(rootView: MachineCoverNote(text: note))
        noteHost.passesEvents = true
        noteHost.sizingOptions = []
        noteHost.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(noteHost)
        NSLayoutConstraint.activate([
            noteHost.topAnchor.constraint(equalTo: screen.topAnchor),
            noteHost.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            noteHost.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            noteHost.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
        ])
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            // In an async context the compiler takes the async form, which returns when the fade ends.
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                noteHost.animator().alphaValue = 0
            }
            noteHost.removeFromSuperview()
        }
    }
}
#endif
