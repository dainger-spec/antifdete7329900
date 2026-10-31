import AppKit
import SwiftUI

/// A profile whose window is the app's own rather than Safari's runs in a simplified mode: what
/// makes a profile Safari to a site — Safari's frameworks hosting its window — is not there, and
/// the window is WebKit's alone. Its proxy and its data are the same; matching Safari is not.
///
/// Said in the window itself, never only in the log (a person cannot check this for themselves,
/// and finding it out from what sites do is the worst way to): a chip in the window's toolbar,
/// always there, whose tooltip gives the reason, and whose popover — opened by itself once, the
/// first time a window of this process becomes key, and on a click after that — says what the mode
/// is and why. In the toolbar, not a bar above the page: the toolbar's height is Safari's, and a
/// page measures the chrome around it (outerHeight − innerHeight).
@MainActor
enum SimplifiedModeNotice {
    /// Whether the popover opens by itself once: in the app as a person runs it — its manager, and a
    /// profile's own process (main.swift). Not where windows are driven with no one looking at them
    /// (the self-test, the UI snapshots, CI's measurements), whose pages must keep their focus.
    static var presentsAutomatically = false
    private static var presentedAutomatically = false
    /// The popover last shown (held: one not held can go as soon as it is shown).
    private(set) static var shown: NSPopover?

    /// Why, as the popover and the chip's tooltip say it.
    nonisolated static func reasonText(_ reason: SafariChromeHost.OwnWindowReason) -> String {
        switch reason {
        case .deviceProfile: return L("simplified.reason.device")
        case .sandboxed: return L("simplified.reason.sandboxed")
        case .turnedOff: return L("simplified.reason.turnedOff")
        case .tunnelProfile: return L("simplified.reason.tunnel")
        case .notInProfileProcess: return L("simplified.reason.noProfileProcess")
        case .frameworksDidNotLoad: return L("simplified.reason.frameworks")
        case .missingPieces(let names): return String(format: L("simplified.reason.missingPieces"), names.joined(separator: ", "))
        case .notSafarisApplication: return L("simplified.reason.notSafarisApplication")
        case .windowDidNotOpen: return L("simplified.reason.windowDidNotOpen")
        }
    }

    /// The popover under `view` (the chip), once per process when it opens by itself.
    static func presentAutomaticallyOnce(from view: NSView, reason: SafariChromeHost.OwnWindowReason) {
        guard presentsAutomatically, !presentedAutomatically, view.window?.isVisible == true else { return }
        presentedAutomatically = true
        present(from: view, reason: reason)
    }

    static func present(from view: NSView, reason: SafariChromeHost.OwnWindowReason) {
        if let shown, shown.isShown {
            shown.performClose(nil)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = Theme.chromeAppearance
        popover.contentViewController = NSHostingController(rootView: SimplifiedModeExplanation(reason: reason))
        // Under the chip, which is in the toolbar: the bottom edge, whichever way the view is drawn.
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        shown = popover
    }
}

/// The chip in a profile's own window: "Simplified mode", in the warning colour the app gives a
/// proxy that needs attention.
struct SimplifiedModeChip: View {
    let reason: SafariChromeHost.OwnWindowReason
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text(L("simplified.chip"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.warning)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.warning.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.warning.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(SimplifiedModeNotice.reasonText(reason))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("simplified.chip")))
        .accessibilityValue(Text(SimplifiedModeNotice.reasonText(reason)))
        .environment(\.colorScheme, .dark)
    }
}

/// What the chip's popover says: the mode, what it means, and why this window is in it.
struct SimplifiedModeExplanation: View {
    let reason: SafariChromeHost.OwnWindowReason

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(L("simplified.title")).font(.lumenSheetTitle)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
            Text(L("simplified.body"))
                .font(.lumenBody)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(format: L("simplified.why"), SimplifiedModeNotice.reasonText(reason)))
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .environment(\.colorScheme, .dark)
    }
}
