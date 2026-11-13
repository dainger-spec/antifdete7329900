import BrowserCore
import SwiftUI

/// "What sites see" (a profile's ⋯ menu, the command palette): the profile's snapshot — and, only
/// on "Compare with Safari", next to this Mac's own Safari's, signal by signal (`WhatSitesSee`). For an
/// iPhone or iPad view this Mac's Safari is the wrong reference, and the panel says so, with what
/// it cannot see of the real device, rather than "the same" (the owner's decision).
///
/// With a check (`ProfileCheckRun`) the panel opens on it and is titled as the profile's check:
/// one button, a verdict — "All in order" or "Things to look at (N)" — and a sentence a topic,
/// with "Fix" where the settings can put it right. The signals, one by one, are its second tab,
/// with their own explanation at its top.
struct WhatSitesSeeView: View {
    enum Tab: Hashable { case check, signals }

    let name: String
    /// The profile is an iPhone or iPad view: Safari on this Mac under another device's name.
    let mobileView: Bool
    @StateObject private var snapshot: WhatSitesSee
    @StateObject private var check: ProfileCheckRun
    private let hasCheck: Bool
    /// The proxy's step-by-step check, for a finding only that can explain (a proxy that does not answer).
    private let showProxy: (() -> Void)?
    @State private var tab: Tab
    @State private var onlyDifferences: Bool
    @Environment(\.dismiss) private var dismiss

    static let size = CGSize(width: 880, height: 660)

    /// `check`: the profile's check, sharing `snapshot` (nil: the signals alone, as the snapshots
    /// of the list show them).
    init(name: String, snapshot: @autoclosure @escaping () -> WhatSitesSee, check: ((WhatSitesSee) -> ProfileCheckRun)? = nil,
         tab: Tab? = nil, onlyDifferences: Bool = true, mobileView: Bool = false, showProxy: (() -> Void)? = nil) {
        self.name = name
        self.mobileView = mobileView
        self.showProxy = showProxy
        let taken = snapshot()
        _snapshot = StateObject(wrappedValue: taken)
        _check = StateObject(wrappedValue: check?(taken) ?? ProfileCheckRun(profileID: taken.profileID, snapshot: taken, environment: { nil }))
        hasCheck = check != nil
        _tab = State(initialValue: tab ?? (check != nil ? .check : .signals))
        _onlyDifferences = State(initialValue: onlyDifferences)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // By `hasCheck`, not by the tab: the header keeps its height when the tab is switched.
            SheetHeader(title: String(format: hasCheck ? L("check.title") : L("whatSites.title"), name),
                        subtitle: hasCheck ? L("check.subtitle") : L("whatSites.subtitle"))
            if hasCheck {
                LumenSegmented(selection: $tab, options: [(value: Tab.check, title: L("check.tab.check")), (value: Tab.signals, title: L("check.tab.signals"))])
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)
            }
            if tab == .check {
                ProfileCheckPane(check: check, showProxy: showProxy.map { show in { dismiss(); show() } })
            } else {
                signalsPane
            }
            SheetFooter {
                Text(L(tab == .check ? "check.footer" : "whatSites.notMeasured"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } buttons: {
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .sheetFrame(width: Self.size.width, height: Self.size.height)
        .lumenSheetSurface()
    }

    /// The signals one by one: the snapshot's controls, then the list. Under a header that
    /// speaks of the check, what the snapshot is and where it stays is said here first.
    @ViewBuilder
    private var signalsPane: some View {
            // Before the first snapshot the pane has one main button, under its message (as the
            // check's invitation): no row of controls above an empty list.
            let firstRun = snapshot.step == .ready && snapshot.signals.isEmpty
            if hasCheck {
                Text(L("whatSites.subtitle"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            if !firstRun {
                HStack(spacing: 12) {
                    Button {
                        Task { await snapshot.take() }
                    } label: {
                        Label(L(snapshot.takenAt == nil ? "whatSites.take" : "whatSites.retake"), systemImage: "camera.viewfinder")
                    }
                    .buttonStyle(.lumenPrimary)
                    .disabled(snapshot.isTaking)
                    if snapshot.isTaking { ProgressView().controlSize(.small) }
                    Text(status)
                        .font(.lumenSecondary)
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    // Without Safari's values every signal "differs": the filter would change nothing.
                    if snapshot.comparedWithSafari && !snapshot.signals.isEmpty {
                        Toggle(L("whatSites.onlyDifferences"), isOn: $onlyDifferences)
                            .toggleStyle(.lumenCheckbox)
                            .font(.lumenSecondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                // This Mac's own Safari only on the person's word, with what it means said first
                // (once compared, the status says it: the button alone stays).
                if snapshot.takenAt != nil, !snapshot.isTaking, !mobileView {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Button(L("whatSites.compare")) { Task { await snapshot.compareWithSafari() } }
                            .buttonStyle(.lumenSecondary)
                        if !snapshot.comparedWithSafari {
                            Text(L("whatSites.compare.note"))
                                .font(.lumenSecondary)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
            }
            if mobileView {
                Text(L("whatSites.mobileView"))
                    .font(.lumenSecondary)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            if !firstRun {
                Rectangle().fill(Theme.divider).frame(height: 1)
            }
            if snapshot.signals.isEmpty {
                if firstRun {
                    LumenEmptyState(symbol: "eye", title: L("whatSites.empty.title"), text: L("whatSites.empty")) {
                        Button {
                            Task { await snapshot.take() }
                        } label: {
                            Label(L("whatSites.take"), systemImage: "camera.viewfinder")
                        }
                        .buttonStyle(.lumenPrimary)
                        .keyboardShortcut(.defaultAction)
                    }
                } else {
                    LumenEmptyState(symbol: "eye", title: L("whatSites.empty.title"), text: L("whatSites.empty"))
                }
            } else {
                results
            }
    }

    private var status: String {
        switch snapshot.step {
        case .ready: return ""
        case .starting: return L("whatSites.step.starting")
        case .measuringProfile: return L("whatSites.step.profile")
        case .measuringSafari: return L("whatSites.step.safari")
        case .failed(let reason): return reason
        case .done:
            let taken = snapshot.takenAt.map { $0.shown(date: .omitted, time: .standard) } ?? ""
            let key = snapshot.comparedWithSafari ? "whatSites.done"
                : snapshot.safariDidNotAnswer ? "whatSites.doneWithoutSafari" : "whatSites.doneProfileOnly"
            return String(format: L(key), taken)
        }
    }

    private var statusColor: Color {
        switch snapshot.step {
        case .failed: return Theme.danger
        case .done where snapshot.safariDidNotAnswer: return Theme.warning
        default: return Theme.textSecondary
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(SiteSignalCategory.allCases, id: \.self) { category in
                    let all = snapshot.signals.filter { $0.category == category }
                    let shown = onlyDifferences && snapshot.comparedWithSafari ? all.filter { $0.verdict != .same } : all
                    if !all.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(L("whatSites.category.\(category.rawValue)")).font(.lumenLabel)
                                Text(Self.summary(all, comparedWithSafari: snapshot.comparedWithSafari))
                                    .font(.lumenSecondary)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            ForEach(shown) { signal in SignalRow(signal: signal, comparedWithSafari: snapshot.comparedWithSafari) }
                            if shown.isEmpty {
                                Text(mobileView ? L("whatSites.allSame.mobile") : L("whatSites.allSame"))
                                    .font(.lumenSecondary)
                                    .foregroundStyle(Theme.running)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }

    /// "31 same · 2 differ · 3 each window's own". Not compared with Safari: how many signals,
    /// not "7 differ" — without Safari's values none is the same.
    static func summary(_ signals: [SiteSignal], comparedWithSafari: Bool = true) -> String {
        guard comparedWithSafari else { return String(format: L("whatSites.summary.profileOnly"), signals.count) }
        let same = signals.filter { $0.verdict == .same }.count
        let perWindow = signals.filter { $0.verdict == .perWindow }.count
        let differ = signals.count - same - perWindow
        return String(format: L("whatSites.summary"), same, differ, perWindow)
    }
}

/// One signal: its key as CI's comparison names it, and what each browser said.
private struct SignalRow: View {
    let signal: SiteSignal
    let comparedWithSafari: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(signal.key).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Text(verdictText).font(.lumenSecondary).foregroundStyle(color)
                }
                switch signal.verdict {
                case .same, .onlyProfile:
                    value(signal.profile)
                case .onlySafari:
                    value(signal.safari)
                case .differs, .perWindow:
                    labelled(L("whatSites.profile"), signal.profile)
                    labelled(L("whatSites.safari"), signal.safari)
                }
                if signal.verdict == .differs, let note = SiteComparison.noteKey(for: signal.key) {
                    Text(L(note)).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var symbol: String {
        switch signal.verdict {
        case .same: return "checkmark.circle"
        case .differs, .onlySafari: return "exclamationmark.triangle"
        case .onlyProfile: return comparedWithSafari ? "exclamationmark.triangle" : "circle"
        case .perWindow: return "macwindow"
        }
    }

    private var color: Color {
        switch signal.verdict {
        case .same: return Theme.running
        case .differs, .onlySafari: return Theme.warning
        case .onlyProfile: return comparedWithSafari ? Theme.warning : Theme.textSecondary
        case .perWindow: return Theme.textSecondary
        }
    }

    private var verdictText: String {
        switch signal.verdict {
        case .same: return L("whatSites.same")
        case .differs: return L("whatSites.differs")
        case .perWindow: return L("whatSites.perWindow")
        case .onlyProfile: return comparedWithSafari ? L("whatSites.onlyProfile") : ""
        case .onlySafari: return L("whatSites.onlySafari")
        }
    }

    private func value(_ text: String?) -> some View {
        Text(Self.shortened(text ?? "—"))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .textSelection(.enabled)
            .help(text ?? "")
    }

    private func labelled(_ label: String, _ text: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Wide enough for "Профиль" on one line ("Профил" and "ь" under it at 52).
            Text(label).font(.lumenSecondary).foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize()
                .frame(minWidth: 64, alignment: .leading)
            value(text)
        }
    }

    /// A long value (a canvas's data URL) as its start and its length.
    static func shortened(_ text: String) -> String {
        text.count <= 220 ? text : String(text.prefix(200)) + String(format: L("whatSites.longValue"), text.count)
    }
}
