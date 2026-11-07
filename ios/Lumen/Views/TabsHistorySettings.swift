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

/// A session's settings: its proxy and its search engine. Every change is saved and applied at once.
struct SessionSettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    @State private var settings = SessionSettings()
    @State private var proxyID: UUID?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Прокси") {
                    Picker("Прокси", selection: Binding(get: { proxyID }, set: { proxyID = $0; model.setProxy(sessionID, proxyID: $0) })) {
                        Text("Без прокси").tag(UUID?.none)
                        ForEach(model.proxies) { entry in
                            Text(entry.displayName).tag(UUID?.some(entry.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("proxyPicker")
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
                }
                loaded = true
            }
            .onChange(of: settings) { _, new in
                if loaded { model.setSettings(sessionID, new) }
            }
        }
    }
}
