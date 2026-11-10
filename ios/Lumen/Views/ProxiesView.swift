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
                ContentUnavailableView(L("Прокси пока нет"), systemImage: "network",
                                       description: Text(L("Добавьте прокси и назначьте его сессии в её настройках.")))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(model.proxies) { entry in
                ProxyRow(entry: entry, checking: model.checking.contains(entry.id))
                    .contentShape(Rectangle())
                    .onTapGesture { editing = entry }
                    .accessibilityIdentifier("proxy-\(entry.displayName)")
                    .padding(.horizontal, 14).padding(.vertical, 13)
                    .glassPane(radius: 24)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .swipeActions {
                        Button(L("Удалить"), systemImage: "trash", role: .destructive) { model.deleteProxy(entry.id) }
                        Button(L("Проверить"), systemImage: "arrow.clockwise") { model.check(entry.id) }.tint(.gray)
                    }
            }
        }
        .listStyle(.plain)
        .eclipseScreen()
        .navigationTitle(L("Прокси"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("newProxy").accessibilityLabel(L("Новый прокси"))
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
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entry.displayName).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Text(entry.kind == .socks5 ? "SOCKS5" : "HTTP").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Color.white.opacity(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            }
            Text("\(entry.host):\(entry.port)" + (entry.username.isEmpty ? "" : " · \(entry.username)"))
                .font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.secondary)
            // The state in a colour that says it: green works, red does not answer, grey is not known.
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(status).font(.system(size: 14)).foregroundStyle(statusColor)
            }
            Text(udp).font(.system(size: 14)).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        if checking { return Theme.secondary }
        guard let check = entry.check else { return Theme.secondary }
        return check.alive ? Theme.ok : Theme.bad
    }

    private var status: String {
        if checking { return L("Проверяется…") }
        guard let check = entry.check else { return L("Не проверен") }
        guard check.alive else { return L("Недоступен: %@", "\(check.error ?? L("нет ответа"))") }
        let place = [CountryLocale.flag(check.country), check.country ?? "", check.exitIP ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return L("Работает · %@", "\(place)")
    }

    private var udp: String {
        if checking { return L("UDP: проверяется") }
        switch entry.check?.udp ?? .unchecked {
        case .supported: return L("UDP: умеет")
        case .unsupported: return L("UDP: не умеет")
        case .unchecked: return L("UDP: не проверен")
        }
    }
}

struct ProxyEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Closes the form with its login and password emptied first. A proxy's credentials are not the
    /// person's own login: iOS takes a form that leaves the screen with a login and a password in it
    /// for a sign-in and offers to keep them in the person's Passwords (iCloud Keychain) — CI runs 12
    /// and 13: "Save Password?" after every proxy, also with the password marked as a one-time code.
    /// The password is kept in this app's own Keychain item only (ProxyPasswords).
    private func close() {
        if !Faults.isActive(.passwordAutofill) {
            username = ""
            password = ""
        }
        DispatchQueue.main.async { dismiss() }   // after the emptied fields are on screen
    }
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
                Section(L("Прокси")) {
                    TextField(L("Название (необязательно)"), text: $name).accessibilityIdentifier("proxyName")
                    Picker(L("Тип"), selection: $kind) {
                        Text("SOCKS5").tag(ProxyKind.socks5)
                        Text("HTTP").tag(ProxyKind.http)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("proxyKind")
                    TextField(L("Адрес"), text: $host).accessibilityIdentifier("proxyHost")
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField(L("Порт"), text: $port).accessibilityIdentifier("proxyPort").keyboardType(.numberPad)
                }
                .glassRow()
                Section(L("Вход")) {
                    TextField(L("Логин"), text: $username).accessibilityIdentifier("proxyUser")
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(L("Пароль"), text: $password).accessibilityIdentifier("proxyPassword")
                }
                .glassRow()
                if let entry {
                    Section {
                        Button(L("Удалить прокси"), role: .destructive) { model.deleteProxy(entry.id); close() }
                    }
                    .glassRow()
                }
            }
            .eclipseSheet()
            .navigationTitle(entry == nil ? L("Новый прокси") : L("Прокси"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Отмена")) { close() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Сохранить")) {
                        var saved = entry ?? ProxyEntry(kind: kind, host: host, port: 0)
                        saved.name = name.trimmingCharacters(in: .whitespaces)
                        saved.kind = kind
                        saved.host = host.trimmingCharacters(in: .whitespaces)
                        saved.port = Int(port) ?? 0
                        saved.username = username
                        model.saveProxy(saved, password: password)
                        close()
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
