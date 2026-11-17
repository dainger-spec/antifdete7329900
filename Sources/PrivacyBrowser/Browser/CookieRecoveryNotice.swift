import AppKit
import BrowserCore
import SwiftUI

/// "Cookies were restored from a snapshot of …", said in the profile's own window after a launch put
/// back cookies its store had lost (docs/COOKIE_RECOVERY.md) — where the person is looking, and
/// without getting in the way: a small panel of its own over the top of the window's page, which
/// never takes the keyboard or activates anything, goes by itself after a few seconds, and closes
/// with its button.
///
/// A window of its own, attached to the profile's: nothing of the profile's window changes — not its
/// toolbar, not the page's size, which a page measures (outerHeight − innerHeight).
@MainActor
enum CookieRecoveryNotice {
    /// How long it stays.
    static var seconds: TimeInterval = 12
    /// The panels on screen, held until they close.
    private static var shown: [NSPanel] = []

    /// The notice's words.
    static func text(_ report: CookieSnapshotKeeper.Report) -> (title: String, detail: String) {
        (String(format: L("cookieRecovery.notice"), report.snapshotTakenAt.shown(date: .abbreviated, time: .shortened)),
         String(format: L("cookieRecovery.notice.detail"), report.restored))
    }

    /// Shows the notice over `session`'s window — Safari's when its chrome is hosted, else ours.
    /// False when the profile has no window on screen yet (a warm-up, an export): it is shown when
    /// one opens.
    @discardableResult
    static func present(_ report: CookieSnapshotKeeper.Report, in session: BrowserSession) -> Bool {
        guard let window = profileWindow(of: session) else { return false }
        let words = text(report)
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let host = NSHostingView(rootView: NoticeView(title: words.title, detail: words.detail) { [weak panel] in
            if let panel { close(panel) }
        })
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.setAccessibilityRole(.popover)
        panel.setAccessibilityLabel(words.title)
        let size = host.fittingSize
        panel.setContentSize(size)
        // Centred over the top of the page, under the toolbar.
        let content = window.convertToScreen(window.contentLayoutRect)
        panel.setFrameOrigin(NSPoint(x: content.midX - size.width / 2, y: content.maxY - size.height - 14))
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        shown.append(panel)
        let seconds = Self.seconds
        Task { @MainActor [weak panel] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if let panel { close(panel) }
        }
        return true
    }

    private static func close(_ panel: NSPanel) {
        guard let index = shown.firstIndex(where: { $0 === panel }) else { return }
        shown.remove(at: index)
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// The window the person sees the profile in: in a profile's own process hosting Safari's chrome,
    /// Safari's browser window (every window of that process is the profile's); otherwise one of the
    /// session's own — never a warm-up's, which nobody sees.
    private static func profileWindow(of session: BrowserSession) -> NSWindow? {
        if SafariChromeHost.isHosting {
            let windows = NSApp.windows.filter { SafariChromeHost.isBrowserWindow($0) && $0.isVisible }
            return windows.first { $0.isKeyWindow } ?? windows.first { $0.isMainWindow } ?? windows.first
        }
        let windows = session.windowControllers.filter { !$0.isForWarmUp }.compactMap(\.window).filter(\.isVisible)
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    /// Whether a notice is on screen now (the self-test's).
    static var isShowing: Bool { !shown.isEmpty }

    private struct NoticeView: View {
        let title: String
        let detail: String
        let close: () -> Void

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clock.arrow.circlepath") // l10n: not text
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ProfileWindowTheme.accent)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ProfileWindowTheme.textPrimary)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(ProfileWindowTheme.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Button(action: close) {
                    Image(systemName: "xmark") // l10n: not text
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ProfileWindowTheme.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("cookieRecovery.notice.close"))
                .accessibilityLabel(L("cookieRecovery.notice.close"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(width: 380, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ProfileWindowTheme.raised))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ProfileWindowTheme.strongBorder, lineWidth: 1))
            .environment(\.colorScheme, .dark)
        }
    }
}
