import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VMControllerCore

/// The main window: profiles on the left, the selected one on the right with
/// a single "Открыть браузер" button. Technical things (base image, disk,
/// log, display mode) live in Settings (⌘,).
struct ContentView: View {
    @ObservedObject var model: LauncherModel
    @State private var selection: SidebarItem?
    @State private var editing: EditorTarget?

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, selection: $selection, editing: $editing)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if model.phase == .needsTart, let help = model.tartHelp {
                    TartMissingView(help: help, model: model)
                        .padding([.horizontal, .top], 24)
                }
                switch selection {
                case .profile(let id):
                    if let profile = model.profiles.first(where: { $0.id == id }) {
                        ProfileDetailView(model: model, profile: profile, editing: $editing)
                    } else {
                        WelcomeView(model: model, editing: $editing)
                    }
                case .quickLaunch:
                    QuickLaunchView(model: model)
                case nil:
                    WelcomeView(model: model, editing: $editing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(item: $editing) { target in
            ProfileEditor(model: model, target: target) { created in
                if let created { selection = .profile(created.id) }
            }
        }
        .onAppear {
            if selection == nil, let first = model.profiles.first { selection = .profile(first.id) }
        }
        .task { await model.refreshResources() }
    }
}

enum SidebarItem: Hashable {
    case profile(String)
    case quickLaunch
}

struct Sidebar: View {
    @ObservedObject var model: LauncherModel
    @Binding var selection: SidebarItem?
    @Binding var editing: EditorTarget?

    var body: some View {
        List(selection: $selection) {
            Section("Профили") {
                if model.profiles.isEmpty {
                    Text("Пока пусто")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.profiles) { profile in
                    ProfileSidebarRow(profile: profile, active: model.isActive(profile))
                        .tag(SidebarItem.profile(profile.id))
                }
            }
            Section {
                Label("Быстрый запуск", systemImage: "bolt.fill")
                    .tag(SidebarItem.quickLaunch)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button { editing = .new } label: { Label("Новый профиль", systemImage: "plus") }
                Spacer()
                Button { importProfile() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Импортировать профиль из архива")
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Выберите экспортированный профиль (.tar.gz)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importProfile(from: url)
    }
}

struct ProfileSidebarRow: View {
    let profile: Profile
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            ProfileAvatar(name: profile.name, id: profile.id, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).lineLimit(1)
                Text(NetworkSummary(profile: profile).short)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if active {
                Circle().fill(.green).frame(width: 7, height: 7)
                    .help("Запущен")
            }
        }
        .padding(.vertical, 2)
    }
}

/// How a profile reaches the internet, in words.
struct NetworkSummary {
    let profile: Profile

    var short: String {
        switch profile.network {
        case .proxy: profile.guestProxy == nil ? "Прокси не задан — без интернета" : "Через прокси"
        case .direct: "Напрямую"
        case .offline: "Без интернета"
        }
    }

    var symbol: String {
        switch profile.network {
        case .proxy: "lock.shield"
        case .direct: "globe"
        case .offline: "wifi.slash"
        }
    }

    var detail: String {
        switch profile.network {
        case .proxy:
            guard let proxy = profile.guestProxy, let endpoint = ProxyEndpoint(proxy) else {
                return "Прокси не задан IP-адресом, поэтому интернета нет (защита не пропускает ничего, кроме прокси)."
            }
            return "Только через \(endpoint.host)\(endpoint.port.map { ":\($0)" } ?? ""). Если прокси недоступен, интернета нет — "
                + "ваш настоящий IP сайтам не виден."
        case .direct:
            return "Сайты видят IP этого Mac."
        case .offline:
            return "Ни одного соединения наружу."
        }
    }
}

/// One profile: what it is, and the button that opens it.
struct ProfileDetailView: View {
    @ObservedObject var model: LauncherModel
    let profile: Profile
    @Binding var editing: EditorTarget?
    @Environment(\.openWindow) private var openWindow
    @State private var address = ""
    @State private var confirmDelete = false
    @State private var confirmUnique = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                facts
                if model.isActive(profile) || (model.activeProfile?.id == profile.id && model.phase == .failed) {
                    LaunchStatusCard(model: model)
                } else {
                    openCard
                }
                if let error = model.errorMessage, model.activeProfile?.id == profile.id || !model.hasActiveWork {
                    ErrorBanner(message: error) { model.errorMessage = nil }
                }
                if profile.uniqueIdentity != true {
                    uniquenessNote
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { address = profile.lastURL ?? "" }
        .onChange(of: profile.id) { _, _ in address = profile.lastURL ?? "" }
        .confirmationDialog("Удалить профиль «\(profile.name)»?", isPresented: $confirmDelete) {
            Button("Удалить профиль и его систему", role: .destructive) { model.deleteProfile(profile) }
        } message: {
            Text("Будут удалены виртуальная машина профиля, его cookies, история и все данные внутри. Это не отменить.")
        }
        .confirmationDialog("Сделать профиль уникальным?", isPresented: $confirmUnique) {
            Button("Выдать новый серийный номер и MAC") { model.makeIdentityUnique(profile) }
        } message: {
            Text("Профиль получит собственный серийный номер и MAC-адрес. Пароли, сохранённые в Safari этого профиля, "
                + "могут стать недоступны (они привязаны к «компьютеру»). Cookies и история останутся.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ProfileAvatar(name: profile.name, id: profile.id, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.largeTitle.bold()).lineLimit(1)
                Text("Отдельная macOS с настоящим Safari")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Изменить…") { editing = .existing(profile) }
                Button("Импорт cookies…") { importCookies() }
                if profile.cookieCount > 0 {
                    Button("Забыть импортированные cookies") { model.clearCookies(for: profile.id) }
                }
                Button("Экспорт профиля…") { exportProfile() }
                Divider()
                Button("Удалить…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.isActive(profile))
        }
    }

    private var facts: some View {
        let network = NetworkSummary(profile: profile)
        return VStack(alignment: .leading, spacing: 10) {
            FactRow(symbol: network.symbol, title: network.short, detail: network.detail,
                    warning: profile.network == .proxy && profile.guestProxy == nil)
            FactRow(symbol: "clock", title: regionTitle, detail: regionDetail)
            FactRow(symbol: "lock.rectangle.stack", title: "Своя система и свои данные",
                    detail: profile.cookieCount > 0
                        ? "Cookies: импортировано \(profile.cookieCount)\(profile.needsCookieApply ? " (попадут в Safari при следующем запуске)" : "")."
                        : "Cookies, история и вход на сайты — только внутри этого профиля.")
        }
    }

    private var regionTitle: String {
        switch (profile.timeZone, profile.language) {
        case (nil, nil): "Часовой пояс и язык — как в системе"
        default: [profile.timeZone.map(TimeZoneOption.label), profile.language.map(LanguageOption.label)]
            .compactMap { $0 }.joined(separator: " · ")
        }
    }

    private var regionDetail: String {
        profile.network == .proxy
            ? "Сайты видят часовой пояс и язык — подберите их под страну прокси."
            : "Сайты видят часовой пояс и язык."
    }

    private var openCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Адрес (необязательно): \(profile.lastURL ?? "https://…")", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(open)
                Button(action: open) {
                    Label("Открыть браузер", systemImage: "safari")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
            if let urlError = model.urlError {
                Text(urlError).font(.caption).foregroundStyle(.red)
            } else if !model.canStart && model.hasActiveWork {
                Text("Сейчас открыт другой профиль — сначала закройте его браузер.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var uniquenessNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.2.slash").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Профиль создан до выдачи уникальных серийных номеров").font(.callout.weight(.semibold))
                Text("У него тот же серийный номер, что у других старых профилей. Сайты его не видят, но macOS и службы Apple — видят.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Сделать уникальным…") { confirmUnique = true }
                    .controlSize(.small)
                    .disabled(!model.canStart)
            }
        }
    }

    private func open() {
        let requested = address.trimmingCharacters(in: .whitespaces)
        if model.start(profile: profile, url: requested.isEmpty ? nil : requested) {
            openWindow(id: BrowserWindow.id)
        }
    }

    private func importCookies() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, .plainText, .text]
        panel.message = "Netscape cookies.txt или JSON-экспорт расширения"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importCookies(for: profile.id, from: url)
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Profile.slug(profile.name)).tar.gz"
        panel.message = "Система профиля и его настройки в одном архиве — для переноса на другой Mac"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportProfile(profile, to: url)
    }
}

struct FactRow: View {
    let symbol: String
    let title: String
    let detail: String
    var warning = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(warning ? Color.orange : Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// While the selected profile launches or is open.
struct LaunchStatusCard: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                } else if model.phase == .ready {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if model.phase == .failed {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.phase == .failed ? "Не удалось открыть" : model.currentStepTitle).font(.headline)
                    Text(model.statusText).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if model.display == .embedded || model.isBusy {
                    Button("Показать окно") { openWindow(id: BrowserWindow.id) }
                }
                if model.phase == .ready {
                    Button("Закрыть браузер", role: .destructive) { model.cancel() }
                } else if model.canCancel {
                    Button("Отмена", role: .cancel) { model.cancel() }
                }
            }
            if model.isBusy {
                ProgressView(value: model.progress.fraction)
                    .animation(.easeOut(duration: 0.3), value: model.progress.fraction)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// No profile selected (or none yet).
struct WelcomeView: View {
    @ObservedObject var model: LauncherModel
    @Binding var editing: EditorTarget?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            BrandLogo(size: 96)
            Text(Brand.name).font(.largeTitle.bold())
            Text(Brand.tagline)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                Label("У каждого профиля своя macOS: cookies, история и вход на сайты не пересекаются.",
                      systemImage: "square.stack.3d.up")
                Label("Свой прокси, часовой пояс и язык — или прямой интернет.", systemImage: "globe")
                Label("«Через прокси» не выпускает в сеть ничего, кроме прокси: настоящий IP не утечёт.",
                      systemImage: "lock.shield")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 460, alignment: .leading)
            Button {
                editing = .new
            } label: {
                Label("Создать профиль", systemImage: "plus").padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            if model.isFirstRun {
                Text("В первый раз приложение установит компонент виртуализации и скачает macOS (около 25 ГБ) — это долго. Дальше профили открываются за минуту.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Open a page without a profile (the shared default system, direct internet).
struct QuickLaunchView: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "bolt.circle.fill").font(.system(size: 48)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Быстрый запуск").font(.largeTitle.bold())
                    Text("Общая система без профиля, прямой интернет. Для проверки, не для приватной работы.")
                        .foregroundStyle(.secondary)
                }
            }
            if model.isActive(nil) {
                LaunchStatusCard(model: model)
            } else {
                HStack(spacing: 10) {
                    TextField("https://example.com", text: $model.urlText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(open)
                    Button(action: open) {
                        Label("Открыть браузер", systemImage: "safari").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canStart)
                }
                if let urlError = model.urlError {
                    Text(urlError).font(.caption).foregroundStyle(.red)
                }
            }
            if let error = model.errorMessage, model.activeProfile == nil {
                ErrorBanner(message: error) { model.errorMessage = nil }
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func open() {
        if model.start() { openWindow(id: BrowserWindow.id) }
    }
}

struct TartMissingView: View {
    let help: TartHelp
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Нужен компонент виртуализации", systemImage: "shippingbox")
                .font(.headline)
            Text("Профили работают в виртуальных машинах macOS. Для них нужен бесплатный компонент Tart "
                + "(Cirrus Labs) — его нужно установить один раз.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Установить") { model.downloadTart() }
                    .buttonStyle(.borderedProminent)
                if help.brewPath != nil {
                    Button("Через Homebrew") { model.installTartWithHomebrew() }
                }
                Link("Подробнее", destination: URL(string: "https://tart.run/quick-start/")!)
            }
            Text("«Установить» скачивает последний релиз с GitHub, проверяет подпись и кладёт его в "
                + "~/Library/Application Support/VMLauncher.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.35)))
    }
}

struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Журнал…") { openSettings() }
                    if let onDismiss {
                        Button("Скрыть", action: onDismiss)
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.35)))
    }
}
