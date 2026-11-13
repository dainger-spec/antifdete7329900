import LumenCore
import SwiftUI
import UIKit

/// A sheet's title with the session's name under it ("Настройки сессии / Checkout — staging").
struct SheetTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 1) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Tabs

/// The session's tabs (k-tabs): two columns of cards — the page, its title and site, a cross; the
/// tab on the screen outlined in the accent. "+" opens a new one.
struct TabsView: View {
    @ObservedObject var runtime: SessionRuntime
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                    ForEach(Array(runtime.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabCard(tab: tab, selected: tab.id == runtime.selectedID, index: index,
                                select: { runtime.select(tab.id); dismiss() },
                                close: { runtime.closeTab(tab.id) })
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L("Вкладки: %@", "\(runtime.tabs.count)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { SheetTitle(title: Count.tabs(runtime.tabs.count), subtitle: runtime.session.name) }
                ToolbarItem(placement: .topBarLeading) {
                    Button { runtime.newTab(); dismiss() } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("newTab").accessibilityLabel(L("Новая вкладка"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Готово")) { dismiss() }.accessibilityIdentifier("tabsDone")
                }
            }
        }
    }
}

struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let index: Int
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Button(action: select) {
                    ZStack {
                        Color(.secondarySystemGroupedBackground)
                        if let thumbnail = tab.thumbnail, tab.url != nil {
                            Image(uiImage: thumbnail).resizable().scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        } else {
                            Image(systemName: tab.url == nil ? "plus" : "globe").font(.title2).foregroundStyle(.secondary)
                        }
                    }
                    .aspectRatio(0.72, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color(.separator), lineWidth: selected ? 3 : 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title + ", " + site)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("tab-\(index)")
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityIdentifier("closeTab-\(index)")
                .accessibilityLabel(L("Закрыть вкладку"))
            }
            Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
            Text(site).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var title: String { tab.title.isEmpty ? L("Новая вкладка") : tab.title }
    private var site: String { tab.url?.host() ?? " " }
}

// MARK: History

/// The session's history (p5-history): search, the days — "Сегодня", "Вчера", then the dates — each
/// page's title and address, its time on the right; "Очистить историю" at the end.
struct HistoryView: View {
    @ObservedObject var runtime: SessionRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Day: Identifiable {
        let day: Date
        var entries: [HistoryEntry]
        var id: Date { day }
    }

    private var days: [Day] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let entries = runtime.history.reversed().filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.url.lowercased().contains(q) }
        let calendar = Calendar.current
        var result: [Day] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.visitedAt)
            if let last = result.indices.last, result[last].day == day { result[last].entries.append(entry) } else { result.append(Day(day: day, entries: [entry])) }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(days) { day in
                    Section(dayTitle(day.day)) {
                        ForEach(day.entries) { entry in
                            Button {
                                runtime.open(entry.url)
                                dismiss()
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title.isEmpty ? entry.url : entry.title).foregroundStyle(.primary).lineLimit(1)
                                        Text(shortAddress(entry.url)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text(entry.visitedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.locale)))
                                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .accessibilityIdentifier("historyRow")
                        }
                    }
                }
                if !runtime.history.isEmpty {
                    Section {
                        Button(L("Очистить историю"), role: .destructive) { runtime.clearHistory() }
                            .accessibilityIdentifier("clearHistory")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if runtime.history.isEmpty {
                    ContentUnavailableView {
                        Label(L("История пуста"), systemImage: "clock")
                    } description: {
                        Text(L("Здесь появятся страницы, открытые в этой сессии."))
                    }
                }
            }
            .modifier(HistorySearch(query: $query, enabled: !runtime.history.isEmpty))
            .navigationTitle(L("История"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { SheetTitle(title: L("История"), subtitle: runtime.session.name) }
                ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() }.accessibilityIdentifier("historyDone") }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return L("Сегодня") }
        if calendar.isDateInYesterday(day) { return L("Вчера") }
        return day.formatted(Date.FormatStyle().day().month(.wide).locale(Localization.locale))
    }

    private func shortAddress(_ url: String) -> String {
        var text = url
        for prefix in ["https://", "http://", "www."] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}

private struct HistorySearch: ViewModifier {
    @Binding var query: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L("Поиск в истории"))
        } else {
            content
        }
    }
}

// MARK: Settings

/// A session's settings (k-settings), in the order of what matters: the proxy, the time zone and
/// language, the device profile, the browser and search. Every change is saved and reaches the open
/// tabs at once (from their next page on).
struct SessionSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    @State private var settings = SessionSettings()
    @State private var proxyID: UUID?
    @State private var customUserAgent = ""
    @State private var loaded = false
    /// "Свой" chosen: the three switches shown, even while they still say what "Полный" says.
    @State private var customShown = false
    @State private var choosingProxy = false
    /// The plans, from the proxy section of a plan without proxies.
    @State private var showPlans = false

    private var session: Session? { model.session(sessionID) }
    private var proxy: ProxyEntry? { model.proxy(proxyID) }
    private var checking: Bool { proxyID.map { model.checking.contains($0) } ?? false }

    private var level: SessionSettings.ProfileLevel { customShown ? .custom : settings.profileLevel }

    private var userAgentTag: Binding<String> {
        Binding(get: {
            switch settings.userAgent {
            case .thisDevice: return "device"
            case let .preset(id): return id
            case .custom: return "custom"
            }
        }, set: { tag in
            switch tag {
            case "device": settings.userAgent = .thisDevice
            case "custom": settings.userAgent = .custom(customUserAgent)
            default: settings.userAgent = .preset(tag)
            }
        })
    }

    private var localeTag: Binding<String> {
        Binding(get: { if case .device = settings.locale { return "device" } else { return "proxy" } },
                set: { settings.locale = $0 == "device" ? .device : .proxyCountry })
    }

    /// The time zone and language the pages get now: the proxy's country's, set by hand, or the iPhone's.
    private var pageLocale: (zone: String, language: String) {
        var current = session ?? Session(name: "")
        current.settings = settings
        let locale = PageSettings.locale(of: current, proxy: model.access.proxies ? proxy : nil)
        return (locale.timeZone ?? TimeZone.current.identifier, locale.language ?? Locale.preferredLanguages.first ?? "en-US")
    }

    var body: some View {
        NavigationStack {
            Form {
                proxySection
                localeSection
                profileSection
                if level == .custom { customSection }
                browserSection
            }
            .navigationTitle(L("Настройки сессии"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { SheetTitle(title: L("Настройки сессии"), subtitle: session?.name ?? "") }
                ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() }.accessibilityIdentifier("settingsDone") }
            }
            .sheet(isPresented: $showPlans) { PlansView() }
            .sheet(isPresented: $choosingProxy) {
                ProxyChooser(sessionID: sessionID, chosen: $proxyID)
            }
            .sensoryFeedback(trigger: proxy?.check) { _, new in
                guard let new else { return nil }
                return new.alive ? .success : .error
            }
            .sensoryFeedback(.selection, trigger: level)
            .onAppear {
                if let session {
                    settings = session.settings
                    proxyID = session.proxyID
                    customShown = session.settings.profileLevel == .custom
                    if case let .custom(text) = session.settings.userAgent { customUserAgent = text }
                }
                loaded = true
            }
            .onChange(of: settings) { _, new in
                if loaded { model.setSettings(sessionID, new) }
            }
            .onChange(of: session?.proxyID) { _, new in proxyID = new }
        }
        .presentationDetents([.large])
    }

    // The proxy: its name and state, where it goes out; the chooser under it.
    @ViewBuilder private var proxySection: some View {
        if model.access.proxies || session?.boundToProxy == true {
            Section {
                Button { choosingProxy = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(proxy?.displayName ?? L("Без прокси")).foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            if proxy != nil {
                                StatusLight(light: Light.of(proxy, checking: checking))
                                Text(proxyState).foregroundStyle(.secondary)
                                    .contentTransition(.opacity)
                            }
                            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        if let proxy, !proxyPlace(proxy).isEmpty {
                            Text(proxyPlace(proxy)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(.easeInOut(duration: 0.2), value: proxyPlace(proxy))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("proxyRow")
                .accessibilityLabel(L("Прокси") + ": " + (proxy?.displayName ?? L("Без прокси")))
                .accessibilityValue(proxy.map { [proxyState, proxyPlace($0)].joined(separator: ", ") } ?? "")
                .animation(.easeInOut(duration: 0.2), value: checking)
            } header: {
                Text(L("Прокси"))
            } footer: {
                Text(proxy == nil ? L("Сессия открывает сайты с адресом этого iPhone.") : L("Сайты видят этот адрес, а не адрес iPhone."))
            }
        } else {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Прокси недоступны"))
                    Text(model.access.reason ?? L("В бесплатном доступе прокси нет")).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("proxiesNotOnPlan")
                }
                Button { showPlans = true } label: {
                    HStack {
                        Text(L("Аккаунт")).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("plansFromSettings")
            } header: {
                Text(L("Прокси"))
            } footer: {
                Text(L("Сессия открывает сайты с адресом этого iPhone."))
            }
        }
    }

    private var proxyState: String {
        if checking { return L("Проверка…") }
        guard let check = proxy?.check else { return L("Не проверен") }
        return check.alive ? L("Работает") : L("Не отвечает")
    }

    private func proxyPlace(_ proxy: ProxyEntry) -> String {
        let kind = proxy.kind == .socks5 ? "SOCKS5" : "HTTP"
        guard let check = proxy.check, check.alive else { return kind }
        return [check.country, check.exitIP, kind].compactMap { $0 }.joined(separator: " · ")
    }

    // The time zone and language: from the proxy's country, or the iPhone's own.
    private var localeSection: some View {
        let locale = pageLocale
        return Section {
            Picker(L("Задавать"), selection: localeTag) {
                Text(L("По стране прокси")).tag("proxy")
                Text(L("Как у устройства")).tag("device")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("localeMode")
            FactRow(title: L("Часовой пояс"), value: locale.zone, identifier: "localeZone")
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2).delay(0.24), value: locale.zone)
            FactRow(title: L("Язык страниц"), value: locale.language, identifier: "localeLanguage")
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2).delay(0.48), value: locale.language)
        } header: {
            Text(L("Часовой пояс и язык"))
        } footer: {
            Text(L("Сайты получают их из JavaScript. Заголовок Accept-Language у iPhone один на всё приложение."))
        }
    }

    // The device profile: three ways, one line each; "Свой" opens its three switches.
    private var profileSection: some View {
        Section(L("Профиль устройства")) {
            profileChoice(.full, L("Полный"), L("Канвас, WebGL и звук свои и постоянные"), id: "profile-full")
            profileChoice(.simplified, L("Упрощённый"), L("Только строка браузера, часовой пояс и язык"), id: "profile-simplified")
            profileChoice(.custom, L("Свой"), L("Канвас, WebGL и звук — по отдельности"), id: "profile-custom")
        }
    }

    private func profileChoice(_ choice: SessionSettings.ProfileLevel, _ title: String, _ note: String, id: String) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.28, extraBounce: 0)) {
                customShown = choice == .custom
                if choice != .custom { settings.profileLevel = choice }
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if level == choice {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .transition(.identity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(level == choice ? .isSelected : [])
    }

    private var customSection: some View {
        Section {
            modePicker(L("Канвас"), $settings.canvas, id: "canvasMode")
            modePicker("WebGL", $settings.webGL, id: "webglMode")
            modePicker(L("Звук"), $settings.audio, id: "audioMode")
        } footer: {
            Text(L("Выкл — сайт не получит значение. Настоящий — как у этого iPhone. Шум — своё значение у этой сессии, одно и то же при каждом запуске."))
        }
    }

    private func modePicker(_ title: String, _ value: Binding<FingerprintMode>, id: String) -> some View {
        Picker(title, selection: value) {
            Text(L("Выкл")).tag(FingerprintMode.off)
            Text(L("Настоящий")).tag(FingerprintMode.real)
            Text(L("Шум")).tag(FingerprintMode.noise)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier(id)
    }

    // The browser's identity and the search engine.
    private var browserSection: some View {
        Section(L("Браузер и поиск")) {
            Picker(L("Браузер"), selection: userAgentTag) {
                Text(L("Как Safari этого iPhone")).tag("device")
                Section {
                    ForEach(UserAgentPreset.all) { preset in Text(preset.title).tag(preset.id) }
                }
                Section {
                    Text(L("Своя")).tag("custom")
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("userAgentPicker")
            if case .custom = settings.userAgent {
                TextField(L("Своя строка браузера"), text: $customUserAgent, axis: .vertical)
                    .font(.subheadline.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: customUserAgent) { _, text in settings.userAgent = .custom(text) }
                    .accessibilityIdentifier("customUA")
            }
            Picker(L("Поисковик"), selection: $settings.searchEngine) {
                ForEach(SearchEngine.allCases) { engine in Text(engine.title).tag(engine) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("searchEnginePicker")
        }
    }
}

/// The session's proxy, chosen from the list (k-sheet-mid): each with its light and where it goes
/// out; one that does not answer says why. Taking away the proxy of a session that worked through
/// one is asked first (k-alert): without it the sites would see the iPhone's own address.
struct ProxyChooser: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    @Binding var chosen: UUID?
    @State private var confirmUnbind = false

    private var session: Session? { model.session(sessionID) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    choice(nil)
                    ForEach(model.proxies) { entry in choice(entry) }
                }
            }
            .navigationTitle(L("Прокси сессии"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() }.accessibilityIdentifier("proxySheetDone") }
            }
            .alert(L("Открывать без прокси?"), isPresented: $confirmUnbind) {
                Button(L("Оставить прокси"), role: .cancel) {}
                Button(L("Открывать без прокси"), role: .destructive) {
                    chosen = nil
                    model.setProxy(sessionID, proxyID: nil, unbind: true)
                    dismiss()
                }
                .accessibilityIdentifier("confirmUnbind")
            } message: {
                Text(L("Эта сессия работала через прокси «%@». Без него сайты увидят настоящий адрес iPhone.",
                       model.proxy(session?.proxyID)?.displayName ?? ""))
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func choice(_ entry: ProxyEntry?) -> some View {
        let id = entry?.id
        let checking = id.map { model.checking.contains($0) } ?? false
        return Button {
            if id == nil, session?.boundToProxy == true, session?.proxyID != nil {
                confirmUnbind = true
                return
            }
            chosen = id
            model.setProxy(sessionID, proxyID: id)
            dismiss()
        } label: {
            HStack(alignment: .firstLineCenter, spacing: 12) {
                if let entry { StatusLight(light: Light.of(entry, checking: checking)).centredOnFirstLine(of: .body) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry?.displayName ?? L("Без прокси")).foregroundStyle(.primary)
                    if let entry { detail(entry, checking: checking).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
                }
                Spacer(minLength: 8)
                if chosen == id {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry?.displayName ?? L("Без прокси"))
        .accessibilityValue(entry.map { ProxyWords.summary($0, checking: checking) } ?? "")
        .accessibilityAddTraits(chosen == id ? .isSelected : [])
        .accessibilityIdentifier(entry == nil ? "proxyNone" : "choose-\(entry!.displayName)")
    }

    private func detail(_ entry: ProxyEntry, checking: Bool) -> Text {
        let kind = entry.kind == .socks5 ? "SOCKS5" : "HTTP"
        if checking { return Text(L("Проверка…")) }
        guard let check = entry.check else { return Text([L("не проверен"), kind].joined(separator: " · ")) }
        guard check.alive else {
            return Text(L("не отвечает")).foregroundColor(Color(.systemRed)) + Text(check.error.map { ": " + $0 } ?? "")
        }
        return Text([check.country, check.exitIP, kind].compactMap { $0 }.joined(separator: " · "))
    }
}

/// A proxy in plain words, for VoiceOver.
enum ProxyWords {
    static func summary(_ entry: ProxyEntry, checking: Bool) -> String {
        if checking { return L("Проверка…") }
        guard let check = entry.check else { return L("Не проверен") }
        guard check.alive else { return L("Недоступен: %@", check.error ?? L("нет ответа")) }
        return ([L("Работает")] + [check.country, check.exitIP]).compactMap { $0 }.joined(separator: " · ")
    }
}
