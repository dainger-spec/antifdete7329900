import LumenCore
import SwiftUI

/// The account's screen (p10-signed-out, p10-pro): who is signed in on this iPhone, the plan, how many
/// profiles it holds of how many, whether they may go through proxies. A plan is named only when it is
/// paid for and running — it was bought on the site, and nothing here offers one, names a price or
/// leads to the site (the owner, 10 November). Everything shown comes from Access, the one place
/// rights come from. Each state is a fact in a row and one line under it.
struct PlansView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Why the plans opened, when the person tried what the plan does not allow.
    var because: String?
    @State private var signingIn = false
    @State private var confirmSignOut = false
    @State private var refreshing = false
    @State private var syncing = false

    private var signedIn: Bool { model.account != nil }

    var body: some View {
        NavigationStack {
            List {
                if let because {
                    Section { NoticeRow(text: because, identifier: "plansBecause") }
                }
                // The account: who is signed in on this iPhone, or the way in. (A test that fixed the
                // rights has no account to show.)
                if model.fixedAccess == nil {
                    Section {
                        if let account = model.account {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.email).accessibilityIdentifier("accountEmail")
                                if !account.code.isEmpty {
                                    Text(L("Код этого iPhone в кабинете: %@", "\(account.code)")).font(.subheadline).foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .accessibilityIdentifier("deviceCode")
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("Вход не выполнен")).accessibilityIdentifier("signedOut")
                                Text(L("Войдите, чтобы включить свой тариф.")).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Button(L("Войти")) { signingIn = true }.accessibilityIdentifier("signIn")
                        }
                    }
                    if let message = model.accountMessage {
                        Section { NoticeRow(text: message, identifier: "accountNotice") }
                    }
                }
                Section {
                    if let plan = model.access.paidPlanTitle {
                        FactRow(title: L("Тариф"), value: plan, identifier: "planName")
                    }
                    if let end = paidUntil {
                        FactRow(title: L("Оплачен до"), value: end.text,
                                valueStyle: end.ending ? AnyShapeStyle(Color(.systemOrange)) : AnyShapeStyle(.secondary))
                    }
                    profilesRow
                    FactRow(title: L("Прокси"), value: model.access.proxies ? L("есть") : L("нет"), identifier: "planProxies")
                } header: {
                    Text(signedIn && model.access.paidPlanTitle != nil ? L("Тариф") : L("На этом iPhone"))
                } footer: {
                    if !signedIn, model.fixedAccess == nil { Text(L("Аккаунт Lumen — тот же, что в Lumen для Mac.")) }
                }
                if signedIn {
                    Section {
                        Button { syncing = true } label: {
                            HStack(spacing: 8) {
                                Text(L("Синхронизация")).foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                if SyncKeychain.vaultID != nil {
                                    StatusLight(light: .working)
                                    Text(L("Подключено")).foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("syncButton")
                    }
                    Section {
                        Button(refreshing ? L("Обновляем…") : L("Обновить статус")) {
                            refreshing = true
                            Task {
                                await model.refreshAccount()
                                refreshing = false
                            }
                        }
                        .disabled(refreshing)
                        .accessibilityIdentifier("refreshAccount")
                    }
                    Section {
                        Button(L("Выйти"), role: .destructive) { confirmSignOut = true }
                            .accessibilityIdentifier("signOut")
                    } footer: {
                        Text(L("Аккаунт Lumen — тот же, что в Lumen для Mac."))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L("Аккаунт"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() }.accessibilityIdentifier("plansDone") }
            }
            .sheet(isPresented: $signingIn) { SignInView() }
            .sheet(isPresented: $syncing) { SyncView() }
            .confirmationDialog(L("Выйти из аккаунта на этом iPhone?"), isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button(L("Выйти"), role: .destructive) { Task { await model.signOut() } }
                    .accessibilityIdentifier("confirmSignOut")
                Button(L("Отмена"), role: .cancel) {}
            } message: {
                Text(L("Этот iPhone отключится от аккаунта. Профили останутся здесь; прокси будут недоступны, пока вы не войдёте снова."))
            }
        }
    }

    /// How many profiles of how many — a neutral line under it, full when there is no room left.
    private var profilesRow: some View {
        let count = model.sessions.count
        let most = model.access.maxProfiles
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Профили"))
                Spacer(minLength: 12)
                Text(most.map { L("%@ из %@", "\(count)", "\($0)") } ?? "\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            if let most, most > 0 {
                ProgressView(value: min(1, Double(count) / Double(most))).tint(Theme.progress)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.access.profileCounter(count))
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("profileCounter")
    }

    /// The paid period's end, when a paid plan runs: "19 ноября" — orange in its last week.
    private var paidUntil: (text: String, ending: Bool)? {
        guard model.access.paidPlanTitle != nil, let end = model.entitlement?.periodEndsAt else { return nil }
        let text = end.formatted(Date.FormatStyle().day().month(.wide).locale(Localization.locale))
        return (text, AccountNotices.periodEnding(model.entitlement, now: Date()) != nil)
    }
}
