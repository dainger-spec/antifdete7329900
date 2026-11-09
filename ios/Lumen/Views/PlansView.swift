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

    var body: some View {
        NavigationStack {
            List {
                if let because {
                    Section { Text(because).accessibilityIdentifier("plansBecause") }
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
