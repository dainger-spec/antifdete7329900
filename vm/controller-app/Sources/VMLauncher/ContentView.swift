import AppKit
import SwiftUI
import VMControllerCore

struct ContentView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if model.isFirstRun && model.phase == .idle {
                FirstRunHint()
            }
            urlRow
            ProfilesSection(model: model)
            ResourceBar(model: model)
            BaseImageSection(model: model)
            overall
            StageList(progress: model.progress)
            if model.phase == .needsTart, let help = model.tartHelp {
                TartMissingView(help: help, model: model)
            }
            if let error = model.errorMessage {
                ErrorBanner(message: error)
            }
            LogView(model: model)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 620, alignment: .topLeading)
        .task { await model.refreshResources() }
        // The setup splash (carousel + progress) covers the window during the
        // long first-launch/download wait, then falls away when Safari is up.
        .overlay {
            if model.showsSplash {
                SplashView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.showsSplash)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Safari в виртуальной машине")
                .font(.title2)
                .bold()
            Text("Запускает macOS-VM через Tart, ставит в неё агент и открывает адрес в настоящем Safari.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var urlRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("https://example.com", text: $model.urlText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.canStart)
                Button("Запустить") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
                if model.phase == .ready {
                    Button("Остановить VM", role: .destructive) { model.cancel() }
                } else {
                    Button("Отмена", role: .cancel) { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(!model.canCancel)
                }
            }
            if let urlError = model.urlError {
                Text(urlError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var overall: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    PhaseIcon(phase: model.phase)
                }
                Text(model.statusText)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            ProgressView(value: model.progress.fraction)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.3), value: model.progress.fraction)
        }
    }
}

/// Shown once, on a first run, above the URL field.
struct FirstRunHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Добро пожаловать")
                    .font(.headline)
                Text("Введите адрес и нажмите «Запустить». В первый раз нужно установить Tart и скачать "
                    + "образ macOS — это долго, дальше будет быстрее.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }
}

/// The base image: its ref, a manual "pull latest", and the honest note that
/// existing profiles don't auto-migrate.
struct BaseImageSection: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Базовый образ").font(.headline)
                Spacer()
                if model.baseUpdateInProgress {
                    ProgressView().controlSize(.small)
                    Text(model.baseUpdateDetail).font(.caption).foregroundStyle(.secondary)
                }
                Button("Обновить образ") { model.updateBaseImage() }
                    .disabled(model.isBusy || model.baseUpdateInProgress)
            }
            Text(model.currentBaseImage)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(BaseImagePolicy.migrationNote)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.profilesOnOtherBase.isEmpty {
                Text("На другом образе: \(model.profilesOnOtherBase.map(\.name).joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A thin row of host resource readings, with a low-RAM warning.
struct ResourceBar: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        if let report = model.resource {
            HStack(spacing: 14) {
                Label("\(report.runningVMs) VM запущено", systemImage: "play.fill")
                Label("\(bytes(report.profilesDiskBytes)) на диске", systemImage: "internaldrive")
                if let free = report.freeRAMBytes {
                    Label("\(bytes(free)) RAM свободно", systemImage: "memorychip")
                        .foregroundStyle(report.lowRAM ? Color.orange : Color.secondary)
                }
                Spacer()
                if report.lowRAM {
                    Text("Мало памяти (< 2 ГБ) — закройте часть VM")
                        .foregroundStyle(.orange)
                }
                Button { Task { await model.refreshResources() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Обновить")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

struct PhaseIcon: View {
    let phase: LauncherModel.Phase

    var body: some View {
        switch phase {
        case .idle, .running, .stopping:
            Image(systemName: "play.circle").foregroundStyle(.secondary)
        case .needsTart:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .finished:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

struct StageList: View {
    let progress: LaunchProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(LaunchStage.allCases) { stage in
                StageRow(stage: stage, status: progress[stage])
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct StageRow: View {
    let stage: LaunchStage
    let status: StageStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StageIcon(status: status)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(stage.title)
                    .fontWeight(status.isRunning ? .semibold : .regular)
                    .foregroundStyle(status == .pending ? Color.secondary : Color.primary)
                if let detail = status.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailColor)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let fraction = status.progress {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(maxWidth: 360)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var detailColor: Color {
        switch status {
        case .failed: .red
        case .attention: .orange
        default: .secondary
        }
    }
}

struct StageIcon: View {
    let status: StageStatus

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .attention:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

struct TartMissingView: View {
    let help: TartHelp
    @ObservedObject var model: LauncherModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Tart не установлен", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Tart — менеджер виртуальных машин macOS от Cirrus Labs. Без него VM не запустить. Как установить:")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Скачать Tart") { model.downloadTart() }
                    if help.brewPath != nil {
                        Button("Установить через Homebrew") { model.installTartWithHomebrew() }
                    }
                    Link("Инструкция на tart.run", destination: URL(string: "https://tart.run/quick-start/")!)
                }
                Text("«Скачать Tart» берёт последний релиз с GitHub, проверяет подпись и кладёт его в "
                    + "~/Library/Application Support/VMLauncher. Вручную: brew install cirruslabs/cli/tart, "
                    + "затем «Запустить».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .font(.title3)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Не удалось запустить")
                    .font(.headline)
                Text(message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Подробности — в журнале ниже. Исправьте причину и нажмите «Запустить» ещё раз.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.35)))
    }
}

struct LogView: View {
    @ObservedObject var model: LauncherModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .trailing, spacing: 6) {
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
                    .frame(height: 180)
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: model.log.last?.id) { _, last in
                        if let last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                HStack {
                    Button("Открыть файл лога") { NSWorkspace.shared.open(model.logFileURL) }
                    Button("Скопировать журнал") { model.copyLog() }
                        .disabled(model.log.isEmpty)
                }
                .controlSize(.small)
            }
        } label: {
            Text("Журнал (\(model.log.count))")
        }
        .onChange(of: model.errorMessage) { _, message in
            if message != nil { expanded = true }
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
