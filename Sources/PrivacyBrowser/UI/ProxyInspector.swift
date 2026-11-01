import BrowserCore
import SwiftUI

/// The inspector at the right of the Proxies section (the design's proxy inspector): the selected
/// proxy's last check, step by step, with what to do about it, what it is, and the profiles that
/// use it. 320 pt, over the light at 80 %, as the profiles' inspector.
struct ProxyInspectorView: View {
    let entry: ProxyListEntry
    /// Being checked now.
    var checking = false
    /// The profiles that use it (`ProxyList.identity`), by name.
    var profileNames: [String] = []
    var check: () -> Void = {}
    /// Nil while the list cannot be written.
    var edit: (() -> Void)?
    var assign: () -> Void = {}

    var body: some View {
        let report = ProxyReport(proxy: entry.proxy, check: entry.lastCheck, checking: checking)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                head(report)
                if entry.lastCheck == nil, !checking {
                    section(L("inspector.proxy.steps")) {
                        Text(entry.kindKnown ? L("proxies.report.unchecked") : L("proxies.type.unknown.help"))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if !report.steps.isEmpty {
                    section(L("inspector.proxy.steps")) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(report.steps.enumerated()), id: \.element.id) { index, step in
                                ProxyStepTimelineRow(step: step, isLast: index == report.steps.count - 1)
                            }
                        }
                        Text(L("inspector.proxy.throughItself"))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    }
                }
                if report.explanation != nil || report.advice != nil {
                    advice(report)
                }
                if let note = report.kindNote {
                    Label(note, systemImage: "info.circle")
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }
                section(nil) {
                    fact(L("proxies.column.type"), entry.kindKnown ? entry.kindName : L("proxies.type.unknown"))
                    fact(L("inspector.exit"), exitText)
                    fact(L("inspector.exitIP"), entry.lastCheck?.isAlive == true ? (entry.lastCheck?.exitIP ?? "—") : "—", // l10n: not text
                         mono: true)
                    if let latency = entry.lastCheck.flatMap({ $0.isAlive ? $0.latencyMilliseconds : nil }) {
                        fact(L("inspector.latency"), String(format: L("proxies.latency"), latency))
                    }
                    fact(L("inspector.proxy.origin"), entry.originLine)
                }
                section(L("inspector.proxy.profiles")) {
                    if profileNames.isEmpty {
                        Text(L("inspector.proxy.noProfiles"))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(Array(profileNames.enumerated()), id: \.offset) { _, name in
                            HStack(spacing: 10) {
                                Text(String(name.prefix(1)).uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Theme.avatarFill))
                                    .overlay(Circle().strokeBorder(Theme.divider, lineWidth: 1))
                                    .accessibilityHidden(true)
                                Text(name)
                                    .font(.lumenBody)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    Button(L("proxies.menu.assign"), action: assign)
                        .buttonStyle(.lumenGhost)
                        .padding(.top, 6)
                        .padding(.leading, -11)
                }
            }
        }
        .scrollIndicators(.automatic)
    }

    private func head(_ report: ProxyReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.displayName)
                .lumenHeadingTitle()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            if !entry.label.isEmpty {
                Text(entry.address)
                    .font(.lumenMono)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            }
            HStack(spacing: 6) {
                if checking {
                    ProgressView().controlSize(.mini)
                }
                Text(report.state.shortText)
                    .foregroundStyle(report.state.isWorking ? Theme.textPrimary : report.state.color)
                if let checked = entry.lastCheck?.checkedAt, !checking {
                    Text(verbatim: "·").foregroundStyle(Theme.textTertiary)
                    Text(String(format: L("proxies.report.checkedAt"), checked.shownRelative))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .font(.lumenSecondary)
            .lineLimit(1)
            .padding(.top, 10)
            HStack(spacing: 8) {
                Button(L("proxies.menu.check"), action: check)
                    .buttonStyle(.lumenSecondary)
                    .disabled(checking)
                if let edit {
                    Button(L("proxies.edit"), action: edit)
                        .buttonStyle(.lumenGhost)
                }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    /// Where it exits, as its last check found: the country and the city.
    private var exitText: String {
        guard let check = entry.lastCheck, check.isAlive, let code = check.countryCode else { return "—" } // l10n: not text
        guard let city = check.city, !city.isEmpty else { return CountryNames.name(for: code) }
        return CountryNames.name(for: code) + " · " + city // l10n: not text
    }

    /// What happened and what to do, in the state's colour (the design's advice box).
    private func advice(_ report: ProxyReport) -> some View {
        let danger = report.state.color == Theme.danger
        return VStack(alignment: .leading, spacing: 6) {
            if let explanation = report.explanation {
                Text(explanation)
                    .font(.lumenBody)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let advice = report.advice {
                Text(L("proxies.report.advice"))
                    .font(.lumenLabel)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 6)
                Text(advice)
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(danger ? Theme.dangerTint : Theme.warningTint))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(danger ? Theme.dangerLine : Theme.warningLine, lineWidth: 1))
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .accessibilityElement(children: .combine)
    }

    private func section<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).lumenCaps().accessibilityAddTraits(.isHeader).padding(.bottom, 8)
            }
            content()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func fact(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.lumenBody)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 104, alignment: .leading)
            Text(value)
                .font(mono ? Font.lumenMono : Font.lumenBody)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One step of a check on a line that joins the steps (the design's `step`): a ring with a check,
/// a cross or a dash — never told apart by the colour alone — its name, and what was found.
private struct ProxyStepTimelineRow: View {
    let step: ProxyReport.Step
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().strokeBorder(ringColor, lineWidth: 1)
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(symbolColor)
                }
                .frame(width: 16, height: 16)
                if !isLast {
                    Rectangle().fill(Theme.divider).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 16)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.lumenLabel)
                    .foregroundStyle(step.outcome == .notReached ? Theme.textTertiary : Theme.textPrimary)
                Text(step.outcome == .notReached ? L("proxies.step.notReached") : step.detail)
                    .font(.lumenSecondary)
                    .foregroundStyle(step.outcome == .failed ? Theme.danger : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.bottom, isLast ? 0 : 12)
        }
        // The line runs the row's whole height, to the next step's ring.
        .fixedSize(horizontal: false, vertical: true)
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

    private var ringColor: Color {
        switch step.outcome {
        case .passed: return Theme.textSecondary
        case .failed: return Theme.danger
        case .skipped, .notReached: return Theme.divider
        }
    }

    private var symbolColor: Color {
        switch step.outcome {
        case .passed: return Theme.textPrimary
        case .failed: return Theme.danger
        case .skipped, .notReached: return Theme.textTertiary
        }
    }
}

/// Several proxies selected: how many, and what can be done with them all.
struct ProxySelectionInspectorView: View {
    let count: Int
    var checking = false
    let check: () -> Void
    let assign: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(format: L("inspector.selected"), count))
                .lumenHeadingTitle()
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 8) {
                Button(L("proxies.check.selected"), action: check)
                    .buttonStyle(LumenButtonStyle(kind: .secondary, fullWidth: true))
                    .disabled(checking)
                Button(L("proxies.menu.assign"), action: assign)
                    .buttonStyle(LumenButtonStyle(kind: .ghost, fullWidth: true))
                Button(L("proxies.menu.delete"), role: .destructive, action: delete)
                    .buttonStyle(LumenButtonStyle(kind: .destructive, fullWidth: true))
            }
            .padding(.top, 18)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
