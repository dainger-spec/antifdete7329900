import AppKit
import SwiftUI
import VMControllerCore

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

/// Create or edit a profile: name, how it reaches the internet, the region
/// sites see, and the shared clipboard (off by default).
struct ProfileEditor: View {
    @ObservedObject var model: LauncherModel
    let target: EditorTarget
    var onSaved: (Profile?) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ProfileDraft()
    @State private var problem: String?

    private var existing: Profile? {
        if case .existing(let profile) = target { return profile }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ProfileAvatar(name: draft.name.isEmpty ? "?" : draft.name, id: existing?.id ?? "new", size: 36)
                Text(existing == nil ? "Новый профиль" : "Профиль «\(existing!.name)»").font(.title2.bold())
            }
            .padding(20)

            Form {
                Section {
                    TextField("Имя", text: $draft.name, prompt: Text("Например, Работа"))
                }

                Section {
                    Picker("Интернет", selection: $draft.network) {
                        Text("Через прокси").tag(NetworkMode.proxy)
                        Text("Напрямую").tag(NetworkMode.direct)
                        Text("Без интернета").tag(NetworkMode.offline)
                    }
                    .pickerStyle(.segmented)
                    if draft.network == .proxy {
                        TextField("Прокси", text: $draft.proxy, prompt: Text("socks5://user:pass@203.0.113.5:1080"))
                    }
                } header: {
                    Text("Сеть")
                } footer: {
                    Text(networkFooter).font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Часовой пояс", selection: $draft.timeZone) {
                        Text("Не менять").tag(String?.none)
                        Divider()
                        ForEach(TimeZoneOption.choices(including: draft.timeZone), id: \.self) { zone in
                            Text(TimeZoneOption.label(zone)).tag(Optional(zone))
                        }
                    }
                    Picker("Язык", selection: $draft.language) {
                        Text("Не менять").tag(String?.none)
                        Divider()
                        ForEach(LanguageOption.choices(including: draft.language), id: \.self) { code in
                            Text(LanguageOption.label(code)).tag(Optional(code))
                        }
                    }
                } header: {
                    Text("Регион")
                } footer: {
                    Text("Сайты видят часовой пояс и язык. Для профиля с прокси выберите те, что у страны прокси.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Общий буфер обмена с этим Mac", isOn: $draft.clipboardShared)
                } footer: {
                    Text("Выключено по умолчанию, чтобы случайно не вставить в профиль данные с Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Создать" : "Сохранить") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 520)
        .onAppear {
            if let existing { draft = ProfileDraft(profile: existing) }
        }
        .onChange(of: draft) { _, _ in problem = nil }
    }

    private var networkFooter: String {
        switch draft.network {
        case .proxy:
            "Весь трафик профиля идёт только через этот прокси. Если прокси недоступен, интернета нет — "
                + "настоящий IP сайтам не виден. Прокси указывается IP-адресом; http:// или socks5://."
        case .direct:
            "Профиль выходит в интернет через этот Mac: сайты видят ваш IP."
        case .offline:
            "Профиль не выходит в сеть вообще."
        }
    }

    private func save() {
        if let existing {
            problem = model.updateProfile(existing.id, draft)
            if problem == nil {
                onSaved(nil)
                dismiss()
            }
        } else {
            let (created, error) = model.createProfile(draft)
            problem = error
            if let created {
                onSaved(created)
                dismiss()
            }
        }
    }
}

/// Time zones offered in the editor: common ones, plus whatever the profile
/// already has.
enum TimeZoneOption {
    static let common = [
        "Europe/London", "Europe/Dublin", "Europe/Lisbon", "Europe/Paris", "Europe/Berlin", "Europe/Amsterdam",
        "Europe/Madrid", "Europe/Rome", "Europe/Warsaw", "Europe/Prague", "Europe/Stockholm", "Europe/Helsinki",
        "Europe/Kyiv", "Europe/Istanbul", "Europe/Moscow", "Asia/Dubai", "Asia/Tbilisi", "Asia/Almaty",
        "Asia/Kolkata", "Asia/Bangkok", "Asia/Singapore", "Asia/Hong_Kong", "Asia/Shanghai", "Asia/Tokyo",
        "Asia/Seoul", "Australia/Sydney", "America/New_York", "America/Chicago", "America/Denver",
        "America/Los_Angeles", "America/Toronto", "America/Mexico_City", "America/Sao_Paulo",
        "America/Buenos_Aires", "Africa/Cairo", "Africa/Johannesburg",
    ]

    static func choices(including current: String?) -> [String] {
        guard let current, !common.contains(current) else { return common }
        return [current] + common
    }

    static func label(_ identifier: String) -> String {
        let city = identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
        guard let zone = TimeZone(identifier: identifier) else { return city }
        let seconds = zone.secondsFromGMT()
        let sign = seconds < 0 ? "−" : "+"
        let hours = abs(seconds) / 3600
        let minutes = abs(seconds) % 3600 / 60
        return minutes == 0 ? "\(city) (UTC\(sign)\(hours))" : "\(city) (UTC\(sign)\(hours):\(String(format: "%02d", minutes)))"
    }
}

/// Languages offered in the editor (BCP 47, as macOS wants them).
enum LanguageOption {
    static let common = [
        "en-US", "en-GB", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "pt-PT", "nl-NL", "pl-PL",
        "cs-CZ", "sv-SE", "fi-FI", "tr-TR", "uk-UA", "ru-RU", "ja-JP", "ko-KR", "zh-CN", "ar-AE",
    ]

    static func choices(including current: String?) -> [String] {
        guard let current, !common.contains(current) else { return common }
        return [current] + common
    }

    static func label(_ code: String) -> String {
        let name = Locale(identifier: "ru_RU").localizedString(forIdentifier: code) ?? code
        return "\(name.prefix(1).uppercased())\(name.dropFirst())"
    }
}
