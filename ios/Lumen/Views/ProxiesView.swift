import LumenCore
import SwiftUI

/// The proxy list (p8-list), as on the Mac: a proxy entered as one line, SOCKS5 or HTTP; each checked
/// when saved and on demand: alive or not, the address and country it exits from, whether it relays UDP.
struct ProxiesView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: ProxyEntry?
    @State private var adding = false

    var body: some View {
        List {
            if !model.proxies.isEmpty {
                Section {
                    ForEach(model.proxies) { entry in
                        Button { editing = entry } label: {
                            ProxyRow(entry: entry, checking: model.checking.contains(entry.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("proxy-\(entry.displayName)")
                        .swipeActions {
                            Button(L("Удалить"), systemImage: "trash", role: .destructive) { model.deleteProxy(entry.id) }
                            Button(L("Проверить"), systemImage: "arrow.clockwise") { model.check(entry.id) }.tint(Color(.systemGray))
                        }
                        .contextMenu {
                            Button(L("Проверить"), systemImage: "arrow.clockwise") { model.check(entry.id) }
                            Button(L("Изменить"), systemImage: "pencil") { editing = entry }
                            Divider()
                            Button(L("Удалить"), systemImage: "trash", role: .destructive) { model.deleteProxy(entry.id) }
                        }
                    }
                } footer: {
                    Text(L("Прокси проверяется при сохранении и по нажатию."))
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if model.proxies.isEmpty {
                ContentUnavailableView {
                    Label(L("Прокси пока нет"), systemImage: "globe")
                } description: {
                    Text(L("Добавьте HTTP или SOCKS5 — строкой, как его выдал провайдер."))
                } actions: {
                    Button(L("Добавить прокси")) { adding = true }
                        .buttonStyle(.borderedProminent).tint(Theme.accentFill)
                        .accessibilityIdentifier("newProxyEmpty")
                }
            }
        }
        .navigationTitle(L("Прокси"))
        .navigationBarTitleDisplayMode(.large)
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

/// A proxy, entered as one line (p9-new) — in any form providers hand them out, read by the Mac's rules
/// (`ProxyLine`). The type is the line's scheme; a line without one leaves it to the person. The name
/// is the proxy's own field, or what follows " #" in the line. A saved proxy's line is shown without
/// its password, which is never shown again: a line that holds no password keeps the one it has.
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
    @State private var confirmDelete = false

    private var read: Result<ProxyLine, ProxyLine.Problem> { ProxyLine.read(line) }

    private var parsed: ProxyLine? {
        if case let .success(proxy) = read { return proxy }
        return nil
    }

    /// What is wrong with the line, once something is written in it (p9-error: one red line under it).
    private var problem: String? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, case let .failure(problem) = read else { return nil }
        return problem.text
    }

    /// The type the line says itself, if it has a scheme: the choice then follows it.
    private var lineKind: ProxyKind? { parsed?.kind }

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
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("proxyLine")
                        .accessibilityLabel(L("Прокси одной строкой"))
                } header: {
                    Text(L("Прокси одной строкой"))
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(Color(.systemRed)).accessibilityIdentifier("proxyLineProblem")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Подойдёт любой привычный вид: адрес:порт, логин:пароль@адрес:порт или ссылка со схемой."))
                            if entry != nil { Text(L("Пароль не показан. Строка без пароля оставит прежний.")) }
                        }
                    }
                }
                Section(L("Тип")) {
                    Picker(L("Тип"), selection: Binding(get: { lineKind ?? kind }, set: { kind = $0 })) {
                        Text("HTTP").tag(ProxyKind.http)
                        Text("SOCKS5").tag(ProxyKind.socks5)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(lineKind != nil)
                    .accessibilityIdentifier("proxyKind")
                }
                Section {
                    TextField(L("Название"), text: $name).accessibilityIdentifier("proxyName")
                } header: {
                    Text(L("Название"))
                } footer: {
                    Text(L("Прокси проверим при сохранении."))
                }
                if let entry {
                    Section {
                        Button(L("Удалить прокси"), role: .destructive) { confirmDelete = true }
                            .accessibilityIdentifier("deleteProxy")
                    }
                    .confirmationDialog(L("Удалить прокси «%@»?", entry.displayName), isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button(L("Удалить прокси"), role: .destructive) { model.deleteProxy(entry.id); close() }
                        Button(L("Отмена"), role: .cancel) {}
                    } message: {
                        Text(L("Сессии с этим прокси останутся запертыми, пока не выберете им другой."))
                    }
                }
            }
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
        .presentationDetents([.large])
    }
}
