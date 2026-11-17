import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

// "New warm-up" — who, what, how much, with what a profile of each country will visit beside it —
// a run's report, and the editor of a list of one's own.

struct WarmUpNewSheet: View {
    let request: WarmUpNewRequest
    let profiles: [WarmUpProfileItem]
    var templates: [WarmUpTemplate] = []
    let actions: WarmUpActions
    @Environment(\.dismiss) private var dismiss

    @State private var picked: Set<UUID> = []
    @State private var chosen: [String] = [WarmUpInterest.day.rawValue]
    @State private var intensity = WarmUpIntensity.normal
    @State private var viaSearch = true
    @State private var consent = WarmUpConsentChoice.accept
    @State private var trafficSaving = WarmUpCoordinator.trafficSaving
    /// 0: not repeated.
    @State private var repeatHours = 0
    @State private var choosingProfiles = false
    @State private var profileSearch = ""
    /// The country whose sites the right side shows (lower case); "": no country — the world's.
    @State private var previewCountry = ""
    /// The sample on the right, drawn when what it depends on changes — not at every redraw.
    @State private var sample: [String] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("warm.new.title"), subtitle: L("warm.new.subtitle"))
            HStack(alignment: .top, spacing: 24) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        profilesPart
                        templatesPart
                        intensityPart
                        behaviourPart
                    }
                    .padding(.trailing, 2)
                }
                preview
                    .frame(width: 290)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity, alignment: .top)
            SheetFooter(leading: {
                Text(total).font(.lumenSecondary).foregroundStyle(Theme.textSecondary).monospacedDigit()
            }, buttons: {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("warm.new.start")) { start() }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(targets.isEmpty || chosen.isEmpty)
            })
        }
        .sheetFrame(width: 940, height: 680)
        .background(Theme.raised)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            picked = Set(request.profiles)
            if !request.templates.isEmpty { chosen = request.templates.filter { WarmUpTemplateRef(id: $0) != nil } }
            if chosen.isEmpty { chosen = [WarmUpInterest.day.rawValue] }
            // With nothing ticked the sheet opens on the profiles that were never warmed.
            if picked.isEmpty {
                picked = Set(profiles.filter { $0.state == .never }.map(\.id))
                choosingProfiles = true
            }
            previewCountry = countries.first?.code ?? ""
            resample()
        }
        .onChange(of: chosen) { _, _ in resample() }
        .onChange(of: intensity) { _, _ in resample() }
        .onChange(of: previewCountry) { _, _ in resample() }
        .onChange(of: picked) { _, _ in
            if !countries.contains(where: { $0.code == previewCountry }) { previewCountry = countries.first?.code ?? "" }
        }
    }

    // MARK: Who

    /// The ticked profiles that can be warmed now: not those already running a warm-up or waiting.
    private var targets: [WarmUpProfileItem] {
        profiles.filter { picked.contains($0.id) && !$0.isRunning && !$0.isWaiting }
    }

    /// The countries of the ticked profiles, most profiles first; "" for those without one.
    private var countries: [(code: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in targets { counts[item.countryCode?.lowercased() ?? "", default: 0] += 1 }
        return counts.map { (code: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.code < $1.code }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.lumenSection).foregroundStyle(Theme.textSecondary)
    }

    private var profilesPart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                caption(L("warm.new.profiles"))
                Text(profilesLine).font(.lumenBody).foregroundStyle(Theme.textPrimary).monospacedDigit().lineLimit(1)
                Spacer(minLength: 8)
                Button(choosingProfiles ? L("warm.new.profiles.hide") : L("warm.new.profiles.change")) { choosingProfiles.toggle() }
                    .buttonStyle(.lumenGhost)
            }
            if choosingProfiles {
                profileChooser
            }
        }
    }

    /// "24 · Германия 9, США 7, Польша 5, без страны 3".
    private var profilesLine: String {
        guard !targets.isEmpty else { return L("warm.new.profiles.none") }
        let places = countries.prefix(4).map { "\($0.code.isEmpty ? L("warm.country.none") : WarmUpText.country($0.code)) \($0.count)" }
        return "\(targets.count) · " + places.joined(separator: ", ") + (countries.count > 4 ? "…" : "")
    }

    private var profileChooser: some View {
        let query = profileSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let listed = profiles.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || WarmUpText.country($0.countryCode).localizedCaseInsensitiveContains(query) }
        let free = listed.filter { !$0.isRunning && !$0.isWaiting }.map(\.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LumenSearchField(text: $profileSearch, prompt: L("warm.search"))
                Button(Set(free).isSubset(of: picked) && !free.isEmpty ? L("warmupQueue.selectNone") : L("warmupQueue.selectAll")) {
                    if Set(free).isSubset(of: picked) { picked.subtract(free) } else { picked.formUnion(free) }
                }
                .buttonStyle(.lumenGhost)
                .disabled(free.isEmpty)
                Button(L("warm.new.profiles.never")) { picked = Set(profiles.filter { $0.state == .never }.map(\.id)) }
                    .buttonStyle(.lumenGhost)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(listed) { item in
                        let busy = item.isRunning || item.isWaiting
                        Toggle(isOn: Binding(get: { picked.contains(item.id) && !busy },
                                             set: { if $0 { picked.insert(item.id) } else { picked.remove(item.id) } })) {
                            HStack(spacing: 8) {
                                ProfileAvatar(name: item.name, id: item.id, size: 20, style: item.avatar)
                                Text(item.name).font(.lumenBody).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(busy ? L("warmupQueue.inQueue") : WarmUpText.country(item.countryCode))
                                    .font(.lumenSecondary).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            }
                        }
                        .toggleStyle(.lumenCheckbox)
                        .disabled(busy)
                        .frame(height: 30)
                        .padding(.horizontal, 8)
                    }
                }
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    // MARK: What

    /// The lists offered: the person's own that fit the profiles' countries first, then the app's.
    private var offered: [(id: String, name: String, note: String)] {
        let own = templates.filter { template in
            guard let country = template.countryCode?.lowercased(), !country.isEmpty else { return true }
            return countries.contains { $0.code == country } || countries.isEmpty
        }.map { (id: $0.presetID, name: $0.name, note: String(format: L("warm.templates.ownSites"), $0.addresses.count)) }
        let ready = WarmUpInterest.allCases.map { interest in
            (id: interest.rawValue, name: L("warm.template." + interest.rawValue), note: "")
        }
        return own + ready
    }

    private var templatesPart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                caption(L("warm.new.templates"))
                Spacer()
                Text(L("warm.new.templates.note")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
            }
            VStack(spacing: 0) {
                ForEach(offered, id: \.id) { entry in
                    Toggle(isOn: Binding(get: { chosen.contains(entry.id) },
                                         set: { on in
                                             if on { if !chosen.contains(entry.id) { chosen.append(entry.id) } } else { chosen.removeAll { $0 == entry.id } }
                                         })) {
                        Text(entry.name).font(.lumenBody).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.lumenCheckbox)
                    .frame(height: 28)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
                }
            }
        }
    }

    // MARK: How much, and how

    private var intensityPart: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption(L("warm.new.intensity"))
            HStack(spacing: 12) {
                LumenSegmented(selection: $intensity, options: WarmUpIntensity.allCases.map { (value: $0, title: WarmUpText.intensity($0)) })
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("warm.new.intensity"))
                Text(String(format: L("warm.new.intensity.detail"), intensity.sites, intensity.pagesPerSite.upperBound,
                            WarmUpText.duration(intensity.estimatedSeconds())))
                    .font(.lumenSecondary).foregroundStyle(Theme.textSecondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setting<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.lumenBody).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 8)
            control()
        }
        .frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var behaviourPart: some View {
        VStack(alignment: .leading, spacing: 4) {
            caption(L("warm.new.behaviour"))
            setting(L("warm.new.viaSearch")) {
                Toggle("", isOn: $viaSearch).labelsHidden().toggleStyle(.lumenSwitch).controlSize(.small)
                    .accessibilityLabel(L("warm.new.viaSearch"))
            }
            setting(L("warm.new.consent")) {
                Picker("", selection: $consent) {
                    ForEach(WarmUpConsentChoice.allCases, id: \.self) { Text(L("warm.consent." + $0.rawValue)).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityLabel(L("warm.new.consent"))
            }
            setting(L("warmup.traffic")) {
                Picker("", selection: $trafficSaving) {
                    Text(L("warmup.traffic.all")).tag(WarmUpTrafficSaving?.none)
                    Text(L("warmup.traffic.media")).tag(WarmUpTrafficSaving?.some(.media))
                    Text(L("warmup.traffic.mediaAndImages")).tag(WarmUpTrafficSaving?.some(.mediaAndImages))
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityLabel(L("warmup.traffic"))
            }
            setting(L("warm.new.repeat")) {
                Picker("", selection: $repeatHours) {
                    Text(L("warm.new.repeat.off")).tag(0)
                    ForEach([6, 12, 24, 48, 72, 168], id: \.self) { Text(String(format: L("warm.new.repeat.hours"), $0)).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityLabel(L("warm.new.repeat"))
            }
            Text(L("warm.new.never")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    // MARK: What a profile will visit

    private func resample() {
        var generator = SystemRandomNumberGenerator()
        let plan = WarmUpPlanner.plan(templates: chosen, countryCode: previewCountry.isEmpty ? nil : previewCountry, intensity: intensity,
                                      userTemplates: templates, using: &generator)
        sample = plan?.pages().pages.compactMap { page in
            page.kind == .search ? page.query.map { "«\($0)»" } : WarmUpLinkPolicy.site(of: page.url)
        } ?? []
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                caption(L("warm.new.preview"))
                Spacer()
                if countries.count > 1 {
                    Picker("", selection: $previewCountry) {
                        ForEach(countries, id: \.code) { entry in
                            Text(verbatim: "\(entry.code.isEmpty ? L("warm.country.none") : WarmUpText.country(entry.code)) · \(entry.count)").tag(entry.code)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityLabel(L("warm.new.preview.country"))
                } else if let only = countries.first {
                    Text(only.code.isEmpty ? L("warm.country.none") : WarmUpText.country(only.code))
                        .font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
                }
            }
            if sample.isEmpty {
                Text(L("warm.new.preview.empty")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sample.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(.lumenSecondary)
                                .foregroundStyle(line.hasPrefix("«") ? Theme.textTertiary : Theme.textPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 24)
                        }
                    }
                }
            }
            Text(L("warm.new.preview.note")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: 14, fill: Theme.raisedInset)
    }

    // MARK: Start

    /// "Профилей: 24 · около 22 мин на каждый · всего около 2 ч 30 мин".
    private var total: String {
        guard !targets.isEmpty else { return L("warm.new.profiles.none") }
        let perProfile = intensity.estimatedSeconds()
        var parts = [String(format: L("warm.new.total.profiles"), targets.count), String(format: L("warm.new.total.each"), WarmUpText.duration(perProfile))]
        if targets.count > 1 {
            let atOnce = Double(min(max(1, WarmUpCoordinator.concurrency), targets.count))
            let all = perProfile * Double(targets.count) / atOnce
            parts.append(String(format: L("warm.new.total.all"), WarmUpText.duration(all)))
        }
        return parts.joined(separator: " · ")
    }

    private func start() {
        WarmUpCoordinator.trafficSaving = trafficSaving
        let choice = WarmUpChoice.templates(chosen, intensity: intensity, viaSearch: viaSearch, consent: consent)
        actions.start(targets.map(\.id), choice, repeatHours > 0 ? repeatHours : nil)
        dismiss()
    }
}

// MARK: - A run's report

struct WarmUpReportSheet: View {
    let request: WarmUpReportRequest
    var templates: [WarmUpTemplate] = []
    let again: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var run: WarmUpRun { request.run }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L("warm.report.title"), request.profile.name), subtitle: subtitle)
            VStack(alignment: .leading, spacing: 10) {
                Text(WarmUpText.summary(run))
                    .font(.lumenLabel).foregroundStyle(Theme.textPrimary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text(details)
                    .font(.lumenSecondary).foregroundStyle(Theme.textSecondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if let remark = WarmUpText.remark(run) {
                    Label(remark + (advice.map { " " + $0 } ?? ""), systemImage: "exclamationmark.triangle.fill")
                        .font(.lumenSecondary).foregroundStyle(remarkColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            table
                .padding(.horizontal, 24)
                .frame(maxHeight: .infinity, alignment: .top)
            SheetFooter(buttons: {
                Button(L("warm.inspector.again")) { dismiss(); again() }
                    .buttonStyle(.lumenSecondary)
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
            })
        }
        .sheetFrame(width: 760, height: 620)
        .background(Theme.raised)
    }

    /// "Сегодня, 19:34–19:58 · Германия · Обычный день, Покупки · обычный".
    private var subtitle: String {
        var parts = [run.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localization.locale))]
        if let code = run.countryCode { parts.append(WarmUpText.country(code)) }
        if !run.templates.isEmpty { parts.append(WarmUpText.templates(run.templates, names: run.templateNames, templates: templates)) }
        if let intensity = run.intensity.flatMap(WarmUpIntensity.init(rawValue:)) { parts.append(WarmUpText.intensity(intensity).lowercased()) }
        if run.scheduled { parts.append(L("warm.report.scheduled")) }
        return parts.joined(separator: " · ")
    }

    /// "Cookies с посещённых сайтов: 198, с других доменов: 14 · запросов: 3 · cookie-баннеров: 5".
    private var details: String {
        var parts = [String(format: L("warm.report.cookies"), run.cookiesVisited, run.cookiesOther)]
        let viaSearch = run.sites.filter { $0.arrivalKind == .search }.count
        if viaSearch > 0 { parts.append(String(format: L("warm.report.viaSearch"), viaSearch)) }
        if run.searches > 0 { parts.append(String(format: L("warm.summary.searches"), run.searches)) }
        if run.consents > 0 { parts.append(String(format: L("warm.summary.consents"), run.consents)) }
        return parts.joined(separator: " · ")
    }

    private var remarkColor: Color {
        switch run.resultKind {
        case .proxyNotAnswering, .notStarted: return Theme.danger
        default: return Theme.warning
        }
    }

    private var advice: String? {
        switch run.resultKind {
        case .proxyNotAnswering: return L("warm.advice.proxy")
        case .notStarted: return L("warm.advice.notStarted")
        default: return run.blockedSites.isEmpty ? nil : L("warm.advice.blocked")
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(L("warm.report.site")).lumenCaps().frame(maxWidth: .infinity, alignment: .leading)
                Text(L("warm.report.how")).lumenCaps().frame(width: 190, alignment: .leading)
                Text(L("warm.report.pages")).lumenCaps().frame(width: 80, alignment: .trailing)
                Text(L("warm.report.time")).lumenCaps().frame(width: 100, alignment: .trailing)
                Text(verbatim: "Cookies").lumenCaps().frame(width: 90, alignment: .trailing) // l10n: not text
            }
            .frame(height: 28)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
            if run.sites.isEmpty {
                Text(L("warm.report.noSites")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                    .padding(.top, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(run.sites) { visit in
                            HStack(spacing: 0) {
                                Text(verbatim: visit.site).font(.lumenLabel).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(visit.isProblem ? WarmUpText.problem(visit) : WarmUpText.arrival(visit))
                                    .font(.lumenSecondary).foregroundStyle(visit.isProblem ? Theme.warning : Theme.textSecondary).lineLimit(1)
                                    .frame(width: 190, alignment: .leading)
                                Text(verbatim: visit.pages > 0 ? "\(visit.pages)" : "—").font(.lumenBody).foregroundStyle(Theme.textPrimary)
                                    .frame(width: 80, alignment: .trailing)
                                Text(WarmUpText.duration(visit.seconds)).font(.lumenBody).foregroundStyle(Theme.textSecondary)
                                    .frame(width: 100, alignment: .trailing)
                                Text(verbatim: visit.cookies > 0 ? "+\(visit.cookies)" : "—").font(.lumenLabel)
                                    .foregroundStyle(visit.cookies > 0 ? Theme.textPrimary : Theme.textDisabled)
                                    .frame(width: 90, alignment: .trailing)
                            }
                            .monospacedDigit()
                            .frame(height: 32)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - A list of one's own

struct WarmUpTemplateEditor: View {
    /// The list being changed; nil: a new one.
    let template: WarmUpTemplate?
    let actions: WarmUpActions
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var addresses = ""
    @State private var searches = ""
    @State private var addsEveryday = true
    @State private var countryCode = ""
    @State private var importing = false
    @State private var loaded = false
    @State private var confirmingDelete = false

    private var reading: (pages: [WarmUpPlan.Page], problems: [WarmUpPlan.Problem]) {
        WarmUpPlan(addresses: addresses).pages()
    }

    var body: some View {
        let reading = self.reading
        return VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: template == nil ? L("warm.own.new") : L("warm.own.edit"), subtitle: L("warm.own.subtitle"))
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L("warmup.template.name"), text: $name, prompt: Text(verbatim: ""))
                        .lumenField(L("warmup.template.name"), isEmpty: name.isEmpty)
                    HStack {
                        Text(L("warm.own.addresses")).font(.lumenSection).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button(L("warm.own.paste")) { paste() }.buttonStyle(.lumenGhost)
                        Button(L("warm.own.import")) { importing = true }.buttonStyle(.lumenGhost)
                    }
                    .padding(.top, 6)
                    editor($addresses, label: L("warm.own.addresses"))
                        .frame(minHeight: 200, maxHeight: .infinity)
                    Text(L("warm.own.searches")).font(.lumenSection).foregroundStyle(Theme.textSecondary)
                        .padding(.top, 6)
                    editor($searches, label: L("warm.own.searches"))
                        .frame(height: 76)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(format: L("warm.own.result"), reading.pages.count, reading.problems.count))
                        .font(.lumenLabel).foregroundStyle(Theme.textPrimary).monospacedDigit()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(reading.problems.prefix(30).enumerated()), id: \.offset) { _, problem in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: String(format: L("warm.own.line"), problem.line) + "  " + problem.text)
                                        .font(.lumenMono).foregroundStyle(Theme.warning).lineLimit(1).truncationMode(.middle)
                                    Text(describe(problem.reason)).font(.lumenSecondary).foregroundStyle(Theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    Toggle(isOn: $addsEveryday) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("warm.own.everyday")).font(.lumenBody).foregroundStyle(Theme.textPrimary)
                            Text(L("warm.own.everyday.note")).font(.lumenSecondary).foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.lumenSwitch)
                    .controlSize(.small)
                    HStack {
                        Text(L("warm.own.country")).font(.lumenBody).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Picker("", selection: $countryCode) {
                            Text(L("warm.own.country.all")).tag("")
                            ForEach(WarmUpCatalog.countries, id: \.self) { Text(WarmUpText.country($0)).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                        .accessibilityLabel(L("warm.own.country"))
                    }
                }
                .frame(width: 300)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity, alignment: .top)
            SheetFooter(leading: {
                if let template {
                    Button(L("warm.own.delete")) { confirmingDelete = true }
                        .buttonStyle(.lumenDestructive)
                        .confirmationDialog(String(format: L("warm.own.delete.title"), template.name), isPresented: $confirmingDelete,
                                            titleVisibility: .visible) {
                            Button(L("warm.own.delete.confirm"), role: .destructive) { actions.deleteTemplate(template.id); dismiss() }
                        } message: {
                            Text(L("warm.own.delete.message"))
                        }
                }
            }, buttons: {
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("common.save")) { save() }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || reading.pages.isEmpty)
            })
        }
        .sheetFrame(width: 820, height: 620)
        .background(Theme.raised)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            guard let template else { return }
            name = template.name
            addresses = template.addresses.joined(separator: "\n")
            searches = template.searches.joined(separator: "\n")
            addsEveryday = template.addsEveryday ?? true
            countryCode = template.countryCode ?? ""
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .commaSeparatedText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else { return }
            append(text)
        }
    }

    private func editor(_ text: Binding<String>, label: String) -> some View {
        TextEditor(text: text)
            .font(.lumenMono)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).strokeBorder(Theme.fieldBorder, lineWidth: 1))
            .accessibilityLabel(label)
    }

    /// Adds lines to the list: a file's or the clipboard's, a spreadsheet's rows taken by their
    /// first column.
    private func append(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map { line -> String in
            let first = line.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" }).first.map(String.init) ?? ""
            return first.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        addresses += (addresses.isEmpty || addresses.hasSuffix("\n") ? "" : "\n") + lines.joined(separator: "\n")
    }

    private func paste() {
        if let text = NSPasteboard.general.string(forType: .string) { append(text) }
    }

    private func describe(_ reason: WarmUpPlan.Problem.Reason) -> String {
        switch reason {
        case .notAWebAddress: return L("warm.own.problem.notAddress")
        case let .unsupportedScheme(scheme): return String(format: L("warmup.reason.unsupportedScheme"), scheme)
        case .duplicate: return L("warmup.reason.duplicate")
        case .tooMany: return String(format: L("warmup.reason.tooMany"), WarmUpPlan.maximumPages)
        }
    }

    private func save() {
        guard var made = WarmUpTemplate(name: name, typedAddresses: addresses, typedSearches: searches) else { return }
        if let template {
            made.id = template.id
            made.createdAt = template.createdAt
        }
        made.addsEveryday = addsEveryday
        made.countryCode = countryCode.isEmpty ? nil : countryCode
        if actions.saveTemplate(made) { dismiss() }
    }
}
