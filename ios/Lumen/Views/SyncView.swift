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
    @State private var syncing = false
    @State private var syncResult: String?

    enum Stage: Equatable {
        case loading
        case notInPlan
        case noVault
        case askPassword(UUID)
        case connected(UUID)
        case failed(String)
    }

    /// When the last run ended well (the connected sheet says it).
    @AppStorage("sync.lastRun") private var lastRun: Double = 0
    @State private var showPassword = false
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                switch stage {
                case .loading:
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(L("Проверяем хранилище…")).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("syncLoading")
                    }
                case .notInPlan:
                    Section {
                        FactRow(title: L("Синхронизация"), value: L("нет в тарифе"))
                    } footer: {
                        Text(L("Синхронизация с Mac — в пробном и платном тарифе. Профили на этом iPhone остаются как есть."))
                            .accessibilityIdentifier("syncNotInPlan")
                    }
                case .noVault:
                    Section {
                        FactRow(title: L("Хранилище Mac"), value: L("не включено"))
                    } footer: {
                        Text(L("Синхронизация ещё не включена. Включите её в Lumen для Mac, затем вернитесь сюда."))
                            .accessibilityIdentifier("syncNoVault")
                    }
                case let .askPassword(vaultID):
                    Section {
                        HStack {
                            Group {
                                if showPassword {
                                    TextField(L("Мастер-пароль"), text: $password).accessibilityIdentifier("syncPasswordShown")
                                } else {
                                    SecureField(L("Мастер-пароль"), text: $password).accessibilityIdentifier("syncPassword")
                                }
                            }
                            .textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye" : "eye.slash").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(showPassword ? L("Скрыть пароль") : L("Показать пароль"))
                        }
                    } header: {
                        Text(L("Хранилище Mac"))
                    } footer: {
                        if let message {
                            Text(message).foregroundStyle(Color(.systemRed)).accessibilityIdentifier("syncMessage")
                        } else {
                            Text(L("Мастер-пароль — тот же, что у хранилища Lumen на Mac. Он нужен один раз, дальше — Face ID."))
                        }
                    }
                    Section {
                        Button(working ? L("Проверяем…") : L("Подключить")) { connect(vaultID) }
                            .fontWeight(.semibold)
                            .disabled(working || password.isEmpty)
                            .accessibilityIdentifier("syncConnect")
                    }
                case .connected:
                    Section {
                        HStack(spacing: 8) {
                            Text(L("Хранилище"))
                            Spacer(minLength: 8)
                            StatusLight(light: .working)
                            Text(L("Подключено")).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L("Хранилище подключено"))
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityIdentifier("syncConnected")
                        if lastRun > 0 {
                            FactRow(title: L("Синхронизировали"),
                                    value: Date(timeIntervalSince1970: lastRun).formatted(.relative(presentation: .named).locale(Localization.locale)))
                        }
                        FactRow(title: L("Сессии с Mac"), value: "\(model.sessions.filter { $0.syncedProfileID != nil }.count)")
                    } footer: {
                        if let syncResult {
                            Text(syncResult).accessibilityIdentifier("syncResult")
                        } else {
                            Text(L("Профили с Mac появляются в списке сессий с пометкой «С Mac». Имя, описание и метки, изменённые на iPhone, уходят на Mac."))
                        }
                    }
                    Section {
                        Button { syncNow() } label: {
                            HStack(spacing: 10) {
                                Text(syncing ? L("Синхронизация…") : L("Синхронизировать")).fontWeight(.semibold)
                                if syncing { ProgressView() }
                            }
                        }
                        .disabled(syncing)
                        .accessibilityIdentifier("syncNow")
                    }
                    Section {
                        Button(L("Забыть хранилище"), role: .destructive) { confirmForget = true }
                            .accessibilityIdentifier("syncForget")
                    } footer: {
                        Text(L("Забыть — значит отключить этот iPhone от хранилища. Сессии на Mac останутся."))
                    }
                case let .failed(text):
                    Section {
                        Text(text).foregroundStyle(Color(.systemRed)).accessibilityIdentifier("syncFailed")
                    }
                }
            }
            .navigationTitle(L("Синхронизация"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() }.accessibilityIdentifier("syncDone") }
            }
            .confirmationDialog(L("Забыть хранилище на этом iPhone?"), isPresented: $confirmForget, titleVisibility: .visible) {
                Button(L("Забыть хранилище"), role: .destructive) {
                    SyncKeychain.erase()
                    lastRun = 0
                    Task { await load() }
                }
                .accessibilityIdentifier("confirmSyncForget")
                Button(L("Отмена"), role: .cancel) {}
            } message: {
                Text(L("Ключ хранилища удалится с iPhone. Сессии с Mac останутся в списке; чтобы синхронизировать снова, понадобится мастер-пароль."))
            }
            .task { await load() }
        }
        .presentationDetents([.large])
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

    /// One run: the Mac's profiles read and made sessions here. The kept key is read behind Face ID or
    /// the passcode; a key that no longer opens the vault (the master password changed on the Mac) is
    /// forgotten, and the password asked again.
    private func syncNow() {
        guard let record = AccountStore.record() else { return }
        guard let kept = SyncKeychain.read(reason: L("Синхронизация с Mac")) else { return }
        syncing = true
        syncResult = nil
        let token = record.deviceToken
        Task {
            defer { syncing = false }
            let transport = LumenSyncTransport(vaultID: kept.vaultID) { method, path, body, headers in
                try await AccountClient.sync(method, path, body, headers, token: token)
            }
            // The Mac's rule: a profile's cookies change while it does not run. The sessions made from
            // the vault are closed first (left, if one is on the screen behind this one).
            let synced = model.sessions.filter { $0.syncedProfileID != nil }
            if model.path.contains(where: { id in synced.contains { $0.id == id } }) { model.path = [] }
            synced.forEach { SessionRuntimes.shared.close($0.id) }
            switch await SyncRead.run(root: SyncKeychain.vaultFolder, key: kept.unlockKey, transport: transport,
                                      keptGeneration: SyncKeychain.generation, edits: model.catalog.localEdits(),
                                      cookies: CookieBridge(sessions: synced)) {
            case let .success(outcome):
                SyncKeychain.generation = outcome.generation
                SyncKeychain.profileTokens = outcome.profileTokens
                let made = model.applySynced(outcome.profiles)
                lastRun = Date().timeIntervalSince1970
                syncResult = L("Профилей с Mac: %@, новых: %@", "\(outcome.profiles.count)", "\(made)")
                    + (outcome.cookiesSet + outcome.cookiesDeleted > 0 ? "\n" + L("Куки обновлены: %@", "\(outcome.cookiesSet + outcome.cookiesDeleted)") : "")
            case .failure(.notInPlan):
                stage = .notInPlan
            case .failure(.keyNoLongerOpens):
                SyncKeychain.erase()
                await load()
                message = L("Мастер-пароль изменился на Mac. Введите новый.")
            case .failure(.generationChanged):
                syncResult = L("Данные синхронизации на сервере изменились. Синхронизируйте ещё раз.")
            case .failure(.newerApp):
                syncResult = AccountText.outdated
            case let .failure(.other(text)):
                NSLog("Lumen: the sync's run failed: %@", text)
                syncResult = AccountText.unreachable
            }
        }
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
