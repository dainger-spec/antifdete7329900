import LumenCore
import SwiftUI

/// The proxy list, as on the Mac: address, port, user, password, SOCKS5 or HTTP; each checked when
/// added: alive or not, the address it exits from, its country, and whether it relays UDP.
struct ProxiesView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: ProxyEntry?
    @State private var adding = false

    var body: some View {
        List {
            if model.proxies.isEmpty {
                ContentUnavailableView("Прокси пока нет", systemImage: "network",
                                       description: Text("Добавьте прокси и назначьте его сессии в её настройках."))
            }
            ForEach(model.proxies) { entry in
                ProxyRow(entry: entry, checking: model.checking.contains(entry.id))
                    .contentShape(Rectangle())
                    .onTapGesture { editing = entry }
                    .accessibilityIdentifier("proxy-\(entry.displayName)")
                    .swipeActions {
                        Button("Удалить", systemImage: "trash", role: .destructive) { model.deleteProxy(entry.id) }
                        Button("Проверить", systemImage: "arrow.clockwise") { model.check(entry.id) }.tint(.blue)
                    }
            }
        }
        .navigationTitle("Прокси")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("newProxy").accessibilityLabel("Новый прокси")
            }
        }
        .sheet(isPresented: $adding) { ProxyEditor(entry: nil) }
        .sheet(item: $editing) { ProxyEditor(entry: $0) }
    }
}

struct ProxyRow: View {
    let entry: ProxyEntry
    let checking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.displayName).font(.headline)
                Spacer()
                Text(entry.kind == .socks5 ? "SOCKS5" : "HTTP").font(.caption.bold()).foregroundStyle(.secondary)
            }
            Text("\(entry.host):\(entry.port)" + (entry.username.isEmpty ? "" : " · \(entry.username)"))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(status).font(.subheadline)
            Text(udp).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        if checking { return "Проверяется…" }
        guard let check = entry.check else { return "Не проверен" }
        guard check.alive else { return "Недоступен: \(check.error ?? "нет ответа")" }
        let place = [CountryLocale.flag(check.country), check.country ?? "", check.exitIP ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return "Работает · \(place)"
    }

    private var udp: String {
        if checking { return "UDP: проверяется" }
        switch entry.check?.udp ?? .unchecked {
        case .supported: return "UDP: умеет"
        case .unsupported: return "UDP: не умеет"
        case .unchecked: return "UDP: не проверен"
        }
    }
}

struct ProxyEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let entry: ProxyEntry?
    @State private var name = ""
    @State private var kind = ProxyKind.socks5
    @State private var host = ""
    @State private var port = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Прокси") {
                    TextField("Название (необязательно)", text: $name).accessibilityIdentifier("proxyName")
                    Picker("Тип", selection: $kind) {
                        Text("SOCKS5").tag(ProxyKind.socks5)
                        Text("HTTP").tag(ProxyKind.http)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("proxyKind")
                    TextField("Адрес", text: $host).accessibilityIdentifier("proxyHost")
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Порт", text: $port).accessibilityIdentifier("proxyPort").keyboardType(.numberPad)
                }
                Section("Вход") {
                    TextField("Логин", text: $username).accessibilityIdentifier("proxyUser")
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Пароль", text: $password).accessibilityIdentifier("proxyPassword")
                }
                if let entry {
                    Section {
                        Button("Удалить прокси", role: .destructive) { model.deleteProxy(entry.id); dismiss() }
                    }
                }
            }
            .navigationTitle(entry == nil ? "Новый прокси" : "Прокси")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        var saved = entry ?? ProxyEntry(kind: kind, host: host, port: 0)
                        saved.name = name.trimmingCharacters(in: .whitespaces)
                        saved.kind = kind
                        saved.host = host.trimmingCharacters(in: .whitespaces)
                        saved.port = Int(port) ?? 0
                        saved.username = username
                        model.saveProxy(saved, password: password)
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || !(1...65535).contains(Int(port) ?? 0))
                    .accessibilityIdentifier("saveProxy")
                }
            }
            .onAppear {
                guard let entry else { return }
                name = entry.name
                kind = entry.kind
                host = entry.host
                port = String(entry.port)
                username = entry.username
                password = model.password(for: entry.id) ?? ""
            }
        }
    }
}
