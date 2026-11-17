import AppKit
import BrowserCore
import SwiftUI
import UpdateProgress

/// What the update's window shows (docs/UPDATES.md §7).
enum UpdateWindowMode: Equatable {
    /// What the updater has: checking, up to date, a release found (with its notes, Update and
    /// Restart, Later), downloading in the background, a failure (Try Again), or a place the app
    /// cannot be replaced in.
    case updater
    /// After "Update and Restart": the download's bar, then the checks — the window cannot be
    /// closed, and Lumen quits at the end; the installer's own window takes over in its place.
    case installing
    /// An update that did not happen, in calm words (`UpdateOutcome.kind`, the quit's gate):
    /// Install Now when the release is still here, else Try Again.
    case notice(String)
    /// The first launch of a new version: "Update installed — Lumen 0.1.x", what is new, Continue.
    case installed(InstalledUpdate)
}

/// The first launch of a new version: "Update installed — Lumen 0.1.x", and what is new.
struct InstalledUpdate: Equatable {
    var version: String
    /// The release's notes, as the feed gave them (plain text); empty: none.
    var notes: String
}

/// The update's window: one window of its own (AppKit's, so that it opens over the lock screen as
/// well as the profiles, from the menu or by itself), the size and place of the installer's — the
/// two stand where the other stood when Lumen hands over to its installer.
@MainActor
final class UpdateWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(model: AppModel, focus: Bool) {
        let window = self.window ?? make(model: model)
        if focus {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    /// While Lumen is being replaced the window stays: no close button, above the app's others.
    func update(closable: Bool, floating: Bool) {
        guard let window else { return }
        if closable { window.styleMask.insert(.closable) } else { window.styleMask.remove(.closable) }
        window.level = floating ? .floating : .normal
    }

    func close() {
        window?.orderOut(nil)
    }

    private func make(model: AppModel) -> NSWindow {
        let window = UpdateWindowLayout.window(closable: true, title: L("updates.window.title"),
                                               content: UpdateWindowView().environmentObject(model))
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                               queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.updateWindowClosed() }
        }
        self.window = window
        return window
    }
}

/// The update window's content for the model's mode.
struct UpdateWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.updateWindowMode {
            case .installing?:
                if let progress = model.updateProgress {
                    UpdateProgressView(model: progress, texts: UpdateProgressTexts(AppUpdater.progressTexts))
                } else {
                    UpdaterPanel(updater: model.updater)
                }
            case .notice(let text)?:
                UpdateNoticePanel(text: text, canInstall: model.updater?.isReady ?? false,
                                  install: { Task { await model.installUpdateNow() } },
                                  retry: {
                                      model.showUpdateWindow(.updater, focus: true)
                                      Task { await model.updater?.checkNow() }
                                  },
                                  close: { model.closeUpdateWindow() })
            case .installed(let update)?:
                UpdateInstalledPanel(update: update, dismiss: { model.closeUpdateWindow() })
            case .updater?, nil:
                UpdaterPanel(updater: model.updater)
            }
        }
        .preferredColorScheme(.dark)
    }
}

enum UpdatePanels {
    /// "0.1.18" — the version running.
    static var runningVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}

/// The window as the updater has it. Without an updater (a build with no feed), it says so.
struct UpdaterPanel: View {
    let updater: AppUpdater?

    var body: some View {
        if let updater {
            UpdaterStatePanel(updater: updater)
        } else {
            UpdateWindowFrame(title: L("updates.unavailable.title"),
                              subtitle: String(format: L("updates.progress.version"), UpdatePanels.runningVersion)) {
                UpdatePanelText(L("updates.unavailable"))
            } buttons: {
                UpdateCloseButton()
            }
        }
    }
}

private struct UpdateCloseButton: View {
    @EnvironmentObject private var model: AppModel
    var primary = false

    var body: some View {
        Button(L("common.close")) { model.closeUpdateWindow() }
            .buttonStyle(LumenButtonStyle(kind: primary ? .primary : .secondary))
            .keyboardShortcut(primary ? KeyboardShortcut.defaultAction : KeyboardShortcut.cancelAction)
    }
}

/// A paragraph of the window, centred under its title.
struct UpdatePanelText: View {
    let text: String
    var tone: Color = Theme.textSecondary

    init(_ text: String, tone: Color = Theme.textSecondary) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.lumenBody)
            .foregroundStyle(tone)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 400)
            .frame(maxWidth: .infinity)
    }
}

/// What is new, as the feed says it: plain text, never a page — nothing of the feed is rendered by
/// WebKit outside a profile. A list when the feed writes one ("•", "-", "*" at the lines' starts),
/// else its paragraphs as they are; long lines wrap. Never taller than about six lines, whatever
/// the notes' length — the window does not grow with them —: the rest scrolls inside, under a soft
/// fade at the foot. No notes: no section (`isEmpty`).
struct UpdateNotesList: View {
    let caption: String
    let notes: String
    /// About six lines of the body's type.
    static let maximumHeight: CGFloat = 118
    @State private var height: CGFloat = 0

    static func isEmpty(_ notes: String) -> Bool { notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The notes as points: their lines without the list marks — or nil when the feed wrote no
    /// list, and the notes are paragraphs.
    static func points(_ notes: String) -> [String]? {
        let lines = notes.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func marked(_ line: String) -> Bool { line.first.map { "•-*–".contains($0) } ?? false }
        guard lines.contains(where: marked) else { return nil }
        return lines.map { marked($0) ? String($0.dropFirst()).trimmingCharacters(in: .whitespaces) : $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption)
                .lumenCaps()
            ScrollView {
                list
                    .padding(.bottom, height > Self.maximumHeight ? 14 : 0)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: NotesHeight.self, value: geometry.size.height)
                    })
            }
            .scrollIndicators(height > Self.maximumHeight ? .automatic : .never)
            .frame(height: min(max(height, 1), Self.maximumHeight))
            .mask(alignment: .top) {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: height > Self.maximumHeight ? 0.78 : 1),
                                       .init(color: .black.opacity(height > Self.maximumHeight ? 0 : 1), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .onPreferenceChange(NotesHeight.self) { height = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var list: some View {
        if let points = Self.points(notes) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(verbatim: "•") // l10n: not text
                            .font(.lumenBody)
                            .foregroundStyle(Theme.textTertiary)
                        Text(verbatim: point) // l10n: the feed's own text
                            .font(.lumenBody)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(verbatim: notes.trimmingCharacters(in: .whitespacesAndNewlines)) // l10n: the feed's own text
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NotesHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Checking, up to date, found, downloading in the background, failed, not installable here.
struct UpdaterStatePanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var updater: AppUpdater

    var body: some View {
        switch updater.state {
        case .idle, .checking:
            UpdateWindowFrame(title: L("updates.checking.title"),
                              subtitle: String(format: L("updates.progress.version"), UpdatePanels.runningVersion)) {
                LumenActivityLine(width: 200).padding(.vertical, 8)
            } buttons: {
                UpdateCloseButton()
            }
        case .upToDate:
            UpdateWindowFrame(title: L("updates.upToDate.title"),
                              subtitle: String(format: L("updates.upToDate.text"), UpdatePanels.runningVersion)) {
                EmptyView()
            } buttons: {
                Button(L("common.done")) { model.closeUpdateWindow() }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        case .available(let item), .downloading(let item), .ready(let item):
            UpdateFoundPanel(item: item, background: updater.downloadProgress.map { model.downloadDetail($0) },
                             stops: model.updateStopsList(),
                             update: { Task { await model.updateAndRestart() } },
                             later: { model.closeUpdateWindow(later: true) })
        case .blocked(let item, let block):
            UpdateWindowFrame(title: L("updates.blocked.title"),
                              subtitle: String(format: L("updates.progress.version"), item.version)) {
                UpdatePanelText(String(format: block == .translocated ? L("updates.state.translocated") : L("updates.state.notWritable"),
                                       item.version))
            } buttons: {
                UpdateCloseButton(primary: true)
            }
        case .failed(let reason):
            UpdateFailedPanel(release: updater.failedRelease?.version, reason: reason,
                              retry: { Task { await updater.retry() } }, close: { model.closeUpdateWindow() })
        }
    }
}

/// "Lumen 0.1.19 is available": what is new, its size, Update and Restart (the default) and Later.
/// With profiles running, what Update and Restart stops is said above the buttons — it asks
/// nothing more: the press is the answer.
struct UpdateFoundPanel: View {
    let item: AppcastItem
    /// Downloading in the background: "12.3 MB of 45.6 MB · …".
    var background: String?
    var stops: [String] = []
    let update: () -> Void
    let later: () -> Void

    private var size: String {
        Int64(item.length).formatted(.byteCount(style: .file).locale(Localization.locale))
    }

    var body: some View {
        UpdateWindowFrame(title: String(format: L("updates.found.title"), item.version),
                          subtitle: String(format: L("updates.found.subtitle"), UpdatePanels.runningVersion, size)) {
            VStack(alignment: .leading, spacing: 14) {
                if !UpdateNotesList.isEmpty(item.notes) {
                    UpdateNotesList(caption: L("updates.found.notes"), notes: item.notes)
                }
                if !stops.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("updates.found.stops"))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textPrimary)
                        Text(verbatim: stops.prefix(4).map { "• " + $0 }.joined(separator: "\n")
                             + (stops.count > 4 ? "\n…" : "")) // l10n: the profiles' names
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(5)
                    }
                } else if let background {
                    Text(String(format: L("updates.found.background"), background))
                        .font(.lumenSecondary.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Text(L("updates.found.restartNote"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        } buttons: {
            Button(L("updates.found.later"), action: later)
                .buttonStyle(.lumenSecondary)
                .keyboardShortcut(.cancelAction)
            Button(L("updates.found.update"), action: update)
                .buttonStyle(.lumenPrimary)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// A check or a download that failed, in the person's words, with Try Again.
struct UpdateFailedPanel: View {
    /// The release whose download failed; nil: the check failed.
    let release: String?
    let reason: String
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        UpdateWindowFrame(title: release == nil ? L("updates.checking.failedTitle") : L("updates.failed.title"),
                          subtitle: String(format: L("updates.progress.version"), release ?? UpdatePanels.runningVersion)) {
            UpdatePanelText(release.map { String(format: L("updates.failed.text"), $0, reason) }
                            ?? String(format: L("updates.failed.check"), reason))
        } buttons: {
            Button(L("common.close"), action: close)
                .buttonStyle(.lumenSecondary)
                .keyboardShortcut(.cancelAction)
            Button(L("updates.retry"), action: retry)
                .buttonStyle(.lumenPrimary)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// An update that did not happen — at the last quit, or Install Now just now — said calmly, with
/// what can be done: Install Now while the release is still here, else Try Again.
struct UpdateNoticePanel: View {
    let text: String
    let canInstall: Bool
    let install: () -> Void
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        UpdateWindowFrame(title: L("updates.outcome.title"),
                          subtitle: String(format: L("updates.progress.version"), UpdatePanels.runningVersion)) {
            UpdatePanelText(text)
        } buttons: {
            Button(L("updates.found.later"), action: close)
                .buttonStyle(.lumenSecondary)
                .keyboardShortcut(.cancelAction)
            if canInstall {
                Button(L("updates.installNowButton"), action: install)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L("updates.retry"), action: retry)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The first launch of a new version: "Update installed — Lumen 0.1.19", what is new, Continue —
/// the update's window like the others, once per update, over the lock screen. It is shown without
/// the keyboard (the lock screen's password field keeps it), and the first key typed puts it away
/// and goes on to the field, so a password typed at once is typed whole; Continue has no Return.
struct UpdateInstalledPanel: View {
    let update: InstalledUpdate
    let dismiss: () -> Void
    /// The snapshots: no key watching.
    var still = false
    @State private var keyMonitor: Any?

    var body: some View {
        UpdateWindowFrame(title: L("updates.installed.title"),
                          subtitle: String(format: L("updates.installed.version"), update.version)) {
            if !UpdateNotesList.isEmpty(update.notes) {
                UpdateNotesList(caption: L("updates.installed.notes"), notes: update.notes)
            }
        } buttons: {
            Button(L("updates.installed.continue"), action: dismiss)
                .buttonStyle(.lumenPrimary)
                .focusable(false)
        }
        .onAppear {
            guard !still, keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { dismiss() }
                return event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }
}

/// The sidebar's row while a release waits — found, downloading, ready — whatever was said of it:
/// it opens the update's window.
struct UpdateSidebarRow: View {
    let offer: UpdateOffer
    let action: () -> Void
    @State private var hovered = false

    private var detail: String {
        switch offer.stage {
        case .ready: return String(format: L("updates.sidebar.ready"), offer.version)
        case .downloading: return String(format: L("updates.sidebar.downloading"), offer.version)
        case .available, .blocked: return String(format: L("updates.sidebar.available"), offer.version)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("updates.sidebar.title"))
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.lumenCaption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovered ? Theme.rowHover : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityIdentifier("update-sidebar-row")
    }
}
