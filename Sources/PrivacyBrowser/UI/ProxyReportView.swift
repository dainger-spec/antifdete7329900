import BrowserCore
import SwiftUI

// MARK: - State

/// How a proxy stands, as the list, the menus and the reports show it: a state for each way it
/// can fail (`ProxyDiagnosis.Verdict`), because each asks something else of the person — a typo,
/// a stopped proxy, a whitelist without this Mac's address, a wrong password. Each has a symbol
/// of its own as well as a colour: never told apart by the colour alone.
enum ProxyState: Equatable {
    case unchecked
    case checking
    /// A request through it was answered.
    case works
    /// The probe's verdict on a proxy that does not work.
    case failed(ProxyDiagnosis.Verdict)
    /// It took the login and opened a tunnel, and the request through it got no answer.
    case noAnswerThrough
    /// Its settings cannot be applied: nothing was sent.
    case invalidSettings
    /// Taken for dead by a build from before the stepwise check: how is not known.
    case dead

    /// From the last check (none: not checked yet).
    init(check: ProxyCheckResult?, checking: Bool = false) {
        if checking {
            self = .checking
        } else if let check {
            if let failure = check.failure {
                if failure == .invalidSettings {
                    self = .invalidSettings
                } else if let diagnosis = check.diagnosis {
                    if diagnosis.isWorking {
                        // The proxy itself answered; the request through it did not get through.
                        self = failure == .needsCredentials ? .failed(.credentialsNeeded) : .noAnswerThrough
                    } else {
                        self = .failed(diagnosis.verdict)
                    }
                } else {
                    self = .dead
                }
            } else {
                self = .works
            }
        } else {
            self = .unchecked
        }
    }

    /// From the probe alone (a profile's launch).
    init(diagnosis: ProxyDiagnosis) {
        self = diagnosis.isWorking ? .works : .failed(diagnosis.verdict)
    }

    var isWorking: Bool { self == .works }

    var symbol: String {
        switch self {
        case .unchecked, .checking: return "circle.dashed"
        case .works: return "checkmark.circle.fill"
        case .noAnswerThrough, .invalidSettings: return "exclamationmark.triangle.fill"
        case .dead: return "xmark.circle.fill"
        case let .failed(verdict):
            switch verdict {
            case .hostNotFound, .resolverFailed, .substituteDNS: return "questionmark.circle.fill"
            case .refused: return "nosign"
            case .unreachable, .connectTimeout: return "xmark.circle.fill"
            case .silent: return "hourglass"
            case .closedWithoutAnswer: return "xmark.octagon.fill"
            case .notAProxy: return "questionmark.diamond.fill"
            case .credentialsNeeded, .credentialsRejected: return "lock.fill"
            case .refusedByProxy: return "hand.raised.fill"
            case .noUpstream: return "exclamationmark.triangle.fill"
            case .reachable, .works: return "checkmark.circle.fill"
            }
        }
    }

    /// Green: works. Amber: the proxy is there and something about this Mac, the login or the way
    /// out is wrong. Red: it cannot be reached as a proxy at all. Gray: not checked.
    var color: Color {
        switch self {
        case .unchecked, .checking: return Theme.textDisabled
        case .works: return Theme.running
        case .noAnswerThrough: return Theme.warning
        case .invalidSettings, .dead: return Theme.danger
        case let .failed(verdict):
            switch verdict {
            case .credentialsNeeded, .credentialsRejected, .refusedByProxy, .noUpstream: return Theme.warning
            case .reachable, .works: return Theme.running
            default: return Theme.danger
            }
        }
    }

    /// A few words, for the list's column and the menus.
    var shortText: String {
        switch self {
        case .unchecked: return L("proxies.status.unchecked")
        case .checking: return L("proxies.status.checking")
        case .works: return L("proxies.status.alive")
        case .noAnswerThrough: return L("proxies.state.noAnswerThrough")
        case .invalidSettings: return L("proxies.status.invalid")
        case .dead: return L("proxies.status.noAnswer")
        case let .failed(verdict):
            switch verdict {
            case .hostNotFound: return L("proxies.state.hostNotFound")
            case .resolverFailed: return L("proxies.state.resolverFailed")
            case .substituteDNS: return L("proxies.state.substituteDNS")
            case .refused: return L("proxies.state.refused")
            case .unreachable: return L("proxies.state.unreachable")
            case .connectTimeout: return L("proxies.state.connectTimeout")
            case .silent: return L("proxies.state.silent")
            case .closedWithoutAnswer: return L("proxies.state.closed")
            case .notAProxy: return L("proxies.state.notAProxy")
            case .credentialsNeeded: return L("proxies.state.credentialsNeeded")
            case .credentialsRejected: return L("proxies.state.credentialsRejected")
            case .refusedByProxy: return L("proxies.state.refusedByProxy")
            case .noUpstream: return L("proxies.state.noUpstream")
            case .reachable, .works: return L("proxies.status.alive")
            }
        }
    }

    /// A sentence that says what is wrong, for a report's headline.
    var title: String {
        switch self {
        case .unchecked: return L("proxies.title.unchecked")
        case .checking: return L("proxies.status.checking")
        case .works: return L("proxies.title.works")
        case .noAnswerThrough: return L("proxies.title.noAnswerThrough")
        case .invalidSettings: return L("proxies.title.invalid")
        case .dead: return L("proxies.title.dead")
        case let .failed(verdict):
            switch verdict {
            case .hostNotFound: return L("proxies.title.hostNotFound")
            case .resolverFailed: return L("proxies.title.resolverFailed")
            case .substituteDNS: return L("proxies.title.substituteDNS")
            case .refused: return L("proxies.title.refused")
            case .unreachable: return L("proxies.title.unreachable")
            case .connectTimeout: return L("proxies.title.connectTimeout")
            case .silent: return L("proxies.title.silent")
            case .closedWithoutAnswer: return L("proxies.title.closed")
            case .notAProxy: return L("proxies.title.notAProxy")
            case .credentialsNeeded: return L("proxies.title.credentialsNeeded")
            case .credentialsRejected: return L("proxies.title.credentialsRejected")
            case .refusedByProxy: return L("proxies.title.refusedByProxy")
            case .noUpstream: return L("proxies.title.noUpstream")
            case .reachable, .works: return L("proxies.title.works")
            }
        }
    }
}

// MARK: - Report

/// What a check found, step by step and in words, with what to do about it: the Proxies section's
/// report on a proxy, and what a profile whose proxy did not work at its launch says — one text
/// for both, from the same probe (`ProxyProbe`).
struct ProxyReport {
    enum Outcome {
        case passed, failed, skipped, notReached
    }

    struct Step: Identifiable {
        let id: Int
        let title: String
        let outcome: Outcome
        let detail: String
    }

    var state: ProxyState
    /// What happened, in a sentence; nil when it works or was not checked.
    var explanation: String?
    /// What to do about it.
    var advice: String?
    /// Empty before a check, and for a check from before the steps were kept.
    var steps: [Step] = []
    /// What the check found about the type, when the list did not have it right.
    var kindNote: String?

    /// The last check of `proxy` (none: not checked yet).
    init(proxy: ProxySettings, check: ProxyCheckResult?, checking: Bool = false) {
        state = ProxyState(check: check, checking: checking)
        guard !checking, let check else { return }
        (explanation, advice) = Self.words(for: state, proxy: proxy, diagnosis: check.diagnosis)
        if let diagnosis = check.diagnosis { steps = Self.steps(proxy: proxy, diagnosis: diagnosis, check: check) }
        switch check.kindFinding {
        case .found?:
            kindNote = String(format: L("proxies.report.kindFound"), Self.kindName(proxy.kind, tls: proxy.tlsToProxy))
        case let .corrected(from)?:
            kindNote = String(format: L("proxies.report.kindCorrected"), Self.kindName(from, tls: false),
                              Self.kindName(proxy.kind, tls: proxy.tlsToProxy))
        case nil:
            break
        }
    }

    /// The probe alone, as a profile's launch runs it: no request was made through the proxy.
    init(proxy: ProxySettings, diagnosis: ProxyDiagnosis) {
        state = ProxyState(diagnosis: diagnosis)
        (explanation, advice) = Self.words(for: state, proxy: proxy, diagnosis: diagnosis)
        steps = Self.steps(proxy: proxy, diagnosis: diagnosis, check: nil)
    }

    // MARK: Words

    private static func words(for state: ProxyState, proxy: ProxySettings, diagnosis: ProxyDiagnosis?) -> (String?, String?) {
        let host = proxy.displayHost
        let answer = diagnosis?.answer ?? "—" // l10n: not text
        let kind = kindName(diagnosis?.kinds.first ?? proxy.kind, tls: proxy.tlsToProxy)
        switch state {
        case .unchecked, .checking, .works:
            return (nil, nil)
        case .noAnswerThrough:
            return (L("proxies.explain.noAnswerThrough"), L("proxies.advice.noAnswerThrough"))
        case .invalidSettings:
            return (L("proxies.explain.invalid"), L("proxies.advice.invalid"))
        case .dead:
            return (L("proxies.explain.dead"), L("proxies.advice.dead"))
        case let .failed(verdict):
            switch verdict {
            case .hostNotFound:
                return (String(format: L("proxies.explain.hostNotFound"), host), L("proxies.advice.hostNotFound"))
            case .resolverFailed:
                return (String(format: L("proxies.explain.resolverFailed"), host), L("proxies.advice.resolverFailed"))
            case .substituteDNS:
                return (String(format: L("proxies.explain.substituteDNS"), host, diagnosis?.connectedAddress ?? "—"), // l10n: not text
                        L("proxies.advice.substituteDNS"))
            case .refused:
                return (String(format: L("proxies.explain.refused"), host, proxy.port), L("proxies.advice.refused"))
            case .unreachable:
                return (String(format: L("proxies.explain.unreachable"), host), L("proxies.advice.unreachable"))
            case .connectTimeout:
                return (String(format: L("proxies.explain.connectTimeout"), host, proxy.port), L("proxies.advice.connectTimeout"))
            case .silent:
                return (L("proxies.explain.silent"), L("proxies.advice.silent"))
            case .closedWithoutAnswer:
                return (L("proxies.explain.closed"), L("proxies.advice.closed"))
            case .notAProxy:
                return (String(format: L("proxies.explain.notAProxy"), answer), L("proxies.advice.notAProxy"))
            case .credentialsNeeded:
                return (String(format: L("proxies.explain.credentialsNeeded"), kind), L("proxies.advice.credentialsNeeded"))
            case .credentialsRejected:
                return (String(format: L("proxies.explain.credentialsRejected"), kind), L("proxies.advice.credentialsRejected"))
            case .refusedByProxy:
                return (String(format: L("proxies.explain.refusedByProxy"), answer), L("proxies.advice.refusedByProxy"))
            case .noUpstream:
                return (String(format: L("proxies.explain.noUpstream"), answer), L("proxies.advice.noUpstream"))
            case .reachable, .works:
                return (nil, nil)
            }
        }
    }

    /// "SOCKS5", "HTTP", or "HTTPS" for TLS to the proxy.
    static func kindName(_ kind: ProxySettings.Kind, tls: Bool) -> String {
        switch kind {
        case .socks5: return "SOCKS5" // l10n: not text
        case .httpConnect: return tls ? "HTTPS" : "HTTP" // l10n: not text
        }
    }

    // MARK: Steps

    private static func steps(proxy: ProxySettings, diagnosis: ProxyDiagnosis, check: ProxyCheckResult?) -> [Step] {
        let failedStep = diagnosis.failedStep
        func outcome(_ step: Int) -> Outcome {
            guard let failedStep else { return .passed }
            return step < failedStep ? .passed : (step == failedStep ? .failed : .notReached)
        }
        let insideTLS = diagnosis.verdict == .reachable
        var steps: [Step] = []

        // 1. The name.
        let name: String
        switch diagnosis.verdict {
        case .hostNotFound: name = L("proxies.step.name.notFound")
        case .resolverFailed: name = diagnosis.answer.map { String(format: L("proxies.step.name.failedBecause"), $0) } ?? L("proxies.step.name.failed")
        default:
            if isIPAddress(proxy.host) {
                name = L("proxies.step.name.ip")
            } else if let address = diagnosis.connectedAddress {
                // A VPN's substitute is no real address of the proxy: the VPN connects to it by name.
                name = SubstituteDNS.isSubstitute(address) ? String(format: L("proxies.step.name.substitute"), address)
                                                           : String(format: L("proxies.step.name.resolved"), address)
            } else {
                name = L("proxies.step.name.found")
            }
        }
        steps.append(Step(id: 1, title: L("proxies.step.name"), outcome: outcome(1), detail: name))

        // 2. A connection to its port.
        let connection: String
        switch diagnosis.verdict {
        case .refused: connection = String(format: L("proxies.step.connection.refused"), proxy.port)
        case .unreachable: connection = diagnosis.answer.map { String(format: L("proxies.step.connection.unreachableBecause"), $0) } ?? L("proxies.step.connection.unreachable")
        case .connectTimeout: connection = String(format: L("proxies.step.connection.timeout"), proxy.port)
        default: connection = String(format: L("proxies.step.connection.open"), proxy.port)
        }
        steps.append(Step(id: 2, title: L("proxies.step.connection"), outcome: outcome(2), detail: outcome(2) == .notReached ? "" : connection))

        // 3. The handshake: SOCKS5 and HTTP both tried.
        let handshake: String
        switch diagnosis.verdict {
        case .silent: handshake = L("proxies.step.handshake.silent")
        case .closedWithoutAnswer: handshake = L("proxies.step.handshake.closed")
        case .notAProxy: handshake = L("proxies.step.handshake.notAProxy")
        case .reachable: handshake = L("proxies.step.insideTLS")
        default:
            let kinds = diagnosis.kinds.map { kindName($0, tls: false) }.joined(separator: " + ") // l10n: not text
            handshake = kinds.isEmpty ? "" : String(format: L("proxies.step.handshake.kinds"), kinds)
        }
        steps.append(Step(id: 3, title: L("proxies.step.handshake"), outcome: insideTLS ? .skipped : outcome(3),
                          detail: outcome(3) == .notReached ? "" : handshake))

        // 4. The login.
        let login: String
        switch diagnosis.verdict {
        case .refusedByProxy: login = L("proxies.step.login.refused")
        case .reachable: login = L("proxies.step.insideTLS")
        default:
            switch diagnosis.authentication {
            case .notRequired?: login = L("proxies.step.login.notRequired")
            case .accepted?: login = L("proxies.step.login.accepted")
            case .rejected?: login = L("proxies.step.login.rejected")
            case .missing?: login = L("proxies.step.login.missing")
            case nil: login = ""
            }
        }
        steps.append(Step(id: 4, title: L("proxies.step.login"), outcome: insideTLS ? .skipped : outcome(4),
                          detail: outcome(4) == .notReached ? "" : login))

        // 5. A tunnel to the site.
        let tunnel: String
        switch diagnosis.verdict {
        case .noUpstream: tunnel = L("proxies.step.tunnel.failed")
        case .reachable: tunnel = L("proxies.step.insideTLS")
        default: tunnel = L("proxies.step.tunnel.open")
        }
        steps.append(Step(id: 5, title: L("proxies.step.tunnel"), outcome: insideTLS ? .skipped : outcome(5),
                          detail: outcome(5) == .notReached ? "" : tunnel))

        // 6. A request through it, end to end, and where it came out.
        let through: (Outcome, String)
        if !diagnosis.isWorking || check == nil {
            through = (.notReached, "")
        } else if let check, check.isAlive {
            through = (.passed, exitLine(check) ?? L("proxies.step.through.answered"))
        } else if check?.failure == .needsCredentials {
            through = (.failed, L("proxies.step.login.missing"))
        } else {
            through = (.failed, L("proxies.step.through.noAnswer"))
        }
        steps.append(Step(id: 6, title: L("proxies.step.through"), outcome: through.0, detail: through.1))

        // 7. How long a tunnel takes.
        if let check, check.isAlive, let latency = check.latencyMilliseconds {
            let detail = diagnosis.latencies.count > 1
                ? String(format: L("proxies.step.latency.median"), latency, diagnosis.latencies.count)
                : String(format: L("proxies.latency"), latency)
            steps.append(Step(id: 7, title: L("proxies.step.latency"), outcome: .passed, detail: detail))
        } else {
            steps.append(Step(id: 7, title: L("proxies.step.latency"), outcome: .notReached, detail: ""))
        }
        return steps
    }

    /// "Exit IP 203.0.113.9 · Germany, Berlin · AS64500 Example Networks", as much as is known.
    static func exitLine(_ check: ProxyCheckResult) -> String? {
        var parts: [String] = []
        if let ip = check.exitIP { parts.append(String(format: L("proxies.step.through.exit"), ip)) }
        let place = [check.countryCode.map(CountryNames.name(for:)), check.city].compactMap { $0 }.joined(separator: ", ")
        if !place.isEmpty { parts.append(place) }
        let network = [check.asn, check.organization].compactMap { $0 }.joined(separator: " ")
        if !network.isEmpty { parts.append(network) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ") // l10n: not text
    }

    /// An IPv4 or IPv6 address: there is no name to look up.
    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
}

extension ProxySettings {
    /// The host as it is written in an address: an IPv6 one in brackets.
    var displayHost: String { host.contains(":") ? "[\(host)]" : host }
    /// "host:port".
    var displayAddress: String { "\(displayHost):\(port)" }
}

// MARK: - Views

/// The state's symbol in its colour, or a spinner while the proxy is being checked; its words are
/// the help and what VoiceOver reads.
struct ProxyStatusIcon: View {
    let state: ProxyState
    var size: CGFloat = 13

    var body: some View {
        ZStack {
            if state == .checking {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: state.symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(state.color)
            }
        }
        .frame(width: 18, height: 18)
        .help(state.shortText)
        .accessibilityElement()
        .accessibilityLabel(state.shortText)
    }
}

/// A report in full: the headline with its symbol, what happened, what to do, and the steps.
struct ProxyReportView: View {
    let report: ProxyReport
    /// When it was checked, shown after the headline.
    var checkedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProxyStatusIcon(state: report.state, size: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                Text(report.state.title)
                    .font(.lumenSection)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let checkedAt {
                    Text(String(format: L("proxies.report.checkedAt"), checkedAt.formatted(.relative(presentation: .named))))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            if let explanation = report.explanation {
                Text(explanation)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let advice = report.advice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("proxies.report.advice"))
                            .font(.lumenLabel)
                            .foregroundStyle(Theme.textPrimary)
                        Text(advice)
                            .font(.lumenBody)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let note = report.kindNote {
                Label(note, systemImage: "info.circle")
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !report.steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.steps) { step in
                        ProxyStepRow(step: step)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

private struct ProxyStepRow: View {
    let step: ProxyReport.Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(step.title)
                .font(.lumenLabel)
                .foregroundStyle(step.outcome == .notReached ? Theme.textTertiary : Theme.textPrimary)
                .frame(width: 130, alignment: .leading)
            Text(step.outcome == .notReached ? L("proxies.step.notReached") : step.detail)
                .font(.lumenSecondary)
                .foregroundStyle(step.outcome == .failed ? color : Theme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch step.outcome {
        case .passed: return "checkmark"
        case .failed: return "xmark"
        case .skipped: return "arrow.turn.down.right"
        case .notReached: return "minus"
        }
    }

    private var color: Color {
        switch step.outcome {
        case .passed: return Theme.running
        case .failed: return Theme.danger
        case .skipped, .notReached: return Theme.textTertiary
        }
    }
}
