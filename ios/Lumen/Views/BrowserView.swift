import LumenCore
import SwiftUI
import WebKit

/// A session's browser (k-browser): above, the system's back button and the session's name with
/// where it goes out under it; the page under both bars; below, the floating address capsule and
/// the bar — back, forward, tabs, history, the session's settings.
struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runtime: SessionRuntime
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case tabs, history, settings
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if let tab = runtime.selected {
                TabPage(tab: tab, runtime: runtime, sheet: $sheet)
                    .id(tab.id)
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Leaving the browser, the window takes the app's own scheme back.
        .onDisappear { model.lightPageShown = false }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(session.name).font(.headline).foregroundStyle(.primary)
                    HStack(spacing: 5) {
                        StatusLight(light: light)
                        Text(PageWords.exitLine(session, proxy: proxy, checking: checking))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sessionExit")
                }
                .lineLimit(1)
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .tabs: TabsView(runtime: runtime).preferredColorScheme(Theme.colorScheme)
            case .history: HistoryView(runtime: runtime).preferredColorScheme(Theme.colorScheme)
            case .settings: SessionSettingsView(sessionID: runtime.sessionID).preferredColorScheme(Theme.colorScheme)
            }
        }
    }

    private var session: Session { model.session(runtime.sessionID) ?? runtime.session }
    private var proxy: ProxyEntry? { model.usableProxy(session) }
    private var checking: Bool { proxy.map { model.checking.contains($0.id) } ?? false }

    private var light: Light {
        if let failure = runtime.selected?.failure, proxy != nil, PageWords.proxyFailure(failure) { return .failing }
        return Light.of(proxy, checking: checking)
    }
}

/// One tab on the screen: its page (or the new tab's words, or the proxy that does not answer), the
/// capsule and the bar.
private struct TabPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tab: BrowserTab
    @ObservedObject var runtime: SessionRuntime
    @Binding var sheet: BrowserView.Sheet?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            WebViewContainer(webView: tab.webView)
                .ignoresSafeArea()
            if tab.url == nil {
                NewTabPage(engine: runtime.session.settings.searchEngine)
            } else if let failure = tab.failure, let proxy = model.usableProxy(runtime.session), PageWords.proxyFailure(failure) {
                ProxyNotAnswering(proxyName: proxy.displayName, retry: { tab.retry() }, settings: { sheet = .settings })
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                AddressCapsule(tab: tab) { runtime.open($0) }
                    .environment(\.colorScheme, pageScheme ?? colorScheme)
                #if DEBUG
                if TestHooks.enabled { RelayDrills(runtime: runtime) }
                #endif
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { if !Faults.isActive(.backIgnored) { tab.webView.goBack() } } label: { Image(systemName: "chevron.backward") }
                    .disabled(!tab.canGoBack).accessibilityIdentifier("back").accessibilityLabel(L("Назад"))
                Spacer()
                Button { if !Faults.isActive(.forwardIgnored) { tab.webView.goForward() } } label: { Image(systemName: "chevron.forward") }
                    .disabled(!tab.canGoForward).accessibilityIdentifier("forward").accessibilityLabel(L("Вперёд"))
                Spacer()
                Button { sheet = .tabs } label: {
                    Image(systemName: runtime.tabs.count <= 50 ? "\(runtime.tabs.count).square" : "square.on.square")
                }
                .accessibilityIdentifier("tabsButton").accessibilityLabel(L("Вкладки: %@", "\(runtime.tabs.count)"))
                Spacer()
                Button { sheet = .history } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityIdentifier("historyButton").accessibilityLabel(L("История"))
                Spacer()
                Button { sheet = .settings } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityIdentifier("settingsButton").accessibilityLabel(L("Настройки сессии"))
            }
        }
        // Over a white site the bars and the status bar go light, as Safari's do: the window's scheme
        // follows the page (a bar's own scheme left 9:41 white on white, runs 108 and 110). The sheets
        // keep the app's own (above).
        .toolbarColorScheme(pageScheme, for: .navigationBar, .bottomBar)
        .onChange(of: pageIsLight, initial: true) { _, light in model.lightPageShown = light }
    }

    /// A site's own light page is on the screen (not the new tab's words, not the proxy that does not answer).
    private var pageIsLight: Bool { tab.lightPage && tab.url != nil && tab.failure == nil }

    /// The bars' scheme: light over a site's light page, else the app's own — not dark: in the light
    /// theme a dark bar wrote the session's name white on the new tab's white (runs 120, 121).
    private var pageScheme: ColorScheme? { pageIsLight ? .light : Theme.colorScheme }
}

/// The address capsule (iOS 26: the system's glass; iOS 18: the bar's material): a lock and the
/// site's domain, "Обновить" — or "Стоп" and a neutral line along its lower edge while a page loads.
/// Touched, it is the field: the whole address, to change or to search.
struct AddressCapsule: View {
    @ObservedObject var tab: BrowserTab
    let submit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var showsDomain: Bool { !focused && tab.url != nil }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                // The field holds the whole address at all times (VoiceOver reads it, the tests check
                // it); away from the keyboard its letters give way to the lock and the domain.
                TextField(L("Адрес или запрос"), text: $text)
                    .focused($focused)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .multilineTextAlignment(focused ? .leading : .center)
                    .foregroundStyle(showsDomain ? Color.clear : Color.primary)
                    .onSubmit {
                        submit(text)
                        focused = false
                    }
                    .accessibilityIdentifier("addressBar")
                if showsDomain {
                    HStack(spacing: 4) {
                        if tab.url?.scheme == "https" {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(PageWords.domain(tab.url)).lineLimit(1).truncationMode(.middle)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            if !focused, tab.url != nil {
                if tab.isLoading {
                    Button { tab.webView.stopLoading() } label: { Image(systemName: "xmark") }
                        .accessibilityIdentifier("stop").accessibilityLabel(L("Стоп"))
                } else {
                    Button { if !Faults.isActive(.reloadIgnored) { tab.webView.reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityIdentifier("reload").accessibilityLabel(L("Обновить"))
                }
            }
        }
        .font(.body)
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) {
            if tab.isLoading {
                GeometryReader { geometry in
                    Rectangle().fill(Theme.progress)
                        .frame(width: geometry.size.width * max(0.05, tab.progress), height: 2)
                        .animation(.linear(duration: 0.2), value: tab.progress)
                }
                .frame(height: 2)
                .accessibilityHidden(true)
            }
        }
        .modifier(CapsuleGround())
        .padding(.horizontal, 16)
        .padding(.top, 6).padding(.bottom, 8)
        .onAppear { text = tab.url?.absoluteString ?? "" }
        .onChange(of: tab.url) { _, url in if !focused { text = url?.absoluteString ?? "" } }
        .onChange(of: focused) { _, isFocused in if !isFocused { text = tab.url?.absoluteString ?? text } }
    }
}

/// The capsule's own glass on iOS 26, the bar's material before it.
private struct CapsuleGround: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.clipShape(Capsule()).glassEffect(.regular, in: .capsule)
        } else {
            content.clipShape(Capsule()).background(.bar, in: Capsule())
        }
    }
}

/// A new tab: what to do, and where a search goes (k-newtab).
struct NewTabPage: View {
    let engine: SearchEngine

    var body: some View {
        ContentUnavailableView {
            Label(L("Новая вкладка"), systemImage: "globe")
        } description: {
            Text(L("Введите адрес или запрос.") + "\n" + L("Поисковик: %@", engine.title))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("startPage")
    }
}

/// The session's proxy did not answer (p3-dead): nothing opens directly — that is the point — and
/// the way on: again, or the session's settings.
struct ProxyNotAnswering: View {
    let proxyName: String
    let retry: () -> Void
    let settings: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(L("Прокси не отвечает"), systemImage: "wifi.slash")
        } description: {
            Text(L("Эта сессия открывает сайты только через прокси «%@», а он не ответил. Напрямую страница не откроется — так сайты не увидят настоящий адрес iPhone.", proxyName))
        } actions: {
            Button(L("Повторить"), action: retry)
                .buttonStyle(.borderedProminent).tint(Theme.accentFill).controlSize(.large)
                .accessibilityIdentifier("retryPage")
            Button(L("Настройки сессии"), action: settings)
                .buttonStyle(.bordered).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityIdentifier("proxyNotAnswering")
    }
}

#if DEBUG
/// The tests' view of the session's relay, and their drills on it (DEBUG, LUMEN_TEST_HOOKS).
private struct RelayDrills: View {
    @ObservedObject var runtime: SessionRuntime

    var body: some View {
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
        .padding(.bottom, 4)
    }
}
#endif

/// Hosts the selected tab's WKWebView; switching tabs swaps the view, the pages stay loaded. The page
/// runs under both bars; WebKit keeps its content clear of them.
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ container: UIView, context: Context) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        container.addSubview(webView)
    }
}
