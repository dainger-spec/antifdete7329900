import LumenCore
import SwiftUI

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
            .navigationTitle("Вкладки: \(runtime.tabs.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button { runtime.newTab(); dismiss() } label: { Label("Новая вкладка", systemImage: "plus") }
                        .accessibilityIdentifier("newTab")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }.accessibilityIdentifier("tabsDone")
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
                    Image(systemName: tab.url == nil ? "plus.square.dashed" : "doc.richtext")
                        .font(.largeTitle).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 90)
                    Text(tab.title.isEmpty ? "Новая вкладка" : tab.title).font(.subheadline.bold()).lineLimit(1)
                    Text(tab.url?.host() ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tab-\(index)")
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .padding(6)
            .accessibilityIdentifier("closeTab-\(index)")
            .accessibilityLabel("Закрыть вкладку")
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
                    ContentUnavailableView("История пуста", systemImage: "clock")
                }
                ForEach(runtime.history.reversed()) { entry in
                    Button {
                        runtime.open(entry.url)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title.isEmpty ? entry.url : entry.title).lineLimit(1)
                            Text(entry.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .accessibilityIdentifier("historyRow")
                }
            }
            .navigationTitle("История")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() }.accessibilityIdentifier("historyDone") }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Очистить", role: .destructive) { runtime.clearHistory() }.disabled(runtime.history.isEmpty)
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
            return settings.locale == .device ? "Как у устройства" : "Нет проверенного прокси: как у устройства"
        }
        return [locale.timeZone, locale.language].compactMap { $0 }.joined(separator: " · ")
    }

    private func modePicker(_ title: String, _ value: Binding<FingerprintMode>, id: String) -> some View {
        Picker(title, selection: value) {
            Text("Выкл").tag(FingerprintMode.off)
            Text("Настоящий").tag(FingerprintMode.real)
            Text("Шум").tag(FingerprintMode.noise)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Прокси") {
                    Picker("Прокси", selection: Binding(get: { proxyID }, set: { chosen in
                        // A session that lived behind a proxy goes without one only when the person
                        // says so, knowing what it means; otherwise it stays bound (and locked).
                        if chosen == nil, model.session(sessionID)?.boundToProxy == true {
                            confirmUnbind = true
                            return
                        }
                        proxyID = chosen
                        model.setProxy(sessionID, proxyID: chosen)
                    })) {
                        Text("Без прокси").tag(UUID?.none)
                        ForEach(model.proxies) { entry in
                            Text(entry.displayName).tag(UUID?.some(entry.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("proxyPicker")
                    .confirmationDialog("Профиль работал через прокси", isPresented: $confirmUnbind, titleVisibility: .visible) {
                        Button("Открывать без прокси", role: .destructive) {
                            proxyID = nil
                            model.setProxy(sessionID, proxyID: nil, unbind: true)
                        }
                        .accessibilityIdentifier("confirmUnbind")
                        Button("Оставить прокси", role: .cancel) {}
                    } message: {
                        Text("Без прокси сайты этого профиля увидят настоящий адрес устройства.")
                    }
                }
                Section("Браузер (строка User-Agent)") {
                    Picker("Строка браузера", selection: userAgentTag) {
                        Text("Как Safari этого iPhone").tag("device")
                        ForEach(UserAgentPreset.all) { preset in Text(preset.title).tag(preset.id) }
                        Text("Своя").tag("custom")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("userAgentPicker")
                    if case .custom = settings.userAgent {
                        TextField("Своя строка", text: $customUserAgent)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { settings.userAgent = .custom(customUserAgent) }
                            .onChange(of: customUserAgent) { _, text in settings.userAgent = .custom(text) }
                            .accessibilityIdentifier("customUA")
                    }
                }
                Section {
                    Picker("Часовой пояс и язык", selection: localeTag) {
                        Text("По стране прокси").tag("proxy")
                        Text("Как у устройства").tag("device")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("localeMode")
                    Text(localeSummary).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("localeSummary")
                } header: {
                    Text("Часовой пояс и язык")
                } footer: {
                    Text("Язык страницы меняется только в navigator.language: заголовок Accept-Language WebKit на iPhone задаёт один на всё приложение.")
                }
                Section("Профиль устройства") {
                    modePicker("Канвас", $settings.canvas, id: "canvasMode")
                    modePicker("WebGL", $settings.webGL, id: "webglMode")
                    modePicker("Звук", $settings.audio, id: "audioMode")
                }
                Section("Поисковик") {
                    Picker("Поисковик", selection: $settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("searchEnginePicker")
                }
            }
            .navigationTitle("Настройки сессии")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() }.accessibilityIdentifier("settingsDone") }
            }
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
