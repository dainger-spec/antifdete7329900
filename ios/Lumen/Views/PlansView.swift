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
                    Section {
                        Label { Text(because).accessibilityIdentifier("plansBecause") } icon: { Image(systemName: "exclamationmark.triangle") }
                            .font(.system(size: 15)).foregroundStyle(Theme.warn)
                    }
                    .listRowBackground(Theme.warn.opacity(0.1))
                }
                // The account: who is signed in on this iPhone, or the way in. (A test that fixed the
                // rights has no account to show.)
                if model.fixedAccess == nil {
                    Section {
                        if let account = model.account {
                            HStack(spacing: 12) {
                                InitialBadge(name: account.email, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.email).foregroundStyle(Theme.text).accessibilityIdentifier("accountEmail")
                                    if !account.code.isEmpty {
                                        Text(L("Код этого iPhone в кабинете: %@", "\(account.code)")).font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                                            .accessibilityIdentifier("deviceCode")
                                    }
                                }
                            }
                            Button(refreshing ? L("Обновляем…") : L("Обновить статус")) {
                                refreshing = true
                                Task {
                                    await model.refreshAccount()
                                    refreshing = false
                                }
                            }
                            .disabled(refreshing)
                            .accessibilityIdentifier("refreshAccount")
                            Button(L("Выйти"), role: .destructive) { confirmSignOut = true }
                                .accessibilityIdentifier("signOut")
                        } else {
                            HStack(spacing: 12) {
                                Image(systemName: "person").font(.system(size: 15)).foregroundStyle(Theme.secondary)
                                    .frame(width: 36, height: 36).background(Color.white.opacity(0.05), in: Circle())
                                    .accessibilityHidden(true)
                                Text(L("Вход не выполнен")).foregroundStyle(Theme.secondary).accessibilityIdentifier("signedOut")
                            }
                            Button(L("Войти")) { signingIn = true }.fontWeight(.semibold).accessibilityIdentifier("signIn")
                        }
                        if let message = model.accountMessage {
                            Text(message).font(.subheadline).foregroundStyle(Theme.warn).accessibilityIdentifier("accountNotice")
                        }
                    } header: {
                        Text(L("Аккаунт"))
                    } footer: {
                        Text(L("Аккаунт Lumen — тот же, что в Lumen для Mac."))
                    }
                    .glassRow()
                }
                // What this iPhone may do: the plan's name when one is paid for, how many profiles of
                // how many — the bar turns amber when there is no room left — and the proxies.
                Section(L("На этом iPhone")) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let plan = model.access.paidPlanTitle {
                            Text(L("Тариф: %@", "\(plan)")).font(.system(size: 21, weight: .bold)).foregroundStyle(Theme.text)
                                .accessibilityIdentifier("planName")
                        }
                        if let most = model.access.maxProfiles, most > 0 {
                            Meter(part: Double(model.sessions.count) / Double(most), full: model.sessions.count >= most)
                        }
                        HStack {
                            Text(model.access.profileCounter(model.sessions.count)).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                                .accessibilityIdentifier("profileCounter")
                            Spacer()
                            Text(model.access.proxies ? L("Прокси: есть") : L("Прокси: нет")).font(.system(size: 14))
                                .foregroundStyle(model.access.proxies ? Theme.ok : Theme.tertiary)
                                .accessibilityIdentifier("planProxies")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .glassRow()
            }
            .eclipseSheet()
            .navigationTitle(L("Аккаунт"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Готово")) { dismiss() }.accessibilityIdentifier("plansDone") }
            }
            .sheet(isPresented: $signingIn) { SignInView() }
            .confirmationDialog(L("Выйти из аккаунта на этом iPhone?"), isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button(L("Выйти"), role: .destructive) { Task { await model.signOut() } }
                    .accessibilityIdentifier("confirmSignOut")
                Button(L("Отмена"), role: .cancel) {}
            } message: {
                Text(L("Этот iPhone отключится от аккаунта. Профили останутся здесь; прокси будут недоступны, пока вы не войдёте снова."))
            }
        }
    }
}
