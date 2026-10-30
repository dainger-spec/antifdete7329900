import BrowserCore
import SwiftUI

// MARK: - What the field holds

/// A proxy typed or pasted into one field, wherever one proxy is entered: a profile's editor, the
/// list's Edit sheet. The field takes the strings providers sell —
///
///     host:port:user:pass
///     user:pass@host:port
///     scheme://user:pass@host:port      (socks5, socks5h, socks, http, https)
///     host:port
///
/// — and reads them as a line of a pasted list is read (`ProxyListImport.readField`): one parser for
/// the field and the import. The type comes from the scheme. A line without one gets the type a
/// check finds — both handshakes are tried, and the one that answers is the type (`ProxyProbe`) —
/// or, while it still names the same proxy, the type already known for it (the list entry's, the
/// profile's). Until then the type is not known, and nothing acts on a guess.
struct ProxyLine: Equatable {
    var text: String
    /// The last check run from the field, and the proxy it checked: it speaks for the field only
    /// while the field still names that proxy, reached the same way (`currentCheck`).
    var check: Check?
    /// The type known for a proxy from before: a line without a scheme takes it while it names
    /// that proxy (the same host, port and user name).
    var knownKind: KnownKind?

    struct Check: Equatable {
        var proxy: ProxySettings
        var result: ProxyCheckResult
    }

    struct KnownKind: Equatable {
        /// `ProxyList.identity(of:)`.
        var identity: String
        var kind: ProxySettings.Kind
        var tlsToProxy: Bool
    }

    /// Where the type comes from.
    enum KindSource: Equatable {
        /// The line's scheme.
        case scheme
        /// A check: the line has no scheme.
        case check
        /// A check, against the line's scheme: the proxy answers as this type only (as the list
        /// corrects an entry, `ProxyList.record`).
        case corrected(from: ProxySettings.Kind)
        /// What was known for this proxy before.
        case known
    }

    enum Reading: Equatable {
        case empty
        /// Not one proxy: what to say under the field, in plain words.
        case problem(String)
        /// A proxy whose type is known.
        case proxy(ProxySettings, KindSource)
        /// A proxy without a scheme whose type no check has found yet: its `kind` is a placeholder.
        case kindUnknown(ProxySettings)
    }

    init(text: String = "") {
        self.text = text
    }

    /// `proxy` as the field shows it (`ProxyListImport.line(for:)`), its type known from before.
    init(proxy: ProxySettings, kindKnown: Bool = true) {
        text = ProxyListImport.line(for: proxy, kindKnown: kindKnown)
        if kindKnown {
            knownKind = KnownKind(identity: ProxyList.identity(of: proxy), kind: proxy.kind, tlsToProxy: proxy.tlsToProxy)
        }
    }

    var field: ProxyListImport.Field { ProxyListImport.readField(text) }

    /// What Check checks: the proxy the line names — for a line without a scheme with the type
    /// known for it, or the placeholder (both handshakes are tried whatever it is).
    var checkable: ProxySettings? {
        guard case .proxy(let line) = field else { return nil }
        var proxy = line.proxy
        if !line.kindGiven, let known = knownKind, known.identity == ProxyList.identity(of: proxy) {
            proxy.kind = known.kind
            proxy.tlsToProxy = known.tlsToProxy
        }
        return proxy
    }

    /// The last check, while it is about what the field holds now.
    var currentCheck: Check? {
        guard let check, let proxy = checkable, ProxyList.sameConnection(check.proxy, proxy) else { return nil }
        return check
    }

    var reading: Reading {
        switch field {
        case .empty:
            return .empty
        case .several(let count):
            return .problem(String(format: L("proxyLine.error.several"), count))
        case .problem(let reason):
            return .problem(reason.words)
        case .proxy(let line):
            guard var proxy = checkable else { return .empty }
            let found = currentCheck?.result.diagnosis?.kinds ?? []
            if line.kindGiven {
                guard let first = found.first, !found.contains(proxy.kind) else { return .proxy(proxy, .scheme) }
                let given = proxy.kind
                proxy.kind = first
                if first == .socks5 { proxy.tlsToProxy = false }
                return .proxy(proxy, .corrected(from: given))
            }
            if let first = found.first {
                proxy.kind = first
                if first == .socks5 { proxy.tlsToProxy = false }
                return .proxy(proxy, .check)
            }
            if let known = knownKind, known.identity == ProxyList.identity(of: proxy) {
                return .proxy(proxy, .known)
            }
            return .kindUnknown(proxy)
        }
    }

    /// The proxy, when the field holds one whose type is known.
    var proxy: ProxySettings? {
        if case .proxy(let proxy, _) = reading { return proxy }
        return nil
    }

    /// The text with the password as dots — what the field shows while it is not being edited — or
    /// nil when there is no password in it. Where the password is not found in the text as written,
    /// the proxy's own address is shown with dots instead: the password is never shown.
    var maskedText: String? {
        guard case .proxy(let line) = field, let password = line.proxy.password, !password.isEmpty else { return nil }
        let dots = String(repeating: "•", count: 8) // l10n: not text
        var shown: String
        if let range = ProxyListImport.passwordRange(in: text) {
            shown = text
            shown.replaceSubrange(range, with: dots)
        } else {
            shown = (line.kindGiven ? Self.scheme(line.proxy) : "") + (line.proxy.username ?? "") + ":" + dots + "@"
                + line.proxy.displayAddress // l10n: not text
        }
        // One line: whatever pasted line breaks and runs of spaces there are, as one space.
        return shown.split(whereSeparator: { $0.isNewline || $0.isWhitespace }).joined(separator: " ")
    }

    static func scheme(_ proxy: ProxySettings) -> String {
        proxy.kind == .socks5 ? "socks5://" : (proxy.tlsToProxy ? "https://" : "http://") // l10n: not text
    }

    /// The location a check found for `proxy` (its exit, as a launch's lookup through it remembers
    /// it), when the check is about the proxy the field resolves to.
    func location(for proxy: ProxySettings) -> ProxyLocation? {
        currentCheck?.result.location(for: proxy)
    }
}

// MARK: - The field

/// The one field for a proxy: the line (its password as dots while the field is not being edited),
/// Check beside it, under it what the line was read as — or, as it is typed, why it is not a
/// proxy — and what the check found.
struct ProxyLineField: View {
    @Binding var line: ProxyLine
    /// A check from this field is running.
    var checking: Bool
    var onCheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(L("proxyLine.field"), text: $line.text, prompt: Text(verbatim: ""))
                    .lumenField(L("proxyLine.example"), isEmpty: line.text.isEmpty, masked: line.maskedText)
                    .accessibilityLabel(L("proxyLine.field"))
                Button(action: onCheck) {
                    Label(L("proxyLine.check"), systemImage: "checkmark.shield")
                }
                .buttonStyle(.lumenSecondary)
                .disabled(checking || line.checkable == nil)
                .help(L("proxyLine.check.help"))
            }
            ProxyLineReadingView(reading: line.reading)
            if checking {
                ProxyLineCheckView(proxy: line.checkable, result: nil, checking: true)
            } else if let check = line.currentCheck {
                ProxyLineCheckView(proxy: check.proxy, result: check.result)
            }
        }
    }
}

/// What the line was read as — the type and where it comes from, the address, the user name — or
/// why it is not a proxy, at once and in plain words.
struct ProxyLineReadingView: View {
    let reading: ProxyLine.Reading

    var body: some View {
        Group {
            switch reading {
            case .empty:
                Text(L("proxyLine.hint"))
                    .foregroundStyle(Theme.textTertiary)
            case .problem(let message):
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.danger)
            case .proxy(let proxy, let source):
                Label(Self.summary(proxy, kind: Self.kindText(proxy, source)), systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.textSecondary)
            case .kindUnknown(let proxy):
                Label(Self.summary(proxy, kind: L("proxyLine.kind.unknown")), systemImage: "questionmark.circle")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.lumenSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// "SOCKS5 · 1.2.3.4:1080 · user alice".
    static func summary(_ proxy: ProxySettings, kind: String) -> String {
        var parts = [kind, proxy.displayAddress]
        if let user = proxy.username, !user.isEmpty { parts.append(String(format: L("proxyLine.user"), user)) }
        return parts.joined(separator: " · ") // l10n: not text
    }

    static func kindText(_ proxy: ProxySettings, _ source: ProxyLine.KindSource) -> String {
        let name = ProxyReport.kindName(proxy.kind, tls: proxy.tlsToProxy)
        switch source {
        case .scheme: return name
        case .check: return String(format: L("proxyLine.kind.found"), name)
        case .corrected(let given): return String(format: L("proxyLine.kind.corrected"), name, ProxyReport.kindName(given, tls: false))
        case .known: return String(format: L("proxyLine.kind.known"), name)
        }
    }
}

/// What a check found: the proxy working — its type, latency, where it exits (flag, country, city)
/// and its exit IP — or the state that says how it does not work, why, and what to do about it.
struct ProxyLineCheckView: View {
    /// The proxy as it was checked.
    let proxy: ProxySettings?
    let result: ProxyCheckResult?
    var checking = false

    var body: some View {
        let state = checking ? ProxyState.checking : ProxyState(check: result)
        HStack(alignment: .top, spacing: 10) {
            ProxyStatusIcon(state: state, size: 14)
            VStack(alignment: .leading, spacing: 4) {
                if checking {
                    Text(L("proxyLine.checking"))
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.textPrimary)
                } else if let result, let proxy {
                    let report = ProxyReport(proxy: proxy, check: result)
                    Text(headline(state: state, result: result))
                        .font(.lumenLabel)
                        .foregroundStyle(Theme.textPrimary)
                    if state.isWorking {
                        exitRow(result)
                    } else {
                        if let explanation = report.explanation {
                            Text(explanation)
                                .font(.lumenSecondary)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if let advice = report.advice {
                            Label(advice, systemImage: "lightbulb")
                                .font(.lumenSecondary)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raisedInset))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// "Works · SOCKS5 · 84 ms"; for a proxy that does not work, its state's sentence.
    private func headline(state: ProxyState, result: ProxyCheckResult) -> String {
        guard state.isWorking, let proxy else { return state.title }
        let kind = result.diagnosis?.kinds.first ?? proxy.kind
        var parts = [state.title, ProxyReport.kindName(kind, tls: kind == .httpConnect && proxy.tlsToProxy)]
        let latency = ProxyCheckText.latency(result)
        if !latency.isEmpty { parts.append(latency) }
        return parts.joined(separator: " · ") // l10n: not text
    }

    @ViewBuilder
    private func exitRow(_ result: ProxyCheckResult) -> some View {
        HStack(spacing: 6) {
            if let code = result.countryCode {
                CountryFlag(code: code, size: 12)
            }
            Text(ProxyReport.exitLine(result) ?? L("proxies.step.through.answered"))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
    }
}
