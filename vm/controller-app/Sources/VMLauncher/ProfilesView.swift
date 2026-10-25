import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VMControllerCore

/// The saved-profiles section in the main window: a list with launch / edit /
/// delete, and "+" to add. Launching a row runs that profile (its own VM,
/// fail-closed proxy, cookies, last URL).
struct ProfilesSection: View {
    @ObservedObject var model: LauncherModel
    @State private var editing: EditorTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Профили").font(.headline)
                Spacer()
                Button {
                    editing = .new
                } label: {
                    Label("Создать", systemImage: "plus")
                }
                .help("Создать профиль")
            }

            if model.profiles.isEmpty {
                Text("Пока нет профилей. «Создать» — отдельная VM со своим прокси и cookies.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.profiles) { profile in
                        ProfileRow(profile: profile, model: model) { editing = .existing(profile) }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .sheet(item: $editing) { target in
            ProfileEditor(model: model, target: target)
                .frame(width: 420)
        }
    }
}

struct ProfileRow: View {
    let profile: Profile
    @ObservedObject var model: LauncherModel
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.on.square.dashed").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Запустить") { model.start(profile: profile) }
                .disabled(!model.canStart)
            Button { onEdit() } label: { Image(systemName: "pencil") }
                .help("Изменить")
            Button(role: .destructive) { model.deleteProfile(profile.id) } label: {
                Image(systemName: "trash")
            }
            .help("Удалить")
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [profile.proxy ?? "без прокси (изоляция)"]
        if profile.cookieCount > 0 { parts.append("cookies: \(profile.cookieCount)") }
        if profile.clipboardShared { parts.append("буфер общий") }
        return parts.joined(separator: " · ")
    }
}

enum EditorTarget: Identifiable {
    case new
    case existing(Profile)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let profile): profile.id
        }
    }
}

/// Create or edit a profile: name, proxy, shared-clipboard toggle (off by
/// default), and — for a saved profile — cookie import.
struct ProfileEditor: View {
    @ObservedObject var model: LauncherModel
    let target: EditorTarget
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var proxy = ""
    @State private var clipboardShared = false
    @State private var cookieCount = 0

    private var existing: Profile? {
        if case .existing(let profile) = target { return profile }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Новый профиль" : "Профиль").font(.title3).bold()

            Form {
                TextField("Имя", text: $name)
                TextField("Прокси (socks5:// или http://, пусто = без выхода)", text: $proxy)
                Toggle("Общий буфер обмена с хостом", isOn: $clipboardShared)
                Text("Выключено по умолчанию, чтобы случайно не вставить данные с хоста в VM.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let existing {
                Divider()
                HStack {
                    Text("Cookies: \(cookieCount)").foregroundStyle(.secondary)
                    Spacer()
                    if cookieCount > 0 {
                        Button("Очистить") {
                            try? model.profileStore.clearCookies(for: existing.id)
                            model.reloadProfiles(); cookieCount = 0
                        }
                    }
                    Button("Импорт cookies…") { importCookies(into: existing) }
                }
                Text("Netscape cookies.txt или JSON-экспорт расширения.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Создать" : "Сохранить") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            if let existing {
                name = existing.name
                proxy = existing.proxy ?? ""
                clipboardShared = existing.clipboardShared
                cookieCount = existing.cookieCount
            }
        }
    }

    private func save() {
        if let existing {
            model.updateProfile(existing.id, name: name, proxy: proxy, clipboardShared: clipboardShared)
        } else {
            _ = model.createProfile(name: name, proxy: proxy, clipboardShared: clipboardShared)
        }
        dismiss()
    }

    private func importCookies(into profile: Profile) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json, .plainText, .text]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importCookies(for: profile.id, from: url)
        cookieCount = model.profiles.first { $0.id == profile.id }?.cookieCount ?? cookieCount
    }
}
