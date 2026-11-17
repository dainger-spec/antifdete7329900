import AppKit
import BrowserCore
import SwiftUI

/// What the bar at the top of a profile's machine's window shows; the helper changes it as the
/// machine runs (on the main thread): the proxy's answer time, the traffic, a word while it closes,
/// a network that does not work.
public final class MachineTitleBarModel: ObservableObject {
    public let name: String
    public let bar: VMHelperRequest.WindowBar
    /// The words (`VMHelperRequest.texts`, the keys `bar.…`); English where one is missing.
    public let texts: [String: String]
    /// How long the proxy took to take a connection, in milliseconds; nil: not measured yet, or it
    /// did not answer (`latencyFailed`).
    @Published public var latency: Int?
    @Published public var latencyFailed = false
    @Published public var bytesUp: UInt64 = 0
    @Published public var bytesDown: UInt64 = 0
    /// "shutting down…", "saving…".
    @Published public var status: String?
    /// "No internet in this machine": the network does not work now.
    @Published public var trouble: String?

    public init(name: String, bar: VMHelperRequest.WindowBar, texts: [String: String]) {
        self.name = name
        self.bar = bar
        self.texts = texts
    }

    func text(_ key: String, _ fallback: String) -> String { texts[key] ?? fallback }

    var locale: Locale { texts["bar.locale"].map(Locale.init(identifier:)) ?? .current }
}

/// The top of a profile's machine's window, in Lumen's dark: the machine's name, then — in one
/// calm line — where it goes out: the exit's flag and country, the proxy, the exit's address, the
/// proxy's answer time, whether UDP goes through, and the traffic. Drawn under the window's own
/// buttons (the window's content takes its whole frame), `leadingInset` clear of them. The system's
/// light-grey title bar with the name alone looked out of place over a dark app.
public struct MachineTitleBar: View {
    @ObservedObject var model: MachineTitleBarModel
    var leadingInset: CGFloat

    public static let background = Color(red: 11.0 / 255, green: 12.0 / 255, blue: 15.0 / 255)
    static let primary = Color(red: 244.0 / 255, green: 244.0 / 255, blue: 245.0 / 255)
    static let secondary = Color(red: 161.0 / 255, green: 161.0 / 255, blue: 170.0 / 255)
    static let tertiary = Color(red: 133.0 / 255, green: 133.0 / 255, blue: 142.0 / 255)
    static let good = Color(red: 95.0 / 255, green: 211.0 / 255, blue: 155.0 / 255)
    static let warning = Color(red: 227.0 / 255, green: 165.0 / 255, blue: 60.0 / 255)

    public init(model: MachineTitleBarModel, leadingInset: CGFloat = 78) {
        self.model = model
        self.leadingInset = leadingInset
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: model.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Self.primary)
                .lineLimit(1)
                .layoutPriority(2)
            if let word = model.status ?? model.trouble {
                Text(verbatim: word)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(model.trouble != nil && model.status == nil ? Self.warning : Self.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            route
                .layoutPriority(1)
            latency
            udp
            traffic
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Self.secondary)
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
        .environment(\.colorScheme, .dark)
    }

    /// "🇩🇪 Germany · de.proxy.example · 203.0.113.30", the whole of it in the tooltip.
    private var route: some View {
        let bar = model.bar
        var parts: [String] = []
        if let country = bar.country, !country.isEmpty { parts.append(country) }
        parts.append(bar.route)
        if let ip = bar.exitIP, !ip.isEmpty { parts.append(ip) }
        let line = parts.joined(separator: " · ")
        return HStack(spacing: 6) {
            if let flag = Self.flag(bar.countryCode) {
                Text(verbatim: flag).font(.system(size: 12))
            }
            Text(verbatim: line)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
        }
        .help(line)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var latency: some View {
        if model.bar.pingHost != nil {
            let text: String = {
                if let ms = model.latency { return String(format: model.text("bar.ping", "%ld ms"), ms) }
                return model.latencyFailed ? model.text("bar.ping.none", "no answer") : "…"
            }()
            HStack(spacing: 4) {
                Circle()
                    .fill(model.latencyFailed ? Self.warning : (model.latency.map { $0 < 300 } ?? false ? Self.good : Self.tertiary))
                    .frame(width: 6, height: 6)
                Text(verbatim: text).monospacedDigit().lineLimit(1)
            }
            .fixedSize()
            .help(model.text("bar.ping.help", "How long the proxy takes to answer, measured every few seconds"))
        }
    }

    @ViewBuilder private var udp: some View {
        if let carried = model.bar.udp {
            Text(verbatim: "WebRTC")
                .font(.system(size: 10.5, weight: .medium))
                .strikethrough(!carried, color: Self.tertiary)
                .foregroundStyle(carried ? Self.secondary : Self.tertiary)
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(Capsule().strokeBorder(Color.white.opacity(carried ? 0.16 : 0.08), lineWidth: 1))
                .fixedSize()
                .help(model.bar.udpText ?? "")
                .accessibilityLabel(model.bar.udpText ?? "WebRTC")
        }
    }

    private var traffic: some View {
        Text(verbatim: "↑ \(bytes(model.bytesUp))  ↓ \(bytes(model.bytesDown))")
            .foregroundStyle(Self.tertiary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .help(model.text("bar.traffic.help", "Sent and received since the start"))
    }

    private func bytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .file).locale(model.locale))
    }

    /// The country's flag as its regional-indicator letters; nil for anything but two letters.
    static func flag(_ code: String?) -> String? {
        guard let code = code?.uppercased(), code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        var flag = ""
        for scalar in code.unicodeScalars {
            guard let indicator = Unicode.Scalar(0x1F1E6 + scalar.value - 65) else { return nil }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }
}
