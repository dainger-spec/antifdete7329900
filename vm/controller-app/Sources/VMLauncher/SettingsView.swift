import AppKit
import SwiftUI
import VMControllerCore

/// ⌘, — the technical side, kept out of the main window.
struct SettingsView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("Основные", systemImage: "gearshape") }
            SystemSettings(model: model)
                .tabItem { Label("Система", systemImage: "internaldrive") }
            LogView(model: model)
                .padding(20)
                .tabItem { Label("Журнал", systemImage: "doc.text.magnifyingglass") }
        }
        .frame(width: 620, height: 460)
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        Form {
            Section {
                Toggle("Показывать браузер в окне приложения", isOn: $model.useEmbeddedWindow)
                    .disabled(model.hasActiveWork)
                Text("Рекомендуется. Выключите, только если встроенное окно не работает: тогда система профиля "
                    + "откроется в окне Tart.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Окно браузера")
            }
            Section {
                Text("Внутри профиля скрыты Dock, строка меню и рабочий стол macOS, а окно Safari всегда занимает "
                    + "весь экран. При первом открытии профиля macOS один раз спросит, можно ли управлять Safari — "
                    + "нажмите «Разрешить».")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Только Safari")
            }
        }
        .formStyle(.grouped)
    }
}

struct SystemSettings: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        Form {
            Section("Базовая система macOS") {
                LabeledContent("Образ") {
                    Text(model.currentBaseImage).textSelection(.enabled).foregroundStyle(.secondary)
                }
                HStack {
                    updateBadge
                    Spacer()
                    if model.baseUpdateInProgress || model.baseUpdateChecking {
                        ProgressView().controlSize(.small)
                        Text(model.baseUpdateDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Проверить обновление") { model.checkBaseImageUpdate() }
                        .disabled(model.baseUpdateInProgress || model.baseUpdateChecking)
                    Button("Обновить") { model.updateBaseImage() }
                        .disabled(model.isBusy || model.baseUpdateInProgress)
                }
                Text(BaseImagePolicy.migrationNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.profilesOnOtherBase.isEmpty {
                    Text("На другом образе: \(model.profilesOnOtherBase.map(\.name).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Ресурсы") {
                if let report = model.resource {
                    LabeledContent("Запущено профилей", value: "\(report.runningVMs)")
                    LabeledContent("Профили на диске", value: Self.bytes(report.profilesDiskBytes))
                    if let free = report.freeRAMBytes {
                        LabeledContent("Свободно памяти") {
                            Text(Self.bytes(free)).foregroundStyle(report.lowRAM ? Color.orange : Color.secondary)
                        }
                    }
                    if report.lowRAM {
                        Text("Мало памяти (меньше 2 ГБ): закройте лишние программы или профили.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Обновить") { Task { await model.refreshResources() } }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshResources() }
    }

    @ViewBuilder private var updateBadge: some View {
        switch model.baseUpdateState {
        case .updateAvailable:
            Label("Доступно обновление", systemImage: "arrow.down.circle").foregroundStyle(.orange)
        case .upToDate:
            Label("Актуально", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .unknown:
            Text("Проверка не выполнялась").foregroundStyle(.secondary)
        }
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

struct LogView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.log) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(color(for: line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
                .onChange(of: model.log.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            HStack {
                Text("\(model.log.count) строк").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Открыть файл журнала") { NSWorkspace.shared.open(model.logFileURL) }
                Button("Скопировать") { model.copyLog() }
                    .disabled(model.log.isEmpty)
            }
            .controlSize(.small)
        }
    }

    private func color(for kind: LogLine.Kind) -> Color {
        switch kind {
        case .info: .primary
        case .output: .secondary
        case .error: .red
        }
    }
}
