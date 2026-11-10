import LumenCore
import SwiftUI

/// The account's screen: who is signed in on this iPhone, how many profiles it holds of how many, and
/// whether they may go through proxies. A plan is named only when it is paid for and running — it was
/// bought on the site, and nothing here offers one, names a price or leads to the site (the owner,
/// 10 November). Everything shown comes from Access, the one place rights come from.
struct PlansView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Why the plans opened, when the person tried what the plan does not allow.
    var because: String?
    @State private var signingIn = false
    @State private var confirmSignOut = false
    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            List {
                if let because {
                    Section { Text(because).accessibilityIdentifier("plansBecause") }
                }
                // The account: who is signed in on this iPhone, or the way in. (A test that fixed the
                // rights has no account to show.)
                if model.fixedAccess == nil {
                    Section("Аккаунт") {
                        if let account = model.account {
                            Text(account.email).accessibilityIdentifier("accountEmail")
                            if !account.code.isEmpty {
                                Text("Код этого iPhone в кабинете: \(account.code)").font(.subheadline).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("deviceCode")
                            }
                            Button(refreshing ? "Обновляем…" : "Обновить статус") {
                                refreshing = true
                                Task {
                                    await model.refreshAccount()
                                    refreshing = false
                                }
                            }
                            .disabled(refreshing)
                            .accessibilityIdentifier("refreshAccount")
                            Button("Выйти", role: .destructive) { confirmSignOut = true }
                                .accessibilityIdentifier("signOut")
                        } else {
                            Text("Вход не выполнен").accessibilityIdentifier("signedOut")
                            Button("Войти") { signingIn = true }.accessibilityIdentifier("signIn")
                        }
                        if let message = model.accountMessage {
                            Text(message).font(.subheadline).foregroundStyle(.orange).accessibilityIdentifier("accountNotice")
                        }
                    }
                }
                Section("На этом iPhone") {
                    if let plan = model.access.paidPlanTitle {
                        Text("Тариф: \(plan)").font(.headline).accessibilityIdentifier("planName")
                    }
                    Text(model.access.profileCounter(model.sessions.count)).accessibilityIdentifier("profileCounter")
                    Text(model.access.proxies ? "Прокси: есть" : "Прокси: нет").accessibilityIdentifier("planProxies")
                }
            }
            .navigationTitle("Аккаунт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() }.accessibilityIdentifier("plansDone") }
            }
            .sheet(isPresented: $signingIn) { SignInView() }
            .confirmationDialog("Выйти из аккаунта на этом iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { Task { await model.signOut() } }
                    .accessibilityIdentifier("confirmSignOut")
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Этот iPhone отключится от аккаунта. Профили останутся здесь; прокси будут недоступны, пока вы не войдёте снова.")
            }
        }
    }
}
