import BrowserCore
import SwiftUI

// The Warm-up section's other two tabs: the templates — the person's own lists and the app's kinds
// of browsing, each with what it comes to for a country — and the history of every run.

struct WarmUpTemplatesPane: View {
    let templates: [WarmUpTemplate]
    /// The countries of the person's profiles, most profiles first.
    let countries: [(code: String, count: Int)]
    let actions: WarmUpActions
    /// Opens "New warm-up" with these templates ticked.
    let warmUp: ([String]) -> Void

    /// The template shown: an interest's raw value, or a list's `presetID`.
    @State var selected = WarmUpInterest.day.rawValue
    @State private var country = ""
    @State private var editing: EditorRequest?
    @State private var loaded = false

    struct EditorRequest: Identifiable {
        let id = UUID()
        var template: WarmUpTemplate?
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            list
                .frame(width: 280)
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(item: $editing) { request in WarmUpTemplateEditor(template: request.template, actions: actions) }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            country = countries.first?.code ?? ""
        }
    }

    private func row(_ title: String, note: String, id: String) -> some View {
        Button { selected = id } label: {
            HStack(spacing: 8) {
                Text(title).font(.lumenBody).foregroundStyle(selected == id ? Theme.textPrimary : Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 6)
                Text(note).font(.lumenSecondary).foregroundStyle(Theme.textTertiary).monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected == id ? Theme.rowSelected : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected == id ? .isSelected : [])
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("warm.templates.mine")).font(.lumenSection).foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 10).padding(.bottom, 4)
                ForEach(templates) { template in
                    row(template.name, note: String(format: L("warm.templates.ownSites"), template.addresses.count), id: template.presetID)
                }
                Button { editing = EditorRequest(template: nil) } label: {
                    Label(L("warm.templates.new"), systemImage: "plus")
                }
                .buttonStyle(.lumenGhost)
                .padding(.leading, 2)
                Text(L("warm.templates.ready")).font(.lumenSection).foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 10).padding(.top, 18).padding(.bottom, 4)
                ForEach(WarmUpInterest.allCases, id: \.self) { interest in
                    row(L("warm.template." + interest.rawValue), note: "", id: interest.rawValue)
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder private var detail: some View {
        if let interest = WarmUpInterest(rawValue: selected) {
            interestDetail(interest)
        } else if let template = templates.first(where: { $0.presetID == selected }) {
            ownDetail(template)
        } else {
            LumenEmptyHint(symbol: "list.bullet", text: L("warm.templates.pick"))
        }
    }

    private func title(_ name: String, note: String, @ViewBuilder buttons: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).lumenHeadingTitle().foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(note).font(.lumenBody).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            buttons()
        }
    }

    private func lines(_ caption: String, _ items: [String], mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "\(caption)  \(items.count)").lumenCaps()
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(verbatim: item)
                    .font(mono ? .lumenMono : .lumenBody)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
            }
        }
    }

    private func interestDetail(_ interest: WarmUpInterest) -> some View {
        let selection = WarmUpCatalog.selection(interest, countryCode: country.isEmpty ? nil : country)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                title(L("warm.template." + interest.rawValue), note: L("warm.template." + interest.rawValue + ".note")) {
                    Button(L("warm.templates.warmUp")) { warmUp([interest.rawValue]) }.buttonStyle(.lumenSecondary)
                }
                HStack(spacing: 10) {
                    Text(L("warm.templates.country")).font(.lumenBody).foregroundStyle(Theme.textSecondary)
                    Picker("", selection: $country) {
                        ForEach(countries, id: \.code) { entry in
                            Text(verbatim: "\(WarmUpText.country(entry.code)) · \(entry.count)").tag(entry.code)
                        }
                        if !countries.isEmpty { Divider() }
                        Text(L("warm.templates.world")).tag("")
                        ForEach(WarmUpCatalog.countries.filter { code in !countries.contains { $0.code == code } }, id: \.self) { code in
                            Text(WarmUpText.country(code)).tag(code)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityLabel(L("warm.templates.country"))
                    if selection.usesWorld, !country.isEmpty {
                        Text(L("warm.templates.usesWorld")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                    }
                }
                HStack(alignment: .top, spacing: 36) {
                    lines(L("warm.templates.sites"), selection.sites)
                    lines(L("warm.templates.searches"), selection.searches)
                }
                Text(L("warm.templates.note")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 20)
        }
    }

    private func ownDetail(_ template: WarmUpTemplate) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                title(template.name, note: ownNote(template)) {
                    Button(L("warm.own.change")) { editing = EditorRequest(template: template) }.buttonStyle(.lumenGhost)
                    Button(L("warm.templates.warmUp")) { warmUp([template.presetID]) }.buttonStyle(.lumenSecondary)
                }
                HStack(alignment: .top, spacing: 36) {
                    lines(L("warm.templates.sites"), template.addresses.map { WarmUpPlan(addresses: $0).pages().pages.first?.url.host ?? $0 })
                    lines(L("warm.templates.searches"), template.searches)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 20)
        }
    }

    private func ownNote(_ template: WarmUpTemplate) -> String {
        var parts: [String] = []
        if let code = template.countryCode, !code.isEmpty { parts.append(String(format: L("warm.own.note.country"), WarmUpText.country(code))) }
        parts.append((template.addsEveryday ?? true) ? L("warm.own.note.everyday") : L("warm.own.note.alone"))
        return parts.joined(separator: " · ")
    }
}

/// Every run of every profile, the newest first, by day.
struct WarmUpHistoryPane: View {
    let profiles: [WarmUpProfileItem]
    var templates: [WarmUpTemplate] = []
    var search = ""
    let open: (WarmUpProfileItem, WarmUpRun) -> Void
    @State private var onlyRemarks = false

    private struct Entry: Identifiable {
        let profile: WarmUpProfileItem
        let run: WarmUpRun
        var id: UUID { run.id }
    }

    private var entries: [Entry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .flatMap { item in item.history.map { Entry(profile: item, run: $0) } }
            .filter { !onlyRemarks || $0.run.hasRemarks }
            .sorted { $0.run.endedAt > $1.run.endedAt }
    }

    /// The entries by day, the newest day first (at most 300 rows: the rest is in each profile's own).
    private var days: [(day: Date, entries: [Entry])] {
        var order: [Date] = []
        var byDay: [Date: [Entry]] = [:]
        for entry in entries.prefix(300) {
            let day = Calendar.current.startOfDay(for: entry.run.endedAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(entry)
        }
        return order.map { (day: $0, entries: byDay[$0] ?? []) }
    }

    var body: some View {
        let days = self.days
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(summary).font(.lumenBody).foregroundStyle(Theme.textSecondary).monospacedDigit().lineLimit(1)
                Spacer(minLength: 12)
                LumenSegmented(selection: $onlyRemarks, options: [(value: false, title: L("warm.history.all")), (value: true, title: L("warm.history.remarks"))])
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("warm.tab.history"))
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            header.padding(.horizontal, 28)
            if days.isEmpty {
                LumenEmptyHint(symbol: "clock", text: L("warm.history.empty"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days, id: \.day) { day in
                            Text(verbatim: "\(dayTitle(day.day))  \(day.entries.count)")
                                .lumenCaps()
                                .padding(.top, 22)
                                .padding(.bottom, 6)
                            ForEach(day.entries) { entry in
                                row(entry)
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(entry.profile, entry.run) }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var summary: String {
        let week = Date().addingTimeInterval(-7 * 86_400)
        let recent = profiles.flatMap(\.history).filter { $0.endedAt >= week }
        return String(format: L("warm.history.summary"), recent.count, recent.filter { !$0.hasRemarks }.count, recent.filter(\.hasRemarks).count)
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return L("warm.history.today") }
        if Calendar.current.isDateInYesterday(day) { return L("warm.history.yesterday") }
        return day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Localization.locale))
    }

    private enum Columns {
        static let time: CGFloat = 64
        static let templates: CGFloat = 250
        static let sites: CGFloat = 90
        static let cookies: CGFloat = 80
        static let took: CGFloat = 80
        static let result: CGFloat = 230
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(L("warm.history.time")).lumenCaps().frame(width: Columns.time, alignment: .leading)
            Text(L("warm.history.profile")).lumenCaps().frame(maxWidth: .infinity, alignment: .leading)
            Text(L("warm.tab.templates")).lumenCaps().frame(width: Columns.templates, alignment: .leading)
            Text(L("warm.templates.sites")).lumenCaps().frame(width: Columns.sites, alignment: .trailing)
            Text(verbatim: "Cookies").lumenCaps().frame(width: Columns.cookies, alignment: .trailing) // l10n: not text
            Text(L("warm.history.took")).lumenCaps().frame(width: Columns.took, alignment: .trailing)
            Text(L("warm.history.result")).lumenCaps().padding(.leading, 28).frame(width: Columns.result, alignment: .leading)
        }
        .lineLimit(1)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func row(_ entry: Entry) -> some View {
        let run = entry.run
        let remark = WarmUpText.remark(run)
        return HStack(spacing: 0) {
            Text(run.endedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.locale)))
                .font(.lumenBody).foregroundStyle(Theme.textSecondary)
                .frame(width: Columns.time, alignment: .leading)
            HStack(spacing: 10) {
                ProfileAvatar(name: entry.profile.name, id: entry.profile.id, size: 24, style: entry.profile.avatar)
                Text(entry.profile.name).font(.lumenLabel).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if run.scheduled {
                    Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        .help(L("warm.report.scheduled"))
                        .accessibilityLabel(L("warm.report.scheduled"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(templatesLine(run))
                .font(.lumenBody).foregroundStyle(Theme.textSecondary).lineLimit(1)
                .frame(width: Columns.templates, alignment: .leading)
            Text(String(format: L("warm.row.progress"), run.visitedSites, max(run.plannedSites, run.visitedSites)))
                .font(.lumenBody).foregroundStyle(Theme.textPrimary)
                .frame(width: Columns.sites, alignment: .trailing)
            Text(verbatim: "+\(run.cookies)")
                .font(.lumenLabel).foregroundStyle(Theme.textPrimary)
                .frame(width: Columns.cookies, alignment: .trailing)
            Text(WarmUpText.duration(run.duration))
                .font(.lumenBody).foregroundStyle(Theme.textSecondary)
                .frame(width: Columns.took, alignment: .trailing)
            HStack(spacing: 7) {
                if remark != nil {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(remarkColor(run))
                }
                Text(remark ?? L("warm.history.fine"))
                    .font(.lumenBody).foregroundStyle(remark == nil ? Theme.textSecondary : Theme.textPrimary).lineLimit(1)
            }
            .padding(.leading, 28)
            .frame(width: Columns.result, alignment: .leading)
        }
        .monospacedDigit()
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .hoverHighlight()
        .accessibilityElement(children: .combine)
    }

    private func remarkColor(_ run: WarmUpRun) -> Color {
        switch run.resultKind {
        case .proxyNotAnswering, .notStarted: return Theme.danger
        default: return Theme.warning
        }
    }

    private func templatesLine(_ run: WarmUpRun) -> String {
        guard !run.templates.isEmpty else { return L("warm.history.ownPlan") }
        var text = WarmUpText.templates(run.templates, names: run.templateNames, templates: templates)
        if let intensity = run.intensity.flatMap(WarmUpIntensity.init(rawValue:)) { text += " · " + WarmUpText.intensity(intensity).lowercased() }
        return text
    }
}
