import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// What can be added to the proxy list, as Add offers it (the owner, after 0.1.18: OpenVPN and the
/// links were in ⋯ alone, and "as a user I would never find it"). One place offers all three —
/// the Proxies section's Add, its empty list, the profile editor's connection, Settings › Proxies —
/// each said with what it takes.
enum ProxyAddChoice: String, CaseIterable, Identifiable {
    /// One HTTP or SOCKS5 proxy, as one line in any form providers sell.
    case proxy
    /// A VLESS, VMess, Trojan or Shadowsocks share link.
    case link
    /// A provider's `.ovpn` file (docs/OPENVPN.md).
    case openVPN

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .proxy: return "network"
        case .link: return "link"
        case .openVPN: return "lock.shield"
        }
    }

    var title: String {
        switch self {
        case .proxy: return L("proxies.addChoice.proxy")
        case .link: return L("proxies.addChoice.link")
        case .openVPN: return L("proxies.addChoice.openVPN")
        }
    }

    /// What it takes, in a sentence.
    var detail: String {
        switch self {
        case .proxy: return L("proxies.addChoice.proxy.detail")
        case .link: return L("proxies.addChoice.link.detail")
        case .openVPN: return L("proxies.addChoice.openVPN.detail")
        }
    }
}

/// Add asked for from outside the section (Settings › Proxies, a `.ovpn` opened in the Finder):
/// `choice` nil shows the choices; `file` is an OpenVPN file to read at once.
struct ProxyAddRequest: Identifiable, Equatable {
    let id = UUID()
    var choice: ProxyAddChoice?
    var file: URL?
}

/// The choices, each a row with its symbol, its name and what it takes; under them, with
/// `importList`, a list pasted at once. Shown under Add (a popover); the empty list shows the same
/// as tiles (`ProxyEmptyState`).
struct ProxyAddChoicesView: View {
    var choose: (ProxyAddChoice) -> Void
    var importList: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("proxies.addChoice.title"))
                .lumenCaps()
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)
            ForEach(ProxyAddChoice.allCases) { choice in
                ProxyAddChoiceRow(symbol: choice.symbol, title: choice.title, detail: choice.detail) {
                    choose(choice)
                }
            }
            if let importList {
                Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 10)
                ProxyAddChoiceRow(symbol: "list.bullet.rectangle", title: L("proxies.addChoice.list"),
                                  detail: L("proxies.addChoice.list.detail"), action: importList)
            }
        }
        .padding(8)
        .frame(width: 320)
    }
}

private struct ProxyAddChoiceRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raisedInset))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.controlRadius)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Add, with the choices under it: the Proxies section's main button, and the profile editor's
/// (`prominent` false: a quieter one, beside the connection's choice).
struct ProxyAddButton: View {
    var title: String = L("proxies.add")
    var prominent = true
    var choose: (ProxyAddChoice) -> Void
    var importList: (() -> Void)?
    /// Open from outside (Settings › Proxies' Add…).
    var showing: Binding<Bool>?
    @State private var shown = false

    var body: some View {
        let isShown = showing ?? $shown
        Button {
            isShown.wrappedValue = true
        } label: {
            Label(title, systemImage: "plus")
        }
        .buttonStyle(prominent ? LumenButtonStyle(kind: .primary) : LumenButtonStyle(kind: .secondary))
        .help(L("proxies.add.help"))
        .popover(isPresented: isShown, arrowEdge: .bottom) {
            ProxyAddChoicesView(choose: { choice in
                isShown.wrappedValue = false
                choose(choice)
            }, importList: closing(importList, isShown))
            .background(Theme.raised)
        }
    }

    /// `run`, closing the choices first.
    private func closing(_ run: (() -> Void)?, _ isShown: Binding<Bool>) -> (() -> Void)? {
        guard let run else { return nil }
        return {
            isShown.wrappedValue = false
            run()
        }
    }
}

/// Add's sheet: one proxy or one link, as a line (`ProxyEditView`), or an OpenVPN connection
/// (`OpenVPNImportView`) — the line's sheet turns into the OpenVPN one when a `.ovpn` file is
/// chosen or dropped on it, in place.
struct ProxyAddSheet: View {
    @ObservedObject var proxies: ProxyListModel
    var onAdded: (UUID) -> Void = { _ in }
    @State private var choice: ProxyAddChoice
    @State private var file: URL?

    init(proxies: ProxyListModel, request: ProxyAddRequest, onAdded: @escaping (UUID) -> Void = { _ in }) {
        _proxies = ObservedObject(wrappedValue: proxies)
        self.onAdded = onAdded
        _choice = State(initialValue: request.file == nil ? (request.choice ?? .proxy) : .openVPN)
        _file = State(initialValue: request.file)
    }

    var body: some View {
        if choice == .openVPN {
            OpenVPNImportView(proxies: proxies, file: file, onAdded: onAdded)
        } else {
            ProxyEditView(proxies: proxies, entry: nil, profileCount: 0, choice: choice, onOpenVPN: { url in
                file = url
                choice = .openVPN
            }, onAdded: onAdded)
        }
    }
}

/// A file dropped or opened that may be an OpenVPN configuration.
enum OpenVPNFile {
    /// `.ovpn`, or `.conf` (as OpenVPN's own clients name it).
    static func isConfiguration(_ url: URL) -> Bool {
        ["ovpn", "conf"].contains(url.pathExtension.lowercased()) // l10n: not text
    }

    /// The open panel for one: nil when the person cancels.
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ovpn"), UTType(filenameExtension: "conf"), .plainText].compactMap { $0 }
        panel.message = L("openvpn.import.panel")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// The first file of a drop, on the main thread; false when the drop holds no file.
    static func receive(_ providers: [NSItemProvider], _ take: @escaping (URL) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { take(url) }
        }
        return true
    }
}

// MARK: - The empty list

/// The Proxies section with no proxy yet: a title and a line on the horizon in small, as the
/// Profiles' empty list (`LumenEmptyState`), and under them Add's three choices as tiles side by
/// side — stacked in a narrow window — with a list pasted at once as a quiet button below.
struct ProxyEmptyState: View {
    var choose: (ProxyAddChoice) -> Void
    var importList: () -> Void

    var body: some View {
        LumenEmptyState(title: L("proxies.empty.title"), text: L("proxies.empty")) {
            VStack(spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { tiles(width: 184) }
                    VStack(spacing: 10) { tiles(width: 300) }
                }
                Button(L("proxies.empty.list"), action: importList)
                    .buttonStyle(.lumenGhost)
            }
        }
    }

    private func tiles(width: CGFloat) -> some View {
        ForEach(ProxyAddChoice.allCases) { choice in
            ProxyAddTile(choice: choice, width: width) { choose(choice) }
        }
    }
}

/// One of Add's choices as a tile: its symbol in a ring, its name, one short line. The pointer
/// lifts it as it lifts the app's main buttons (a brighter edge, a lighter face, the light under
/// it); a press sinks it to 98 %.
private struct ProxyAddTile: View {
    let choice: ProxyAddChoice
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Image(systemName: choice.symbol)
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.raisedInset))
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                Text(choice.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 14)
                Text(choice.detail)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 22)
            .padding(.bottom, 18)
            .frame(width: width, height: 152)
        }
        .buttonStyle(ProxyTileStyle())
        .accessibilityLabel(choice.title)
        .accessibilityHint(choice.detail)
    }
}

private struct ProxyTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration)
    }

    private struct Tile: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            configuration.label
                .background(shape.fill(hovered ? Theme.raisedInset : Theme.card))
                .background(shape.fill(LinearGradient(colors: [Color.white.opacity(0.04), Color.clear], startPoint: .top, endPoint: .bottom)))
                .overlay(shape.strokeBorder(hovered ? Theme.edgeStrong : Theme.strongBorder, lineWidth: 1))
                .shadow(color: Theme.rim.opacity(hovered ? 0.14 : 0), radius: 18, y: 8)
                .contentShape(shape)
                .scaleEffect(configuration.isPressed && !Motion.isReduced(reduceMotion) ? 0.98 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = isEnabled && $0 }
                .animation(Motion.hover(hovered), value: hovered)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}
