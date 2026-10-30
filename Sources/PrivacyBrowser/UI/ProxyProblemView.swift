import BrowserCore
import SwiftUI

/// What the Profiles window says when a profile was started with a proxy that does not work
/// (`AppModel.proxyProblems`): which profile, which proxy, what the probe found — step by step,
/// in words, with what to do — and Check, the full check the Proxies sheet runs. The profile
/// itself loads nothing meanwhile: it never goes around its proxy. Several are said one after
/// the other.
struct ProxyProblemView: View {
    /// Shows a proxy of the list in the Proxies sheet (in place of this one).
    let showInList: (UUID) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let model = self.model
        if let problem = model.proxyProblems.first {
            ProxyProblemPanel(problem: problem, more: model.proxyProblems.count - 1,
                              check: { await model.checkProxy(of: problem) },
                              close: {
                                  model.dismissProxyProblem(problem)
                                  if model.proxyProblems.isEmpty { dismiss() }
                              },
                              showInList: {
                                  guard let id = model.proxyEntryID(of: problem) else { return }
                                  model.dismissProxyProblem(problem)
                                  showInList(id)
                              })
                .id(problem.id)
        } else {
            // Nothing left to say (the vault was locked meanwhile).
            Color.clear.frame(width: 1, height: 1).onAppear { dismiss() }
        }
    }
}

/// The sheet's body for one problem (rendered with a sample by `--render-ui-snapshots`).
struct ProxyProblemPanel: View {
    let problem: ProxyProblem
    /// How many more profiles wait to be told about.
    var more = 0
    let check: () async -> ProxyCheckResult?
    let close: () -> Void
    let showInList: () -> Void

    @State private var checking = false
    @State private var result: ProxyCheckResult?

    /// The check's, once it ran; until then the probe's at the launch.
    private var report: ProxyReport {
        if let result { return ProxyReport(proxy: problem.proxy, check: result) }
        return ProxyReport(proxy: problem.proxy, diagnosis: problem.diagnosis)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(format: L(problem.notStarted ? "proxyProblem.title.notStarted" : "proxyProblem.title"),
                                      problem.profileName),
                        subtitle: String(format: L(problem.notStarted ? "proxyProblem.subtitle.notStarted" : "proxyProblem.subtitle"),
                                         problem.proxy.displayAddress))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if checking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("proxyProblem.checking"))
                                .font(.lumenSecondary)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else if let result, result.isAlive {
                        Label(L(problem.notStarted ? "proxyProblem.worksNow.notStarted" : "proxyProblem.worksNow"),
                              systemImage: "checkmark.circle.fill")
                            .font(.lumenLabel)
                            .foregroundStyle(Theme.running)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ProxyReportView(report: report, checkedAt: result?.checkedAt)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            SheetFooter(leading: {
                if more > 0 {
                    Text(String(format: L("proxyProblem.more"), more))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
            }, buttons: {
                Button(L("proxyProblem.showInList"), action: showInList)
                    .buttonStyle(.lumenGhost)
                    .disabled(checking)
                Button(L(more > 0 ? "proxyProblem.next" : "common.close"), action: close)
                    .buttonStyle(.lumenSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("proxyProblem.check"), action: runCheck)
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking)
            })
        }
        .frame(width: 580, height: 600)
        .background(Theme.raised)
    }

    private func runCheck() {
        guard !checking else { return }
        checking = true
        Task {
            let found = await check()
            checking = false
            if let found { result = found }
        }
    }
}
