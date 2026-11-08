import LumenCore
import SwiftUI
import WebKit

/// A session's browser: the address bar, the selected tab's page, and the bar below it.
struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runtime: SessionRuntime
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case tabs, history, settings
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let tab = runtime.selected {
                AddressBar(tab: tab) { runtime.open($0) }
                    .id(tab.id)
                ZStack {
                    WebViewContainer(webView: tab.webView)
                    StartPage(tab: tab)
                }
                BottomBar(tab: tab, tabCount: runtime.tabs.count) { sheet = $0 }
                    .id("bar-\(tab.id)")
            }
            if TestHooks.enabled, let port = runtime.relayPort {
                Text(verbatim: "relay \(port)")
                    .font(.caption2)
                    .accessibilityIdentifier("debugRelayPort")
            }
        }
        .navigationTitle(runtime.session.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheet) { which in
            switch which {
            case .tabs: TabsView(runtime: runtime)
            case .history: HistoryView(runtime: runtime)
            case .settings: SessionSettingsView(sessionID: runtime.sessionID)
            }
        }
    }
}

/// The address of the page, or what is being typed: an address or a search.
struct AddressBar: View {
    @ObservedObject var tab: BrowserTab
    let submit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Адрес или поиск", text: $text)
                .focused($focused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit {
                    submit(text)
                    focused = false
                }
                .accessibilityIdentifier("addressBar")
            if tab.isLoading { ProgressView().accessibilityIdentifier("loading") }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { text = tab.url?.absoluteString ?? "" }
        .onChange(of: tab.url) { _, url in if !focused { text = url?.absoluteString ?? "" } }
        .onChange(of: focused) { _, isFocused in if !isFocused { text = tab.url?.absoluteString ?? text } }
    }
}

/// What an empty tab shows.
struct StartPage: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        if tab.url == nil {
            VStack(spacing: 8) {
                Image(systemName: "globe").font(.largeTitle).foregroundStyle(.secondary)
                Text("Новая вкладка").font(.title3)
                Text("Введите адрес или запрос").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("startPage")
        }
    }
}

struct BottomBar: View {
    @ObservedObject var tab: BrowserTab
    let tabCount: Int
    let show: (BrowserView.Sheet) -> Void

    var body: some View {
        HStack {
            Button { if !Faults.isActive(.backIgnored) { tab.webView.goBack() } } label: { Image(systemName: "chevron.backward") }
                .disabled(!tab.canGoBack).accessibilityIdentifier("back").accessibilityLabel("Назад")
            Spacer()
            Button { if !Faults.isActive(.forwardIgnored) { tab.webView.goForward() } } label: { Image(systemName: "chevron.forward") }
                .disabled(!tab.canGoForward).accessibilityIdentifier("forward").accessibilityLabel("Вперёд")
            Spacer()
            Button { if !Faults.isActive(.reloadIgnored) { tab.webView.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(tab.url == nil).accessibilityIdentifier("reload").accessibilityLabel("Обновить")
            Spacer()
            Button { show(.tabs) } label: {
                Text("\(tabCount)").font(.footnote.bold()).frame(minWidth: 22, minHeight: 22)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.5))
            }
            .accessibilityIdentifier("tabsButton").accessibilityLabel("Вкладки: \(tabCount)")
            Spacer()
            Button { show(.history) } label: { Image(systemName: "clock") }
                .accessibilityIdentifier("historyButton").accessibilityLabel("История")
            Spacer()
            Button { show(.settings) } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityIdentifier("settingsButton").accessibilityLabel("Настройки сессии")
        }
        .font(.title3)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Hosts the selected tab's WKWebView; switching tabs swaps the view, the pages stay loaded.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ container: UIView, context: Context) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}
