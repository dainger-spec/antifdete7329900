import LumenCore
import SwiftUI
import WebKit

/// The plan (the owner, 8 November): which one, how many profiles of how many, what the plans give.
/// A plan is chosen and paid for on the site, in Safari — never inside the app. What the plans give
/// comes from Access, the one place rights come from; the paid plans' counts and prices come with the
/// account server, so they are not written here.
struct PlansView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// Why the plans opened, when the person tried what the plan does not allow.
    var because: String?
    #if DEBUG
    /// The planted fault's page (upgradeOpensInApp): the site inside the app.
    @State private var inApp: URL?
    #endif
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
                Section("Ваш тариф") {
                    Text(model.access.planTitle).font(.headline).accessibilityIdentifier("planName")
                    Text(model.access.profileCounter(model.sessions.count)).accessibilityIdentifier("profileCounter")
                    Text(model.access.proxies ? "Прокси: есть" : "Прокси: нет").accessibilityIdentifier("planProxies")
                }
                Section {
                    PlanRow(title: "Бесплатный",
                            text: "\(Access.freeProfiles) профиля без прокси. Изоляция и профиль устройства — полностью, как на любом тарифе.")
                    PlanRow(title: "Личный, Профессиональный, Команда",
                            text: "Прокси в каждом профиле. Профили общие с Lumen для Mac; iPhone не занимает место устройства.")
                } header: {
                    Text("Тарифы")
                } footer: {
                    Text("Число профилей и цены — на сайте Lumen.")
                }
                Section {
                    Button("Выбрать тариф на сайте") { openPricing() }
                        .accessibilityIdentifier("upgrade")
                } footer: {
                    Text("Сайт откроется в Safari.")
                }
            }
            .navigationTitle("Тариф")
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
            #if DEBUG
            .sheet(isPresented: Binding(get: { inApp != nil }, set: { if !$0 { inApp = nil } })) {
                if let inApp { InAppPage(url: inApp) }
            }
            #endif
        }
    }

    private func openPricing() {
        #if DEBUG
        if Faults.isActive(.upgradeOpensInApp) {   // the planted fault: the site inside the app
            inApp = AccessSource.pricingURL
            return
        }
        #endif
        openURL(AccessSource.pricingURL)
    }
}

private struct PlanRow: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.bold())
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// The planted fault's page: a web view of the app's own.
private struct InAppPage: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
