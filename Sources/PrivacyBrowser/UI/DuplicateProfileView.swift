import BrowserCore
import SwiftUI

/// Copies of a profile (`ProfileClone`, `AppModel.duplicateProfile`): how many, and where their
/// proxies come from — the original's, the list's in turn (unused first, of a country), or none.
/// What each copy will be called and get is shown before anything is made.
struct DuplicateProfileView: View {
    let profile: ProfileSummary
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var count = 1
    @State private var source: Source = .same
    /// "": any country.
    @State private var country = ""
    @State private var error: String?
    /// The copies are being made: said, and the buttons wait.
    @State private var working = false

    enum Source: Hashable { case same, list, none }

    private var original: ProfileDetails? { model.details[profile.id] }
    private var entries: [ProxyListEntry] { model.proxyList?.entries ?? [] }

    /// The countries the list's proxies came out in at their last check, by name.
    private var countries: [String] {
        Array(Set(entries.compactMap { $0.kindKnown ? $0.lastCheck?.countryCode?.uppercased() : nil }))
            .sorted { CountryNames.name(for: $0) < CountryNames.name(for: $1) }
    }

    private var choice: AppModel.CopyProxies {
        switch source {
        case .same: return .same
        case .none: return .none
        case .list: return .fromList(country: country.isEmpty ? nil : country)
        }
    }

    private var plan: [(name: String, proxy: String)] {
        let names = ProfileClone.names(for: profile.name, count: count, taken: model.profiles.map(\.name))
        switch source {
        case .same:
            let proxy = original?.proxyEndpoint ?? L("duplicate.proxy.direct")
            return names.map { (name: $0, proxy: proxy) }
        case .none:
            return names.map { (name: $0, proxy: L("duplicate.proxy.direct")) }
        case .list:
            let used = Set(model.details.values.compactMap(\.proxyIdentity))
            let picked = ProfileClone.proxies(from: entries, count: count, country: country.isEmpty ? nil : country, used: used)
            guard !picked.isEmpty else { return [] }
            return zip(names, picked).map { (name: $0, proxy: $1.displayName) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("duplicate.title"), profile.name), subtitle: L("duplicate.explanation"))
            VStack(alignment: .leading, spacing: 14) {
                EditorField(L("duplicate.count")) {
                    // Typed as well as stepped: fifty copies were fifty clicks on the arrows.
                    HStack(spacing: 8) {
                        TextField(L("duplicate.count"), text: countText, prompt: Text(verbatim: ""))
                            .lumenField()
                            .monospacedDigit()
                            .frame(width: 64)
                        Stepper(L("duplicate.count"), value: $count, in: 1...ProfileClone.maximumCopies)
                            .labelsHidden()
                        Text(String(format: L("duplicate.count.range"), ProfileClone.maximumCopies))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .disabled(working)
                }
                EditorField(L("duplicate.proxy")) {
                    LumenSegmented(selection: $source, options: [
                        (value: Source.same, title: L("duplicate.proxy.same")),
                        (value: Source.list, title: L("duplicate.proxy.list")),
                        (value: Source.none, title: L("duplicate.proxy.none")),
                    ])
                }
                if source == .list {
                    if entries.isEmpty {
                        note(L("duplicate.list.empty"))
                    } else {
                        Picker(L("duplicate.country"), selection: $country) {
                            Text(L("duplicate.country.any")).tag("")
                            ForEach(countries, id: \.self) { code in Text(CountryNames.name(for: code)).tag(code) }
                        }
                        .fixedSize()
                        note(L("duplicate.list.order"))
                    }
                }
                // A profile whose time zone and language do not follow its proxy keeps them in its
                // copies, whatever country their proxies are in.
                if source == .list, original?.followsProxyLocation == false {
                    note(L("duplicate.fixedLocale"), warns: true)
                }
                preview
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.lumenSecondary).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            SheetFooter(leading: {
                if working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(format: L("duplicate.working"), count))
                            .font(.lumenSecondary)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }, buttons: {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(LumenButtonStyle(kind: .ghost, height: Theme.buttonHeight))
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                // How many it makes, on the button that makes them.
                Button(count == 1 ? L("duplicate.action") : String(format: L("duplicate.action.count"), count), action: duplicate)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.isEmpty || working)
            })
        }
        .sheetFrame(width: 520)
        .background(Theme.raised)
    }

    @ViewBuilder private var preview: some View {
        let rows = plan
        VStack(alignment: .leading, spacing: 4) {
            if rows.isEmpty {
                note(L("duplicate.error.noProxies"), warns: true)
            } else {
                ForEach(Array(rows.prefix(6).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        Text(row.name).font(.lumenBody).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(row.proxy).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if rows.count > 6 {
                    Text(String(format: L("duplicate.more"), rows.count - 6))
                        .font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 0, fill: Theme.raisedInset)
    }

    private func note(_ text: String, warns: Bool = false) -> some View {
        Text(text)
            .font(.lumenSecondary)
            .foregroundStyle(warns ? Theme.warning : Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The count as typed: digits only, held to 1…the most copies.
    private var countText: Binding<String> {
        Binding(get: { String(count) },
                set: { text in
                    let digits = text.filter(\.isNumber).prefix(3)
                    count = min(max(Int(digits) ?? 1, 1), ProfileClone.maximumCopies)
                })
    }

    private func duplicate() {
        guard !working else { return }
        working = true
        error = nil
        // A moment for "Making copies…" to show before the copies are written.
        Task { @MainActor in
            await Task.yield()
            let result = model.duplicateProfile(profile.id, count: count, proxies: choice)
            working = false
            if let problem = result.problem {
                error = result.made.isEmpty ? problem : String(format: L("duplicate.partly"), result.made.count, problem)
                return
            }
            dismiss()
        }
    }
}
