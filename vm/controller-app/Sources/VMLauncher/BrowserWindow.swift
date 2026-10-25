import AppKit
import SwiftUI
import VMControllerCore

enum BrowserWindow {
    static let id = "browser"
}

/// The browser window: our own splash (logo + progress) while the profile's
/// macOS boots and gets set up — so neither the Apple boot screen nor the
/// guest desktop is ever seen — then the VM's screen, which by then shows just
/// Safari filling the window (kiosk settings + the agent's fill-screen).
/// Closing the window stops the profile.
struct BrowserWindowView: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            Color.black
            // Mounted as soon as the VM exists, under the splash: the guest
            // display then boots at the window's size.
            if let embedded = model.embeddedVM {
                EmbeddedScreen(vm: embedded)
                    .opacity(model.browserReady ? 1 : 0)
            }
            if !model.browserReady || model.display != .embedded {
                LaunchSplash(model: model) { dismissWindow(id: BrowserWindow.id) }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: model.browserReady)
        .frame(minWidth: 760, minHeight: 500)
        .navigationTitle(model.browserTitle)
        .toolbar {
            ToolbarItem(placement: .status) {
                if let profile = model.activeProfile {
                    Label(NetworkSummary(profile: profile).short, systemImage: NetworkSummary(profile: profile).symbol)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if model.phase == .ready || model.phase == .running {
                    Button {
                        model.cancel()
                    } label: {
                        Label(model.phase == .ready ? "Закрыть" : "Отмена", systemImage: "stop.circle")
                    }
                    .help("Остановить профиль")
                }
            }
        }
        .onDisappear { model.browserWindowClosed() }
    }
}

/// Observes the EmbeddedVM itself: its VZVirtualMachine appears only once
/// start() has built the configuration.
struct EmbeddedScreen: View {
    @ObservedObject var vm: EmbeddedVM

    var body: some View {
        if let machine = vm.virtualMachine {
            VMDisplay(virtualMachine: machine)
        }
    }
}

/// Shown in the browser window until Safari is ready (and instead of it when
/// the VM runs in Tart's window, or the launch ended).
struct LaunchSplash: View {
    @ObservedObject var model: LauncherModel
    var close: () -> Void
    @State private var card = 0

    private let cards = CarouselDeck.cards
    private let tick = Timer.publish(every: CarouselDeck.interval, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            BrandLogo(size: 104)
            Text(model.activeProfile?.name ?? Brand.name)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            content
            Spacer()
            if model.downloadFraction != nil {
                carousel
                Spacer()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(tick) { _ in
            guard model.downloadFraction != nil else { return }
            withAnimation(.easeInOut(duration: 0.5)) { card = CarouselDeck.next(after: card) }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .running, .stopping, .needsTart:
            VStack(spacing: 12) {
                Text(model.phase == .needsTart ? "Нужен компонент виртуализации — см. главное окно" : model.currentStepTitle)
                    .font(.title3.weight(.medium))
                ProgressView(value: model.downloadFraction ?? model.progress.fraction)
                    .frame(width: 320)
                    .animation(.easeOut(duration: 0.3), value: model.progress.fraction)
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 420)
            }
        case .ready:
            // Only when the VM runs in Tart's window (fallback).
            VStack(spacing: 12) {
                Text("Браузер открыт в отдельном окне").font(.title3.weight(.medium))
                Text("Встроенное окно недоступно для этой системы — подробности в журнале (Настройки).")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Закрыть браузер", role: .destructive) { model.cancel() }
            }
        case .failed:
            VStack(spacing: 12) {
                Label("Не удалось открыть браузер", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.red)
                Text(model.errorMessage ?? "Подробности — в журнале.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 480)
                Button("Закрыть", action: close)
            }
        case .idle, .finished, .cancelled:
            VStack(spacing: 12) {
                Text(model.phase == .cancelled ? "Отменено" : "Браузер закрыт").font(.title3.weight(.medium))
                Button("Закрыть окно", action: close)
            }
        }
    }

    private var carousel: some View {
        VStack(spacing: 10) {
            ForEach(cards) { item in
                if item.id == card {
                    VStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.tint)
                        Text(item.title).font(.headline)
                        Text(item.subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .transition(.opacity)
                }
            }
            Text("Первая загрузка macOS долгая; дальше профили открываются за минуту.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
