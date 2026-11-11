import LumenCore
import SwiftUI

/// The sync's screen (step 2 of ios/SYNC_PLAN.md): this iPhone connected to the Mac's vault. The
/// account's vaults come from the server (`GET /v1/device/sync/vaults`); the master password is asked
/// once, turned into a key here, and only the key is kept — in the Keychain, behind Face ID or the
/// passcode (`SyncKeychain`). Without a trial or a paid plan the server says so, and this screen says
/// it as a state, not as an error (decision 8). Profiles come over in the next step.
struct SyncView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var stage = Stage.loading
    @State private var password = ""
    @State private var working = false
    @State private var message: String?

    enum Stage: Equatable {
        case loading
        case notInPlan
        case noVault
        case askPassword(UUID)
        case connected(UUID)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch stage {
                case .loading:
                    Section { ProgressView().accessibilityIdentifier("syncLoading") }.glassRow()
                case .notInPlan:
                    Section {
                        Text(L("Синхронизация с Mac — в пробном и платном тарифе. Профили на этом iPhone остаются как есть."))
                            .accessibilityIdentifier("syncNotInPlan")
                    }
                    .glassRow()
                case .noVault:
                    Section {
                        Text(L("Синхронизация ещё не включена. Включите её в Lumen для Mac, затем вернитесь сюда."))
                            .accessibilityIdentifier("syncNoVault")
                    }
                    .glassRow()
                case let .askPassword(vaultID):
                    Section {
                        SecureField(L("Мастер-пароль"), text: $password)
                            .textContentType(.oneTimeCode)
                            .accessibilityIdentifier("syncPassword")
                    } footer: {
                        Text(L("Мастер-пароль хранилища Lumen для Mac. Он нужен один раз: на этом iPhone остаётся только ключ, под Face ID или кодом телефона."))
                    }
                    .glassRow()
                    if let message {
                        Section {
                            Label { Text(message).accessibilityIdentifier("syncMessage") } icon: { Image(systemName: "exclamationmark.circle") }
                                .font(.system(size: 15)).foregroundStyle(Theme.bad)
                        }
                        .listRowBackground(Theme.bad.opacity(0.1))
                    }
                    Section {
                        Button(working ? L("Проверяем…") : L("Подключить")) { connect(vaultID) }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(working || password.isEmpty)
                            .accessibilityIdentifier("syncConnect")
                            .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    }
                case .connected:
                    Section {
                        Label(L("Хранилище подключено"), systemImage: "checkmark.circle").foregroundStyle(Theme.ok)
                            .accessibilityIdentifier("syncConnected")
                    } footer: {
                        Text(L("Профили с Mac появятся здесь в следующей версии синхронизации."))
                    }
                    .glassRow()
                    Section {
                        Button(L("Забыть хранилище"), role: .destructive) {
                            SyncKeychain.erase()
                            Task { await load() }
                        }
                        .accessibilityIdentifier("syncForget")
                    }
                    .glassRow()
                case let .failed(text):
                    Section { Text(text).foregroundStyle(Theme.bad).accessibilityIdentifier("syncFailed") }.glassRow()
                }
            }
            .eclipseSheet()
            .navigationTitle(L("Синхронизация"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() }.accessibilityIdentifier("syncDone") }
            }
            .task { await load() }
        }
    }

    /// Where this iPhone stands: a vault kept, or the account's vaults from the server.
    private func load() async {
        if let kept = SyncKeychain.vaultID {
            stage = .connected(kept)
            return
        }
        guard let record = AccountStore.record() else { return stage = .failed(L("Войдите в аккаунт Lumen.")) }
        guard let answer = await AccountClient.send("GET", "v1/device/sync/vaults", body: nil, token: record.deviceToken) else {
            return stage = .failed(AccountText.unreachable)
        }
        if answer.status == 403, AccountWire.refusal(answer.data)?.code == "sync_not_in_plan" { return stage = .notInPlan }
        guard answer.status == 200, let vaults = SyncSetup.vaults(answer.data) else {
            return stage = .failed(AccountWire.refusal(answer.data).map(AccountText.refusal) ?? AccountText.unreachable)
        }
        // The vault changed last: the Mac in use now (a person with several Macs has one vault each).
        stage = vaults.first.map { .askPassword($0.vaultID) } ?? .noVault
    }

    private func connect(_ vaultID: UUID) {
        guard let record = AccountStore.record() else { return }
        working = true
        message = nil
        let typed = password
        Task {
            defer { working = false }
            let path = "v1/vaults/\(vaultID.uuidString.lowercased())/objects/vault-header"
            guard let answer = await AccountClient.send("GET", path, body: nil, token: record.deviceToken), answer.status == 200 else {
                return message = AccountText.unreachable
            }
            let outcome = await Task.detached { SyncSetup.unlockKey(password: typed, header: answer.data, vaultID: vaultID) }.value
            switch outcome {
            case let .key(key):
                password = ""
                guard SyncKeychain.keep(.init(vaultID: vaultID, unlockKey: key)) else {
                    return message = L("Задайте код-пароль iPhone в Настройках: без него ключ хранилища не сохранить.")
                }
                stage = .connected(vaultID)
            case .wrongPassword:
                message = L("Неверный мастер-пароль.")
            case .newerApp:
                message = AccountText.outdated
            case .notThisVault:
                message = AccountText.unreachable
            }
        }
    }
}
