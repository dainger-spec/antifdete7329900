import AppKit
import BrowserCore
import SwiftUI

/// The network guard (`NetworkGuard`, docs/TUNNEL.md): where it stands, what the person can do
/// about it, and how WebRTC goes through a proxy with it. Installing it starts here, and only here
/// or where a profile points here: never by itself at the app's start. Before macOS asks anything,
/// the page says what it will ask and why (`explaining`), once per press of Install.
struct NetworkGuardSettingsView: View {
    /// Shown as a section of Settings: the page alone, without the sheet's title and Done.
    var embedded = false
    @ObservedObject private var networkGuard = NetworkGuard.shared
    @Environment(\.dismiss) private var dismiss
    @State private var explaining = false

    var body: some View {
        Group {
            if embedded {
                SettingsPage(title: L("settings.section.webRTC"), subtitle: L("settings.webRTC.subtitle")) {
                    rows
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(title: L("guard.title"), subtitle: L("settings.webRTC.subtitle"))
                    ScrollView {
                        rows
                            .padding(.horizontal, 24)
                            .padding(.bottom, 18)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    SheetFooter {
                        Button(L("common.done")) { dismiss() }
                            .buttonStyle(.lumenPrimary)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .sheetFrame(width: 600, height: 640)
                .background(Theme.raised)
            }
        }
        .onAppear { networkGuard.refresh() }
        // What macOS is about to ask, and why, before its own windows: the extension (an
        // administrator's approval in System Settings), then the content filter's configuration.
        .alert(L("guard.explain.title"), isPresented: $explaining) {
            Button(L("guard.explain.continue")) { networkGuard.install() }
            Button(L("guard.explain.notNow"), role: .cancel) {}
        } message: {
            Text(L("guard.explain.message"))
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCaption(L("guard.status"))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(statusText)
                        .font(.lumenRowTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail {
                    Text(detail)
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 17)
                }
                if networkGuard.installedState != .notInBuild {
                    HStack(spacing: 8) {
                        if let action = primaryAction {
                            Button(action.title, action: action.run)
                                .buttonStyle(.lumenSecondary)
                                .disabled(networkGuard.checking)
                        }
                        Button(L("guard.openSettings")) { networkGuard.openSystemSettings() }
                            .buttonStyle(.lumenGhost)
                        Button(L("guard.refresh")) { networkGuard.refresh() }
                            .buttonStyle(.lumenGhost)
                            .disabled(networkGuard.checking)
                    }
                    .padding(.leading, 17)
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
            .accessibilityElement(children: .contain)

            SettingsCaption(L("settings.webRTC.how"))
            SettingRow(L("guard.how.relay.title"), detail: L("guard.how.relay"), effect: nil) { EmptyView() }
            SettingRow(L("guard.how.guard.title"), detail: L("guard.how.guard"), effect: nil) { EmptyView() }
            SettingRow(L("guard.how.limits.title"), detail: L("guard.how.limits"), effect: nil) { EmptyView() }
        }
    }

    /// The one thing the person can press to move on, where there is one.
    private var primaryAction: (title: String, run: () -> Void)? {
        switch networkGuard.installedState {
        case .notInstalled: return (L("guard.install"), { explaining = true })
        case .off: return (L("guard.enable"), { networkGuard.install() })
        case .notInBuild, .awaitingApproval, .notAnswering, .unproven, .ready: return nil
        }
    }

    private var statusText: String {
        if networkGuard.checking { return L("guard.state.checking") }
        if networkGuard.problem == .reboot { return L("guard.state.reboot") }
        switch networkGuard.installedState {
        case .notInBuild:
            return BuildKind.madeForRelease ? L("guard.state.notInBuild.release") : L("guard.state.notInBuild.development")
        case .notInstalled: return L("guard.state.notInstalled")
        case .awaitingApproval: return L("guard.state.awaitingApproval")
        case .off: return L("guard.state.off")
        case .notAnswering: return L("guard.state.notAnswering")
        case .unproven: return L("guard.state.unproven")
        case .ready: return L("guard.state.ready")
        }
    }

    /// What it means and what to do: a problem the last attempt met comes first.
    private var detail: String? {
        if !networkGuard.checking, let problem = networkGuard.problem {
            switch problem {
            case .reboot: return L("guard.problem.reboot")
            case .location: return L("guard.problem.location")
            case .signing: return L("guard.problem.signing")
            case .authorization: return L("guard.problem.authorization")
            case .policy: return L("guard.problem.policy")
            case .declined: return L("guard.problem.declined")
            case let .other(reason): return String(format: L("guard.problem.other"), reason)
            }
        }
        switch networkGuard.installedState {
        case .notInBuild: return BuildKind.madeForRelease ? L("guard.notInBuild.release") : L("guard.notInBuild.development")
        case .notInstalled: return L("guard.todo.notInstalled")
        case .awaitingApproval: return L("guard.todo.awaitingApproval")
        case .off: return L("guard.todo.off")
        case .notAnswering: return L("guard.todo.notAnswering")
        case .unproven: return L("guard.todo.unproven")
        case .ready: return nil
        }
    }

    /// Green when WebRTC can go through the proxies, amber while it cannot (it is then off in
    /// proxied profiles), red when the last attempt failed; the words beside it say which.
    private var dotColor: Color {
        if networkGuard.checking { return Theme.textTertiary }
        if let problem = networkGuard.problem { return problem == .reboot ? Theme.warning : Theme.danger }
        return networkGuard.installedState == .ready ? Theme.running : Theme.warning
    }
}
