import AppKit
import BrowserCore
import SwiftUI

// The update's windows (docs/UPDATES.md §7), shared by the app and its installer helper so that the
// window the app shows while it downloads and checks, and the one the helper shows while it swaps
// and restarts Lumen, are one and the same: the same place, the same size, the same steps. The app
// draws the rest of the update's windows (found, failed, installed) in the same frame
// (`UpdateWindowFrame`). The colours and type are the app's Theme's — the helper links no app code.

/// The app's Theme, as the update's windows use it.
public enum UpdatePalette {
    public static let backdrop = Color(red: 8 / 255, green: 9 / 255, blue: 11 / 255)
    /// The sky over the horizon: a breath lighter than the disc.
    public static let sky = Color(red: 14 / 255, green: 15 / 255, blue: 19 / 255)
    public static let raised = Color(red: 17 / 255, green: 18 / 255, blue: 22 / 255)
    public static let raisedInset = Color(red: 23 / 255, green: 24 / 255, blue: 29 / 255)
    public static let textPrimary = Color(red: 244 / 255, green: 244 / 255, blue: 245 / 255)
    public static let textSecondary = Color(red: 161 / 255, green: 161 / 255, blue: 170 / 255)
    public static let textTertiary = Color(red: 133 / 255, green: 133 / 255, blue: 142 / 255)
    public static let hairline = Color.white.opacity(0.10)
    public static let done = Color(red: 95 / 255, green: 211 / 255, blue: 155 / 255)
    public static let warning = Color(red: 227 / 255, green: 165 / 255, blue: 60 / 255)
    public static let nsBackdrop = NSColor(srgbRed: 8 / 255, green: 9 / 255, blue: 11 / 255, alpha: 1)
}

/// The words of the progress window, in the person's language. The helper has no strings of its own:
/// the app sends them with its request (`UpdateRequest.texts`, these keys — the app's own
/// `updates.progress.…` strings). English where one is missing.
public struct UpdateProgressTexts: Equatable {
    public var title: String
    public var keepOpen: String
    /// "Lumen %@": the version being installed.
    public var version: String
    public var download: String
    public var checking: String
    public var installing: String
    public var relaunching: String
    public var cancel: String
    /// Said once a Lumen opened during the install stepped aside.
    public var opensItself: String

    public static let titleKey = "updates.progress.title"
    public static let keepOpenKey = "updates.progress.keepOpen"
    public static let versionKey = "updates.progress.version"
    public static let downloadKey = "updates.progress.download"
    public static let checkingKey = "updates.progress.checking"
    public static let installingKey = "updates.progress.installing"
    public static let relaunchingKey = "updates.progress.relaunching"
    public static let cancelKey = "updates.progress.cancel"
    public static let opensItselfKey = "updates.progress.opensItself"
    public static let keys = [titleKey, keepOpenKey, versionKey, downloadKey, checkingKey, installingKey, relaunchingKey, cancelKey,
                              opensItselfKey]

    public init(_ texts: [String: String]) {
        title = texts[Self.titleKey] ?? "Installing the update"
        keepOpen = texts[Self.keepOpenKey] ?? "Don’t close Lumen — it restarts by itself."
        version = texts[Self.versionKey] ?? "Lumen %@"
        download = texts[Self.downloadKey] ?? "Download"
        checking = texts[Self.checkingKey] ?? "Checking"
        installing = texts[Self.installingKey] ?? "Installing"
        relaunching = texts[Self.relaunchingKey] ?? "Restarting"
        cancel = texts[Self.cancelKey] ?? "Cancel"
        opensItself = texts[Self.opensItselfKey] ?? "Lumen opens by itself as soon as the update is installed."
    }

    public func step(_ step: UpdateInstallStep) -> String {
        switch step {
        case .checking: return checking
        case .installing: return installing
        case .relaunching: return relaunching
        }
    }
}

/// What the progress window shows now; changed on the main thread.
public final class UpdateProgressModel: ObservableObject {
    public enum Stage: Equatable {
        /// The archive coming: 0…1 (nil: its size is not known yet), and "12.3 MB of 45.6 MB · 20 s
        /// left" in the person's words.
        case downloading(fraction: Double?, detail: String)
        case step(UpdateInstallStep)
    }

    @Published public var stage: Stage
    /// A Lumen opened during the install stepped aside: the window says Lumen opens by itself.
    @Published public var reopened: Bool
    public let version: String
    /// Cancel, offered while downloading; nil: none (the helper's window).
    public var cancel: (() -> Void)?

    public init(version: String, stage: Stage, reopened: Bool = false, cancel: (() -> Void)? = nil) {
        self.version = version
        self.stage = stage
        self.reopened = reopened
        self.cancel = cancel
    }
}

/// The size every update window has, the app's and the helper's: they stand in the same place.
public enum UpdateWindowLayout {
    public static let size = CGSize(width: 520, height: 540)
    /// Where the horizon's rim stands, from the top.
    public static let rimY: CGFloat = 214

    /// A window for the update's content, centred on the screen with the keyboard, dark, its title
    /// bar the content's. `closable`: the found and failed windows may be closed; the progress
    /// window is not, while Lumen is being replaced.
    @MainActor
    public static func window(closable: Bool, title: String) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .fullSizeContentView]
        if closable { style.insert(.closable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = UpdatePalette.nsBackdrop
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        return window
    }
}

/// The eclipse's horizon the lock screen stands on, drawn small: a dark disc rising from below,
/// light breaking along its rim, a haze above it. Decoration only.
public struct UpdateHorizon: View {
    public var rimY: CGFloat

    public init(rimY: CGFloat = UpdateWindowLayout.rimY) {
        self.rimY = rimY
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let radius = max(width * 1.2, 640)
            let centre = CGPoint(x: width / 2, y: rimY + radius)
            ZStack {
                LinearGradient(colors: [UpdatePalette.backdrop, UpdatePalette.sky], startPoint: .top, endPoint: .init(x: 0.5, y: 0.4))
                // The haze over the rim.
                Ellipse()
                    .fill(RadialGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.03), .clear],
                                         center: .center, startRadius: 0, endRadius: width * 0.42))
                    .frame(width: width * 1.05, height: 150)
                    .position(x: width / 2, y: rimY + 6)
                    .blur(radius: 14)
                // The disc.
                Circle()
                    .fill(UpdatePalette.backdrop)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(centre)
                // Its rim: a glow, and a hairline of light brightest at the top.
                Circle()
                    .stroke(rimLight(0.45), lineWidth: 7)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(centre)
                    .blur(radius: 7)
                Circle()
                    .stroke(rimLight(0.95), lineWidth: 1.1)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(centre)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func rimLight(_ strength: Double) -> AngularGradient {
        // Brightest at the top of the disc (-90°), gone by a quarter turn either way.
        AngularGradient(stops: [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(0), location: 0.62),
            .init(color: .white.opacity(strength), location: 0.75),
            .init(color: .white.opacity(0), location: 0.88),
            .init(color: .white.opacity(0), location: 1),
        ], center: .center, startAngle: .degrees(0), endAngle: .degrees(360))
    }
}

/// Every update window's frame: the app's icon in the sky over the horizon, a title and a line
/// under it, then the window's own content on the disc, its buttons at the foot.
public struct UpdateWindowFrame<Content: View, Buttons: View>: View {
    let icon: NSImage?
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let buttons: () -> Buttons

    public init(icon: NSImage?, title: String, subtitle: String, @ViewBuilder content: @escaping () -> Content,
                @ViewBuilder buttons: @escaping () -> Buttons) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.buttons = buttons
    }

    public var body: some View {
        ZStack(alignment: .top) {
            UpdateHorizon()
            VStack(spacing: 0) {
                Group {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 72, height: 72)
                            .shadow(color: Color.white.opacity(0.14), radius: 18)
                    } else {
                        Color.clear.frame(width: 72, height: 72)
                    }
                }
                .accessibilityHidden(true)
                .padding(.top, 40)
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.44)
                    .foregroundStyle(UpdatePalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(UpdatePalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 34)
                HStack(spacing: 10) {
                    buttons()
                }
                .padding(.bottom, 26)
            }
            .padding(.horizontal, 40)
        }
        .frame(width: UpdateWindowLayout.size.width, height: UpdateWindowLayout.size.height)
        .background(UpdatePalette.backdrop)
        .environment(\.colorScheme, .dark)
    }
}

/// "Installing the update — don't close Lumen": the download's bar (the app's window), then the
/// steps checking → installing → restarting, each ticked off as it is done.
public struct UpdateProgressView: View {
    @ObservedObject var model: UpdateProgressModel
    let texts: UpdateProgressTexts
    let icon: NSImage?

    public init(model: UpdateProgressModel, texts: UpdateProgressTexts, icon: NSImage?) {
        self.model = model
        self.texts = texts
        self.icon = icon
    }

    private enum Row: Hashable {
        case download
        case step(UpdateInstallStep)
    }

    private var rows: [Row] { [.download] + UpdateInstallStep.allCases.map { .step($0) } }

    /// Where the install is, as a row's place in `rows`.
    private var current: Int {
        switch model.stage {
        case .downloading: return 0
        case .step(let step): return 1 + (UpdateInstallStep.allCases.firstIndex(of: step) ?? 0)
        }
    }

    public var body: some View {
        UpdateWindowFrame(icon: icon, title: texts.title,
                          subtitle: String(format: texts.version, model.version) + " · " + (model.reopened ? texts.opensItself : texts.keepOpen)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                    rowView(row, index: index)
                }
            }
            .frame(width: 300, alignment: .leading)
            .frame(maxWidth: .infinity)
        } buttons: {
            if case .downloading = model.stage, let cancel = model.cancel {
                Button(texts.cancel, action: cancel)
                    .buttonStyle(UpdateButtonStyle(primary: false))
                    .keyboardShortcut(.cancelAction)
            } else {
                // The same room whether Cancel is there or not: the steps do not move.
                Color.clear.frame(height: 32)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func rowView(_ row: Row, index: Int) -> some View {
        let state: StepMark.State = index < current ? .done : (index == current ? .now : .later)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                StepMark(state: state)
                Text(title(row))
                    .font(.system(size: 14, weight: state == .now ? .semibold : .medium))
                    .foregroundStyle(state == .later ? UpdatePalette.textTertiary : UpdatePalette.textPrimary)
                Spacer(minLength: 0)
            }
            if row == .download, case let .downloading(fraction, detail) = model.stage {
                VStack(alignment: .leading, spacing: 6) {
                    DownloadBar(fraction: fraction)
                    Text(detail)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(UpdatePalette.textSecondary)
                }
                .padding(.leading, 30)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 9)
        .animation(.easeOut(duration: 0.25), value: model.stage)
        .accessibilityElement(children: .combine)
    }

    private func title(_ row: Row) -> String {
        switch row {
        case .download: return texts.download
        case .step(let step): return texts.step(step)
        }
    }
}

/// A step's mark: ticked when done, a turning ring while under way, a quiet circle before.
struct StepMark: View {
    enum State { case done, now, later }
    let state: State

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(UpdatePalette.done.opacity(0.16))
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(UpdatePalette.done)
            case .now:
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 2)
                TimelineView(.animation) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(UpdatePalette.textPrimary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360))
                }
            case .later:
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 1.5)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}

/// The download's bar, 4 pt: its track at 12 % white, a white fill; with no size yet, a segment
/// sweeping along.
struct DownloadBar: View {
    let fraction: Double?
    var width: CGFloat = 270

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.12))
            if let fraction {
                Capsule().fill(UpdatePalette.textPrimary)
                    .frame(width: max(4, width * min(max(fraction, 0), 1)))
                    .animation(.easeOut(duration: 0.2), value: fraction)
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    Capsule().fill(UpdatePalette.textPrimary)
                        .frame(width: width * 0.3)
                        .offset(x: -width * 0.3 + width * 1.3 * t)
                }
            }
        }
        .frame(width: width, height: 4)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: fraction.map { "\(Int(($0 * 100).rounded())) %" } ?? ""))
    }
}

/// The update windows' buttons where the app's own styles are not at hand (the helper): the app's
/// contour buttons (`LumenButtonStyle`), drawn the same — the main one 32 pt with an edge lit from
/// above, the other quieter.
public struct UpdateButtonStyle: ButtonStyle {
    let primary: Bool

    public init(primary: Bool) {
        self.primary = primary
    }

    public func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: primary ? 10 : 9, style: .continuous)
        return configuration.label
            .font(.system(size: 13, weight: primary ? .semibold : .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(height: primary ? 32 : 28)
            .foregroundStyle(UpdatePalette.textPrimary)
            .background(shape.fill(primary ? UpdatePalette.raised : UpdatePalette.raised.opacity(0.6)))
            .background(shape.fill(LinearGradient(colors: [Color.white.opacity(primary ? 0.05 : 0), .clear],
                                                  startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(primary
                                        ? AnyShapeStyle(LinearGradient(colors: [Color.white.opacity(0.46), Color.white.opacity(0.26)],
                                                                       startPoint: .top, endPoint: .bottom))
                                        : AnyShapeStyle(Color.white.opacity(0.16)), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(shape)
    }
}
