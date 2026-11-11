import LumenCore
import SwiftUI
import UIKit

/// The session's tabs as cards: pick one, close one, open a new one.
struct TabsView: View {
    @ObservedObject var runtime: SessionRuntime
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Array(runtime.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabCard(tab: tab, selected: tab.id == runtime.selectedID, index: index,
                                select: { runtime.select(tab.id); dismiss() },
                                close: { runtime.closeTab(tab.id) })
                    }
                }
                .padding()
            }
            .background(Theme.ground.opacity(0.55).ignoresSafeArea())
            .navigationTitle(L("Вкладки: %@", "\(runtime.tabs.count)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button { runtime.newTab(); dismiss() } label: { Label(L("Новая вкладка"), systemImage: "plus").labelStyle(.titleAndIcon) }
                        .accessibilityIdentifier("newTab")
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
        ZStack(alignment: .topTrailing) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    // The page as it last finished loading; an empty tab, or one not drawn yet, its sign.
                    ZStack {
                        if let thumbnail = tab.thumbnail, tab.url != nil {
                            Image(uiImage: thumbnail).resizable().scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        } else {
                            Image(systemName: tab.url == nil ? "plus" : "globe")
                                .font(.system(size: 24)).foregroundStyle(Theme.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 130, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                    Text(tab.title.isEmpty ? L("Новая вкладка") : tab.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(tab.url?.host() ?? " ").font(.system(size: 12)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPane(radius: 24)
                // The tab on the screen now: a white edge.
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(selected ? Theme.text : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tab-\(index)")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.text)
                    .frame(width: 28, height: 28).background(Color.white.opacity(0.12), in: Circle())
            }
            .padding(8)
            .accessibilityIdentifier("closeTab-\(index)")
            .accessibilityLabel(L("Закрыть вкладку"))
        }
    }
}

/// The session's history, newest first; a row opens its page in the current tab.
struct HistoryView: View {
    @ObservedObject var runtime: SessionRuntime
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if runtime.history.isEmpty {
                    ContentUnavailableView(L("История пуста"), systemImage: "clock")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(runtime.history.reversed()) { entry in
                    Button {
                        runtime.open(entry.url)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            InitialBadge(name: URL(string: entry.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? entry.url, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title.isEmpty ? entry.url : entry.title).foregroundStyle(Theme.text).lineLimit(1)
                                Text(entry.url).font(.system(size: 13)).foregroundStyle(Theme.tertiary).lineLimit(1)
                            }
                        }
                    }
                    .accessibilityIdentifier("historyRow")
                    .glassRow()
                }
            }
            .eclipseSheet()
            .navigationTitle(L("История"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() }.accessibilityIdentifier("historyDone") }
                ToolbarItem(placement: .destructiveAction) {
                    Button(L("Очистить"), role: .destructive) { runtime.clearHistory() }.disabled(runtime.history.isEmpty)
                }
            }
        }
    }
}

/// A session's settings: proxy, User-Agent, time zone and language, canvas/WebGL/audio, search engine.
/// Every change is saved and reaches the open tabs at once (from their next page on).
struct SessionSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    @State private var settings = SessionSettings()
    @State private var proxyID: UUID?
    /// "Без прокси" chosen for a session that lived behind one: asked first (it would go directly).
    @State private var confirmUnbind = false
    @State private var customUserAgent = ""
    @State private var loaded = false
    /// The plans, from the proxy section of a plan without proxies.
    @State private var showPlans = false

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

    private var localeSummary: String {
        guard let session = model.session(sessionID) else { return "" }
        var current = session
        current.settings = settings
        let locale = PageSettings.locale(of: current, proxy: model.proxy(proxyID))
        if locale.timeZone == nil && locale.language == nil {
            return settings.locale == .device ? L("Как у устройства") : L("Нет проверенного прокси: как у устройства")
        }
        return [locale.timeZone, locale.language].compactMap { $0 }.joined(separator: " · ")
    }

    private func modePicker(_ title: String, _ value: Binding<FingerprintMode>, id: String) -> some View {
        Picker(title, selection: value) {
            Text(L("Выкл")).tag(FingerprintMode.off)
            Text(L("Настоящий")).tag(FingerprintMode.real)
            Text(L("Шум")).tag(FingerprintMode.noise)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // A plan without proxies (the free plan) offers none: the profile goes without one.
                    // One that lived behind a proxy keeps its choice (it is locked and not shown here).
                    if model.access.proxies || model.session(sessionID)?.boundToProxy == true {
                        Picker(L("Прокси"), selection: Binding(get: { proxyID }, set: { chosen in
                            // A session that lived behind a proxy goes without one only when the person
                            // says so, knowing what it means; otherwise it stays bound (and locked).
                            if chosen == nil, model.session(sessionID)?.boundToProxy == true {
                                confirmUnbind = true
                                return
                            }
                            proxyID = chosen
                            model.setProxy(sessionID, proxyID: chosen)
                        })) {
                            Text(L("Без прокси")).tag(UUID?.none)
                            ForEach(model.proxies) { entry in
                                Text(entry.displayName).tag(UUID?.some(entry.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .accessibilityIdentifier("proxyPicker")
                        .confirmationDialog(L("Профиль работал через прокси"), isPresented: $confirmUnbind, titleVisibility: .visible) {
                            Button(L("Открывать без прокси"), role: .destructive) {
                                proxyID = nil
                                model.setProxy(sessionID, proxyID: nil, unbind: true)
                            }
                            .accessibilityIdentifier("confirmUnbind")
                            Button(L("Оставить прокси"), role: .cancel) {}
                        } message: {
                            Text(L("Без прокси сайты этого профиля увидят настоящий адрес устройства."))
                        }
                    } else {
                        Text(L("Без прокси")).accessibilityIdentifier("proxyNone")
                    }
                } header: {
                    Text(L("Прокси"))
                } footer: {
                    if !model.access.proxies {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.access.reason ?? L("Прокси недоступны.")).accessibilityIdentifier("proxiesNotOnPlan")
                            Button(L("Аккаунт")) { showPlans = true }.accessibilityIdentifier("plansFromSettings")
                        }
                    }
                }
                .glassRow()
                Section(L("Браузер (строка User-Agent)")) {
                    Picker(L("Строка браузера"), selection: userAgentTag) {
                        Text(L("Как Safari этого iPhone")).tag("device")
                        ForEach(UserAgentPreset.all) { preset in Text(preset.title).tag(preset.id) }
                        Text(L("Своя")).tag("custom")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("userAgentPicker")
                    if case .custom = settings.userAgent {
                        TextField(L("Своя строка"), text: $customUserAgent)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { settings.userAgent = .custom(customUserAgent) }
                            .onChange(of: customUserAgent) { _, text in settings.userAgent = .custom(text) }
                            .accessibilityIdentifier("customUA")
                    }
                }
                .glassRow()
                Section {
                    Picker(L("Часовой пояс и язык"), selection: localeTag) {
                        Text(L("По стране прокси")).tag("proxy")
                        Text(L("Как у устройства")).tag("device")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("localeMode")
                    Text(localeSummary).font(.footnote).foregroundStyle(Theme.secondary).accessibilityIdentifier("localeSummary")
                } header: {
                    Text(L("Часовой пояс и язык"))
                } footer: {
                    Text(L("Язык страницы меняется только в navigator.language: заголовок Accept-Language WebKit на iPhone задаёт один на всё приложение."))
                }
                .glassRow()
                Section {
                    Picker(L("Профиль устройства"), selection: $settings.profileLevel) {
                        Text(L("Полный")).tag(SessionSettings.ProfileLevel.full)
                        Text(L("Упрощённый")).tag(SessionSettings.ProfileLevel.simplified)
                        if settings.profileLevel == .custom { Text(L("Свой")).tag(SessionSettings.ProfileLevel.custom) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("profileLevel")
                    modePicker(L("Канвас"), $settings.canvas, id: "canvasMode")
                    modePicker("WebGL", $settings.webGL, id: "webglMode")
                    modePicker(L("Звук"), $settings.audio, id: "audioMode")
                } header: {
                    Text(L("Профиль устройства"))
                } footer: {
                    Text(L("Полный: канвас, WebGL и звук у профиля свои. Упрощённый: только строка браузера, часовой пояс и язык."))
                }
                .glassRow()
                Section(L("Поисковик")) {
                    Picker(L("Поисковик"), selection: $settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("searchEnginePicker")
                }
                .glassRow()
            }
            .eclipseSheet()
            .navigationTitle(L("Настройки сессии"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() }.accessibilityIdentifier("settingsDone") }
            }
            .sheet(isPresented: $showPlans) { PlansView() }
            .onAppear {
                if let session = model.session(sessionID) {
                    settings = session.settings
                    proxyID = session.proxyID
                    if case let .custom(text) = session.settings.userAgent { customUserAgent = text }
                }
                loaded = true
            }
            .onChange(of: settings) { _, new in
                if loaded { model.setSettings(sessionID, new) }
            }
        }
    }
}
