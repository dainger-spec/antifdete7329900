import BrowserCore
import SwiftUI

/// The profile's check as the person sees it: one button; while it runs, what it is doing; then
/// the verdict — "All in order", or "Things to look at (N)" — and under it a row a topic: what
/// was found, in a sentence, and "Fix" where the settings can put it right. A fix changes the
/// settings at once and says so; the running profile takes them at its next start, which
/// "Restart and check again" makes and shows.
struct ProfileCheckPane: View {
    @ObservedObject var check: ProfileCheckRun
    /// Opens the proxy's own step-by-step check (the Proxies section), where there is one to open.
    var showProxy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    Task { await check.run() }
                } label: {
                    Label(L(check.checkedAt == nil ? "check.run" : "check.rerun"), systemImage: "checkmark.shield")
                }
                .buttonStyle(.lumenPrimary)
                .disabled(check.isRunning)
                if check.isRunning { ProgressView().controlSize(.small) }
                Text(status)
                    .font(.lumenSecondary)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            Rectangle().fill(Theme.divider).frame(height: 1)
            if check.findings.isEmpty {
                LumenEmptyHint(symbol: "checkmark.shield", text: L("check.empty"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        verdict
                        if !check.fixesMade.isEmpty { restart }
                        VStack(spacing: 0) {
                            ForEach(Array(check.findings.enumerated()), id: \.element.id) { index, finding in
                                if index > 0 { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 44) }
                                FindingRow(finding: finding, fixed: finding.fix.map { check.fixesMade.contains($0) } ?? false,
                                           running: check.isRunning, fix: { check.fix($0) },
                                           showProxy: finding.topic == .proxy && finding.level == .attention ? showProxy : nil)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raisedInset))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
        }
    }

    private var status: String {
        switch check.step {
        case .ready: return ""
        case .page: return L("check.step.page")
        case .exit: return L("check.step.exit")
        case .network: return L("check.step.network")
        case .failed(let reason): return reason
        case .done:
            if let error = check.fixError { return error }
            return String(format: L("check.done"), check.checkedAt.map { $0.shown(date: .omitted, time: .standard) } ?? "")
        }
    }

    private var statusColor: Color {
        if case .failed = check.step { return Theme.danger }
        return check.fixError == nil ? Theme.textSecondary : Theme.danger
    }

    /// "All in order" or "Things to look at (N)", with what was not looked at said beside it.
    private var verdict: some View {
        let attention = check.attention
        let unknown = check.findings.filter { $0.level == .unknown }.count
        let tint = attention == 0 ? Theme.running : Theme.warning
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: attention == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(tint)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(attention == 0 ? L("check.verdict.ok") : String(format: L("check.verdict.attention"), attention))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(L(attention == 0 ? "check.verdict.ok.note" : "check.verdict.attention.note"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if unknown > 0 {
                Text(String(format: L("check.verdict.unknown"), unknown))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(attention == 0 ? Theme.running.opacity(0.07) : Theme.warningTint))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(attention == 0 ? Theme.running.opacity(0.26) : Theme.warningLine, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// After a fix: the settings are saved, the running profile has the old ones.
    private var restart: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.clockwise.circle").font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
            Text(L("check.restart.note"))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L("check.restart")) { Task { await check.restartAndRun() } }
                .buttonStyle(.lumenSecondary)
                .disabled(check.isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.rowHover))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// One topic of the check: its state, its name, what was found — and what can be done about it.
private struct FindingRow: View {
    let finding: ProfileCheck.Finding
    /// Its fix was made since the check: saved, waiting for the profile's next start.
    let fixed: Bool
    let running: Bool
    let fix: (ProfileCheck.Fix) -> Void
    let showProxy: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(color)
                .frame(width: 20)
                .padding(.top, 1)
                .accessibilityLabel(L("check.level.\(finding.level.rawValue)"))
            VStack(alignment: .leading, spacing: 3) {
                Text(L("check.topic.\(finding.topic.rawValue)"))
                    .font(.lumenLabel)
                    .foregroundStyle(Theme.textPrimary)
                Text(Self.sentence(finding))
                    .font(.lumenSecondary)
                    .foregroundStyle(finding.level == .unknown ? Theme.textTertiary : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            if fixed {
                Label(L("check.fixed"), systemImage: "checkmark")
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.running)
                    .frame(maxWidth: 190, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            } else if let fix = finding.fix {
                Button(L("check.fix.\(fix.rawValue)")) { self.fix(fix) }
                    .buttonStyle(.lumenSecondary)
                    .disabled(running)
            } else if let showProxy {
                Button(L("check.showProxy"), action: showProxy)
                    .buttonStyle(.lumenSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch finding.level {
        case .ok: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch finding.level {
        case .ok: return Theme.running
        case .attention: return Theme.warning
        case .unknown: return Theme.textTertiary
        }
    }

    /// The finding's sentence, with its values: a country by its name in the interface's language.
    static func sentence(_ finding: ProfileCheck.Finding) -> String {
        let values: [CVarArg] = finding.values.map { value in
            guard value.hasPrefix("country:") else { return value }
            let code = String(value.dropFirst("country:".count))
            return Localization.locale.localizedString(forRegionCode: code) ?? (code.isEmpty ? L("check.country.unknown") : code)
        }
        return String(format: L("check.\(finding.topic.rawValue).\(finding.code)"), arguments: values)
    }
}
