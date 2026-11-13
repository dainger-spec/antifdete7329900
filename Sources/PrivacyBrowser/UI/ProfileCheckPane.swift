import BrowserCore
import SwiftUI

/// The profile's check as the person sees it. Before the first check, an invitation with the one
/// button; while it runs, its three steps; a check that could not be made says why in the same
/// place. Then the verdict — "All in order", or "Things to look at (N)" — and under it the topics
/// in groups, things to look at first: what was found, in a sentence, and "Fix" where the
/// settings can put it right. A fix changes the settings at once and says so; the running profile
/// takes them at its next start, which "Restart and check again" makes and shows.
struct ProfileCheckPane: View {
    @ObservedObject var check: ProfileCheckRun
    /// Opens the proxy's own step-by-step check (the Proxies section), where there is one to open.
    var showProxy: (() -> Void)?

    /// Findings whose sentence ends in "Restart the profile": the running profile is not what its
    /// settings say.
    private static let restartCodes: Set<String> = ["stale", "onWhereOff", "offProfile", "prefetch", "udpOpen"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Before the first check the invitation has the button, so the pane has one main button;
            // a first run and a first failure keep it there too (no lone button far above them).
            if check.checkedAt != nil {
                HStack(spacing: 12) {
                    Button {
                        Task { await check.run() }
                    } label: {
                        Label(L("check.rerun"), systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.lumenPrimary)
                    .disabled(check.isRunning)
                    Text(status)
                        .font(.lumenSecondary)
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                Rectangle().fill(Theme.divider).frame(height: 1)
            }
            switch check.step {
            case .ready: intro
            case .page, .exit, .network: progress
            case .failed(let reason): failure(reason)
            case .done: results
            }
        }
    }

    /// Beside the button: when the check was made, or why a fix could not be. The running steps
    /// and a failure are said in the pane's body.
    private var status: String {
        switch check.step {
        case .ready, .page, .exit, .network, .failed: return ""
        case .done:
            if let error = check.fixError { return error }
            return String(format: L("check.done"), check.checkedAt.map { $0.shown(date: .omitted, time: .standard) } ?? "")
        }
    }

    private var statusColor: Color {
        check.fixError == nil ? Theme.textSecondary : Theme.danger
    }

    /// Before the first check: what it goes over, and the button that makes it.
    private var intro: some View {
        LumenEmptyState(symbol: "checkmark.shield", title: L("check.intro.title"), text: L("check.empty")) {
            Button {
                Task { await check.run() }
            } label: {
                Label(L("check.run"), systemImage: "checkmark.shield")
            }
            .buttonStyle(.lumenPrimary)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// While the check runs: its three steps in order, and what the person will see meanwhile.
    private var progress: some View {
        let steps: [(step: ProfileCheckRun.Step, title: String)] = [
            (step: ProfileCheckRun.Step.page, title: L("check.progress.page")),
            (step: ProfileCheckRun.Step.exit, title: L("check.progress.exit")),
            (step: ProfileCheckRun.Step.network, title: L("check.progress.network")),
        ]
        let current = steps.firstIndex { $0.step == check.step } ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                stepRow(item.title, made: index < current, running: index == current)
            }
            Text(L("check.progress.note"))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.top, 6)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// One step of a running check: a tick when made, a spinner while it is made, a ring before.
    private func stepRow(_ title: String, made: Bool, running: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: made ? "checkmark" : "circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(made ? Theme.running : Theme.textTertiary)
                        .accessibilityHidden(!made)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .font(.lumenBody)
                .foregroundStyle(running ? Theme.textPrimary : (made ? Theme.textSecondary : Theme.textTertiary))
        }
    }

    /// A check that could not be made: why, and what to see to before checking again — with the
    /// button under it on a first check, with the one above after an earlier check.
    @ViewBuilder
    private func failure(_ reason: String) -> some View {
        if check.checkedAt == nil {
            LumenEmptyState(symbol: "exclamationmark.triangle", tint: Theme.danger, title: L("check.failed.title"),
                            text: reason, note: L("check.failed.hint")) {
                Button {
                    Task { await check.run() }
                } label: {
                    Label(L("check.rerun"), systemImage: "checkmark.shield")
                }
                .buttonStyle(.lumenPrimary)
                .keyboardShortcut(.defaultAction)
            }
        } else {
            LumenEmptyState(symbol: "exclamationmark.triangle", tint: Theme.danger, title: L("check.failed.title"),
                            text: reason, note: L("check.failed.hint"))
        }
    }

    /// A finished check: the verdict, the restart where it is asked for, and the findings in
    /// groups by level, things to look at first.
    private var results: some View {
        let order: [ProfileCheck.Level] = [.attention, .unknown, .ok]
        let levels = order.filter { level in check.findings.contains { $0.level == level } }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                verdict
                if needsRestart { restart }
                ForEach(levels, id: \.self) { level in
                    group(level, captioned: levels.count > 1)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    /// One level's findings on a card, in the topics' order. `captioned`: under the level's name
    /// and count, as the profile list's groups (not needed when every finding is of one level).
    private func group(_ level: ProfileCheck.Level, captioned: Bool) -> some View {
        let rows = check.findings.filter { $0.level == level }
        let tone: Color = level == .attention ? Theme.warning : Theme.textTertiary
        return VStack(alignment: .leading, spacing: 8) {
            if captioned {
                HStack(spacing: 8) {
                    Text(L("check.group.\(level.rawValue)")).lumenCaps(tone)
                    Text(verbatim: "\(rows.count)").lumenCaps(tone).monospacedDigit()
                }
                .padding(.leading, 14)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, finding in
                    if index > 0 { Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 44) }
                    FindingRow(finding: finding, fixed: finding.fix.map { check.fixesMade.contains($0) } ?? false,
                               running: check.isRunning, fix: { check.fix($0) },
                               showProxy: finding.topic == .proxy && finding.level == .attention ? showProxy : nil)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raisedInset))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    /// "All in order" — "Nothing to look at" when some topics could not be compared — or "Things
    /// to look at (N)"; how many topics were not checked is said under the verdict's note.
    private var verdict: some View {
        let attention = check.attention
        let unknown = check.findings.filter { $0.level == .unknown }.count
        let tint = attention == 0 ? Theme.running : Theme.warning
        // The filled seal and "All in order" only when every topic was compared.
        let symbol: String = attention > 0 ? "exclamationmark.triangle.fill" : (unknown == 0 ? "checkmark.seal.fill" : "checkmark.seal")
        let title: String = attention > 0 ? String(format: L("check.verdict.attention"), attention)
            : (unknown == 0 ? L("check.verdict.ok") : L("check.verdict.partial"))
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(tint)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(L(attention == 0 ? "check.verdict.ok.note" : "check.verdict.attention.note"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if unknown > 0 {
                    Label(String(format: L("check.verdict.unknown"), unknown), systemImage: "questionmark.circle")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(attention == 0 ? Theme.runningTint : Theme.warningTint))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(attention == 0 ? Theme.runningLine : Theme.warningLine, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// A fix was made, or a finding says the running profile is not what its settings say.
    private var needsRestart: Bool {
        !check.fixesMade.isEmpty || check.findings.contains { $0.level == .attention && Self.restartCodes.contains($0.code) }
    }

    /// After a fix the settings are saved and the running profile has the old ones; a finding
    /// that asks for a restart means the same of the profile as it runs. One button for both.
    private var restart: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.clockwise.circle").font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
            Text(check.fixesMade.isEmpty ? L("check.restart.note.asked") : L("check.restart.note"))
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
/// A topic in order is one quiet line; the others take the room a sentence and a button need.
private struct FindingRow: View {
    let finding: ProfileCheck.Finding
    /// Its fix was made since the check: saved, waiting for the profile's next start.
    let fixed: Bool
    let running: Bool
    let fix: (ProfileCheck.Fix) -> Void
    let showProxy: (() -> Void)?

    var body: some View {
        if finding.level == .ok { compact } else { full }
    }

    /// In order: a tick, the topic's name in a column, the sentence on the same line.
    private var compact: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.running)
                .frame(width: 20)
                .accessibilityLabel(L("check.level.ok"))
            Text(L("check.topic.\(finding.topic.rawValue)"))
                .font(.lumenLabel)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 140, alignment: .leading)
            Text(Self.sentence(finding))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    /// To look at, or not checked: the sentence under the topic's name, and its button beside them.
    private var full: some View {
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
            // One measure for every row's text, with a button beside it or without.
            .frame(maxWidth: 560, alignment: .leading)
            Spacer(minLength: 12)
            if fixed {
                Label(L("check.fixed"), systemImage: "checkmark")
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.running)
                    .fixedSize()
                    .help(L("check.fixed.help"))
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
