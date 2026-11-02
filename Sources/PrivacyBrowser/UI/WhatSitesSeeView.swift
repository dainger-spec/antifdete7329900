import BrowserCore
import SwiftUI

/// "What sites see" (a profile's ⋯ menu, the command palette): what any page measures of the
/// profile — and, only on "Compare with Safari", what of it is the real Safari's (`WhatSitesSee`).
///
/// Written for the person who bought the app (the owner, 2 November: read wrong twice in a row as
/// "everything is bad"). Before a comparison there is nothing to count: what was measured, and the
/// offer to compare. After one: a verdict in one sentence; what is worth a look (should have been
/// Safari's and is not); what is as it should be (the profile's time zone and language — the point
/// of a profile); every difference by the names it is about, never "40 against 41". For an iPhone or
/// iPad view this Mac's Safari is the wrong reference, and the panel says so instead of comparing.
struct WhatSitesSeeView: View {
    let name: String
    /// The profile is an iPhone or iPad view: Safari on this Mac under another device's name.
    let mobileView: Bool
    @StateObject private var snapshot: WhatSitesSee
    @State private var showsSame: Bool
    @State private var showsNotCompared = false
    @Environment(\.dismiss) private var dismiss

    static let size = CGSize(width: 880, height: 660)

    init(name: String, snapshot: @autoclosure @escaping () -> WhatSitesSee, showsSame: Bool = false, mobileView: Bool = false) {
        self.name = name
        self.mobileView = mobileView
        _snapshot = StateObject(wrappedValue: snapshot())
        _showsSame = State(initialValue: showsSame)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("whatSites.title"), name), subtitle: L("whatSites.subtitle"))
            HStack(spacing: 12) {
                takeButton
                if snapshot.isTaking { ProgressView().controlSize(.small) }
                Text(status)
                    .font(.lumenSecondary)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            Rectangle().fill(Theme.divider).frame(height: 1)
            if snapshot.signals.isEmpty {
                LumenEmptyHint(symbol: "eye", text: L("whatSites.empty"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshot.comparedWithSafari {
                compared(SiteComparison.verdict(snapshot.signals, expected: snapshot.expected))
            } else {
                measured
            }
            SheetFooter {
                Text(L("whatSites.notMeasured"))
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
        .background(Theme.raised)
    }

    /// The first check is the thing to do here; once there is one, comparing is.
    @ViewBuilder private var takeButton: some View {
        let label = Label(L(snapshot.takenAt == nil ? "whatSites.take" : "whatSites.retake"), systemImage: "eye")
        if snapshot.takenAt == nil {
            Button { Task { await snapshot.take() } } label: { label }
                .buttonStyle(.lumenPrimary)
                .disabled(snapshot.isTaking)
        } else {
            Button { Task { await snapshot.take() } } label: { label }
                .buttonStyle(.lumenSecondary)
                .disabled(snapshot.isTaking)
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
            let taken = snapshot.takenAt.map { $0.shown(date: .omitted, time: .shortened) } ?? ""
            if snapshot.comparedWithSafari { return String(format: L("whatSites.done.compared"), taken) }
            if snapshot.safariDidNotAnswer { return L("whatSites.doneWithoutSafari") }
            let count = snapshot.signals.count
            return String(format: L("whatSites.done.measured.\(LicenseText.form(count))"), taken, count)
        }
    }

    private var statusColor: Color {
        switch snapshot.step {
        case .failed: return Theme.danger
        case .done where snapshot.safariDidNotAnswer: return Theme.warning
        default: return Theme.textSecondary
        }
    }

    // MARK: Measured, not compared

    /// What was measured, as it is: no "same" or "differs" — there is nothing to compare with yet.
    private var measured: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if mobileView {
                    Text(L("whatSites.mobileView"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    compareCard
                }
                ForEach(SiteSignalCategory.allCases, id: \.self) { category in
                    let signals = snapshot.signals.filter { $0.category == category && !SiteSignalText.isRepeat($0.key) }
                    if !signals.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("whatSites.category.\(category.rawValue)")).font(.lumenSection)
                            ForEach(signals) { signal in ValueRow(signal: signal, value: signal.profile) }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    /// The offer to compare, with why in one line; this Mac's own Safari opens only on it.
    private var compareCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("whatSites.compare.title")).font(.lumenSheetTitle)
            Text(L("whatSites.compare.why"))
                .font(.lumenBody)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("whatSites.compare")) { Task { await snapshot.compareWithSafari() } }
                .buttonStyle(.lumenPrimary)
                .disabled(snapshot.isTaking)
                .padding(.top, 4)
            Text(L("whatSites.compare.note"))
                .font(.lumenCaption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
    }

    // MARK: Compared

    private func compared(_ verdict: SiteVerdict) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: verdict.attention.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(verdict.attention.isEmpty ? Theme.running : Theme.warning)
                    Text(SiteSignalText.verdict(verdict))
                        .font(.lumenRowTitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !verdict.attention.isEmpty {
                    group(title: L("whatSites.group.attention"), why: L("whatSites.group.attention.why")) {
                        ForEach(verdict.attention) { signal in AttentionRow(signal: signal, expected: snapshot.expected) }
                    }
                }
                if !verdict.intended.isEmpty {
                    group(title: L("whatSites.group.intended"), why: SiteSignalText.intendedWhy(verdict.aspects, countryCode: snapshot.countryCode)) {
                        ForEach(verdict.intended) { signal in IntendedRow(signal: signal) }
                    }
                }
                DisclosureGroup(isExpanded: $showsSame) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snapshot.signals.filter { $0.verdict == .same && !SiteSignalText.isRepeat($0.key) }) { signal in
                            ValueRow(signal: signal, value: signal.profile)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text(String(format: L("whatSites.group.same"), verdict.same)).font(.lumenSection)
                }
                let notCompared = verdict.notCompared.filter { !SiteSignalText.isRepeat($0.key) }
                if !notCompared.isEmpty {
                    DisclosureGroup(isExpanded: $showsNotCompared) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(notCompared) { signal in IntendedRow(signal: signal) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(String(format: L("whatSites.group.notCompared"), notCompared.count)).font(.lumenSection)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func group<Rows: View>(title: String, why: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.lumenSection)
            Text(why)
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) { rows() }
                .padding(.top, 2)
        }
    }
}

/// A signal and one value, as measured: its name, and the value.
private struct ValueRow: View {
    let signal: SiteSignal
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(SiteSignalText.name(of: signal.key))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 280, alignment: .leading)
                .help(signal.key)
            SiteSignalText.valueText(value)
        }
    }
}

/// The profile's identity, or each window's own: the name, and both values, calmly.
private struct IntendedRow: View {
    let signal: SiteSignal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(SiteSignalText.name(of: signal.key)).font(.lumenLabel).help(signal.key)
            Text(String(format: L("whatSites.row.values"), SiteSignalText.shortened(signal.profile ?? "—"),
                        SiteSignalText.shortened(signal.safari ?? "—")))
                .font(.lumenSecondary)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Something that should have been the real Safari's: what it is, in words, and what it means where
/// that is known.
private struct AttentionRow: View {
    let signal: SiteSignal
    let expected: ExpectedIdentity?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.warning)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(SiteSignalText.name(of: signal.key)).font(.lumenLabel).help(signal.key)
                ForEach(SiteSignalText.sentences(for: signal, expected: expected), id: \.self) { sentence in
                    Text(sentence)
                        .font(.lumenSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = SiteComparison.noteKey(for: signal.key) {
                    Text(L(note))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The panel's words for signals and their differences: the person's, not CI's keys (which stay in
/// each row's help, for support).
enum SiteSignalText {
    /// A signal's name. A feature is its own name; an unknown key is shown as it is rather than hidden.
    static func name(of key: String) -> String {
        let featurePrefix = "probe.features.", nativePrefix = "probe.natives."
        if key.hasPrefix(featurePrefix) { return String(key.dropFirst(featurePrefix.count)) }
        if key.hasPrefix(nativePrefix) {
            return String(format: L("whatSites.signal.native"), String(key.dropFirst(nativePrefix.count)))
        }
        let parts = key.split(separator: ".", maxSplits: 2).map(String.init)
        if parts.count == 3, parts[0] == "headers" {
            let request = ["navigation", "fetch", "xhr"].contains(parts[1]) ? L("whatSites.request.\(parts[1])") : parts[1]
            switch parts[2] {
            case "order": return String(format: L("whatSites.signal.headerOrder"), request)
            case "accept-language": return String(format: L("whatSites.signal.acceptLanguage"), request)
            default: return String(format: L("whatSites.signal.header"), headerName(parts[2]), request)
            }
        }
        let localized = L("whatSites.signal.\(key)")
        return localized == "whatSites.signal.\(key)" ? key : localized
    }

    /// The same measurement taken twice (the probe's window sizes, geometry's): shown once.
    static func isRepeat(_ key: String) -> Bool {
        key == "probe.innerSize" || key == "probe.outerSize"
    }

    /// "accept-language" as it is written: "Accept-Language".
    static func headerName(_ name: String) -> String {
        name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
    }

    /// One sentence for the whole comparison: how many signals are the real Safari's, how many
    /// differ on purpose, and how many are worth a look.
    static func verdict(_ verdict: SiteVerdict) -> String {
        let form = LicenseText.form
        if verdict.attention.isEmpty, verdict.intended.isEmpty {
            return String(format: L("whatSites.verdict.allSame.\(form(verdict.compared))"), verdict.compared)
        }
        let same = String(format: L("whatSites.verdict.of.\(form(verdict.compared))"), verdict.same, verdict.compared)
        let attention = String(format: L("whatSites.verdict.attention.\(form(verdict.attention.count))"), verdict.attention.count)
        guard !verdict.intended.isEmpty else {
            return String(format: L("whatSites.verdict.attentionOnly"), same, attention)
        }
        let intended = String(format: L("whatSites.verdict.intended.\(form(verdict.intended.count))"), verdict.intended.count)
        let aspects = L("whatSites.aspects.\(aspectsKey(verdict.aspects))")
        if verdict.attention.isEmpty {
            return String(format: L("whatSites.verdict.intendedOnly"), same, intended, aspects)
        }
        return String(format: L("whatSites.verdict.both"), same, intended, aspects, attention)
    }

    /// Why the profile's identity is as it should be: its country's time zone and language when it
    /// takes its place from its proxy, else its own.
    static func intendedWhy(_ aspects: [IdentityAspect], countryCode: String?) -> String {
        let what = L("whatSites.aspectsBare.\(aspectsKey(aspects))")
        if let countryCode {
            return String(format: L("whatSites.group.intended.country"), what, CountryNames.name(for: countryCode))
        }
        return String(format: L("whatSites.group.intended.own"), what)
    }

    private static func aspectsKey(_ aspects: [IdentityAspect]) -> String {
        switch (aspects.contains(.timeZone), aspects.contains(.language)) {
        case (true, false): return "timeZone"
        case (false, true): return "language"
        default: return "both"
        }
    }

    /// What one difference is, in words; for values, which part of them differs where that has names
    /// (the screen's), else both values.
    static func sentences(for signal: SiteSignal, expected: ExpectedIdentity?) -> [String] {
        guard let difference = SiteComparison.difference(of: signal, expected: expected) else { return [] }
        let shownProfile = shortened(signal.profile ?? "—"), shownSafari = shortened(signal.safari ?? "—")
        switch difference {
        case .names(let missing, let extra):
            let prefix = signal.key == "probe.navigatorProperties" ? "navigator." : ""
            let missingNames = missing.map { prefix + $0 }, extraNames = extra.map { prefix + $0 }
            if !missing.isEmpty, !extra.isEmpty {
                return [String(format: L("whatSites.diff.both"), list(missingNames), list(extraNames))]
            }
            let properties = ["probe.navigatorProperties", "probe.windowProperties", "probe.ownNavigator", "probe.ownScreen"]
            if missing.count == 1 {
                let key = properties.contains(signal.key) ? "whatSites.diff.missing.property" : "whatSites.diff.missing.one"
                return [String(format: L(key), missingNames[0])]
            }
            if !missing.isEmpty { return [String(format: L("whatSites.diff.missing.many"), list(missingNames))] }
            if extra.count == 1 { return [String(format: L("whatSites.diff.extra.one"), extraNames[0])] }
            return [String(format: L("whatSites.diff.extra.many"), list(extraNames))]
        case .order:
            return [L(signal.key.hasPrefix("headers.") ? "whatSites.diff.order.headers" : "whatSites.diff.order")]
        case .replacedFunction(let function):
            return [String(format: L("whatSites.diff.replaced"), function)]
        case .onlyInSafari:
            return [String(format: L("whatSites.diff.onlySafari"), shownSafari)]
        case .onlyInProfile:
            return [String(format: L("whatSites.diff.onlyProfile"), shownProfile)]
        case .notAsSet(let wanted):
            let key = signal.key == "probe.timeZone" ? "whatSites.diff.notAsSet.timeZone" : "whatSites.diff.notAsSet.language"
            return [String(format: L(key), shownProfile, wanted)]
        case .values:
            if let parts = screenParts(signal) { return parts }
            return [String(format: L("whatSites.row.values"), shownProfile, shownSafari)]
        }
    }

    /// The screen's and the window bars' numbers by name: "the usable area's height: 998 in the
    /// profile, 995 in Safari".
    private static func screenParts(_ signal: SiteSignal) -> [String]? {
        let names: [String]
        switch signal.key {
        case "probe.screen": names = ["width", "height", "availWidth", "availHeight", "pixelRatio"]
        case "geometry.screen": names = ["width", "height", "availWidth", "availHeight", "availLeft", "availTop"]
        case "geometry.chrome": names = ["barsWidth", "barsHeight"]
        default: return nil
        }
        let mine = (signal.profile ?? "").split(separator: "x").map(String.init)
        let theirs = (signal.safari ?? "").split(separator: "x").map(String.init)
        guard mine.count == names.count, theirs.count == names.count else { return nil }
        let sentences = names.indices.filter { mine[$0] != theirs[$0] }.map { index in
            String(format: L("whatSites.part.values"), L("whatSites.part.screen.\(names[index])"), mine[index], theirs[index])
        }
        return sentences.isEmpty ? nil : sentences
    }

    private static func list(_ names: [String]) -> String {
        names.count <= 12 ? names.joined(separator: ", ")
            : names.prefix(12).joined(separator: ", ") + String(format: L("whatSites.diff.more"), names.count - 12)
    }

    /// A value shown in a row: as it is, selectable.
    static func valueText(_ value: String?) -> some View {
        Text(shortened(value ?? "—"))
            .font(.lumenMono)
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .help(value ?? "")
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A long value (a canvas's data URL) as its start and its length.
    static func shortened(_ text: String) -> String {
        text.count <= 220 ? text : String(text.prefix(200)) + String(format: L("whatSites.longValue"), text.count)
    }
}
