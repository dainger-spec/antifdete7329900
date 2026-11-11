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
            #if DEBUG
            if TestHooks.enabled {
                // The tests' view of the session's relay, and their drills on it.
                HStack(spacing: 16) {
                    Text(verbatim: runtime.relayPort.map { "relay \($0)" } ?? "relay down")
                        .accessibilityIdentifier("debugRelayPort")
                    Button(L("сеть")) { runtime.drill(.networkChange) }
                        .accessibilityIdentifier("debugNetworkChange")
                    Button(L("смерть")) { runtime.drill(.death) }
                        .accessibilityIdentifier("debugRelayDeath")
                    Button(L("перезапуск")) { runtime.drill(.restart) }
                        .accessibilityIdentifier("debugRelayRestart")
                }
                .font(.caption2)
            }
            #endif
        }
        .background(Theme.ground)
        .navigationTitle(runtime.session.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The session's name, and under it where it goes out: the proxy's country and name.
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(model.session(runtime.sessionID)?.name ?? runtime.session.name)
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(exitLine).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("sessionExit")
                }
                .lineLimit(1)
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .tabs: TabsView(runtime: runtime)
            case .history: HistoryView(runtime: runtime)
            case .settings: SessionSettingsView(sessionID: runtime.sessionID)
            }
        }
    }
}

extension BrowserView {
    /// "🇩🇪 DE · Berlin 1": the proxy's country, once its check knows it, and its name.
    var exitLine: String {
        guard let proxy = model.proxy(model.session(runtime.sessionID)?.proxyID) else { return L("Без прокси") }
        guard let country = proxy.check?.country, proxy.check?.alive == true else { return proxy.displayName }
        return "\(CountryLocale.flag(country)) \(country) · \(proxy.displayName)"
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
            TextField(L("Адрес или поиск"), text: $text)
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
        .font(.system(size: 15))
        .padding(.horizontal, 16)
        .frame(height: 46)
        .glassPane(radius: 23)
        .padding(.horizontal, 16)
        .padding(.top, 4).padding(.bottom, 10)
        .background(Theme.ground)
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
            VStack(spacing: 12) {
                Image(systemName: "globe").font(.system(size: 28)).foregroundStyle(Theme.secondary)
                    .frame(width: 72, height: 72).glassPane(radius: 36)
                Text(L("Новая вкладка")).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text).padding(.top, 4)
                Text(L("Введите адрес или запрос")).font(.system(size: 16)).foregroundStyle(Theme.secondary)
                // Where a search goes from here: the session's own engine.
                if let engine = tab.runtime?.session.settings.searchEngine {
                    Text(L("Поисковик: %@", engine.title))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 13).frame(height: 30)
                        .background(Color.white.opacity(0.06), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(EclipseBackground())
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
                .disabled(!tab.canGoBack).accessibilityIdentifier("back").accessibilityLabel(L("Назад"))
            Spacer()
            Button { if !Faults.isActive(.forwardIgnored) { tab.webView.goForward() } } label: { Image(systemName: "chevron.forward") }
                .disabled(!tab.canGoForward).accessibilityIdentifier("forward").accessibilityLabel(L("Вперёд"))
            Spacer()
            Button { if !Faults.isActive(.reloadIgnored) { tab.webView.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(tab.url == nil).accessibilityIdentifier("reload").accessibilityLabel(L("Обновить"))
            Spacer()
            Button { show(.tabs) } label: {
                Text("\(tabCount)").font(.system(size: 12, weight: .bold)).frame(minWidth: 22, minHeight: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(lineWidth: 1.6))
            }
            .accessibilityIdentifier("tabsButton").accessibilityLabel(L("Вкладки: %@", "\(tabCount)"))
            Spacer()
            Button { show(.history) } label: { Image(systemName: "clock") }
                .accessibilityIdentifier("historyButton").accessibilityLabel(L("История"))
            Spacer()
            Button { show(.settings) } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityIdentifier("settingsButton").accessibilityLabel(L("Настройки сессии"))
        }
        .font(.system(size: 19))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 22)
        .frame(height: 60)
        .glassPane(radius: 30)
        .padding(.horizontal, 14)
        .padding(.top, 8).padding(.bottom, 4)
        .background(Theme.ground)
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
