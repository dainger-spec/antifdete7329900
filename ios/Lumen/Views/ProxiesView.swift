import LumenCore
import SwiftUI

/// The proxy list, as on the Mac: a proxy entered as one line, SOCKS5 or HTTP; each checked when
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

/// A proxy, entered as one line (the owner's design, 10 November 2026) — in any form providers hand
/// them out, read by the Mac's rules (`ProxyLine`). The type is the line's scheme; a line without one
/// leaves it to the person. The name is the proxy's own field, or what follows " #" in the line.
/// A saved proxy's line is shown without its password, which is never shown again: a line that
/// holds no password keeps the one the proxy has.
///
/// The line is a plain field, not a login and a password: iOS has nothing here to take for a
/// sign-in and offer to keep among the person's own passwords (CI runs 12 and 13 did, with the two
/// separate fields). The password is kept in this app's own Keychain item only (ProxyPasswords).
struct ProxyEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let entry: ProxyEntry?
    @State private var name = ""
    @State private var kind = ProxyKind.socks5
    @State private var line = ""

    private var read: Result<ProxyLine, ProxyLine.Problem> { ProxyLine.read(line) }

    private var parsed: ProxyLine? {
        if case let .success(proxy) = read { return proxy }
        return nil
    }

    /// What is wrong with the line, once something is written in it.
    private var problem: String? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, case let .failure(problem) = read else { return nil }
        return problem.text
    }

    private func close() {
        line = ""   // nothing of the line stays on a screen that is leaving
        DispatchQueue.main.async { dismiss() }
    }

    private func save(_ proxy: ProxyLine) {
        var saved = entry ?? ProxyEntry(kind: proxy.kind ?? kind, host: proxy.host, port: proxy.port)
        let ownName = name.trimmingCharacters(in: .whitespaces)
        saved.name = ownName.isEmpty ? proxy.label : ownName
        saved.kind = proxy.kind ?? kind
        saved.host = proxy.host
        saved.port = proxy.port
        // A line without a password, for the same login as before: the proxy keeps the one it has.
        var password = proxy.password ?? ""
        if let entry, password.isEmpty, proxy.username == entry.username {
            password = model.password(for: entry.id) ?? ""
        }
        saved.username = proxy.username
        model.saveProxy(saved, password: password)
        close()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("socks5://user:pass@host:port", text: $line, axis: .vertical)
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("proxyLine")
                    PasteButton(payloadType: String.self) { strings in
                        if let pasted = strings.first { line = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .accessibilityIdentifier("pasteProxy")
                } header: {
                    Text(L("Прокси одной строкой"))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let problem {
                            Text(problem).foregroundStyle(Theme.bad).accessibilityIdentifier("proxyLineProblem")
                        }
                        Text(L("Подойдёт любой привычный вид: со схемой или без, логин и пароль до адреса или после него."))
                        if entry != nil {
                            Text(L("Пароль не показан. Строка без пароля оставит прежний."))
                        }
                    }
                }
                .glassRow()
                // The type, when the line does not say it.
                if let parsed, parsed.kind == nil {
                    Section {
                        Picker(L("Тип"), selection: $kind) {
                            Text("SOCKS5").tag(ProxyKind.socks5)
                            Text("HTTP").tag(ProxyKind.http)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("proxyKind")
                    }
                    .glassRow()
                }
                Section {
                    TextField(L("Название (необязательно)"), text: $name).accessibilityIdentifier("proxyName")
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
                        if let parsed { save(parsed) }
                    }
                    .disabled(parsed == nil)
                    .accessibilityIdentifier("saveProxy")
                }
            }
            .onAppear {
                guard let entry else { return }
                name = entry.name
                kind = entry.kind
                line = ProxyLine.write(kind: entry.kind, host: entry.host, port: entry.port, username: entry.username)
            }
        }
    }
}
