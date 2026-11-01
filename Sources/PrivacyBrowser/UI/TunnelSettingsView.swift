import AppKit
import SwiftUI

/// The network extension that carries proxied profiles' WebRTC through their SOCKS5 proxies:
/// its state, the Enable button (system prompts), where to allow it in System Settings, and what
/// happens while it is off.
struct TunnelSettingsView: View {
    /// Shown as a section of Settings: the page alone, without the sheet's title and Done.
    var embedded = false
    @ObservedObject private var tunnel = TunnelManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if embedded {
            SettingsPage(title: L("settings.section.webRTC"), subtitle: L("settings.webRTC.subtitle")) {
                rows
            }
            .onAppear { tunnel.refresh() }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: L("tunnel.title"), subtitle: L("settings.webRTC.subtitle"))
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
            .sheetFrame(width: 600, height: 620)
            .background(Theme.raised)
            .onAppear { tunnel.refresh() }
        }
    }

    /// The design's page: the state, with what can be done about it, then how it works and its
    /// limits. The same buttons as ever — the extension itself is not touched here.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCaption(L("tunnel.status"))
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
                if !tunnel.canCarryWebRTC {
                    Text(L("tunnel.warning.off"))
                        .font(.lumenBody)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 17)
                }
                if tunnel.state != .notBuilt {
                    HStack(spacing: 8) {
                        Button(L("tunnel.enable")) { tunnel.enable() }
                            .buttonStyle(.lumenSecondary)
                            .disabled(tunnel.state == .checking || tunnel.canCarryWebRTC)
                        Button(L("tunnel.openSettings")) { tunnel.openSystemSettings() }
                            .buttonStyle(.lumenGhost)
                        Button(L("tunnel.refresh")) { tunnel.refresh() }
                            .buttonStyle(.lumenGhost)
                    }
                    .padding(.leading, 17)
                    .padding(.top, 4)
                    Text(L("tunnel.instructions"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 17)
                        .padding(.top, 2)
                } else {
                    Text(L("tunnel.notBuilt.note"))
                        .font(.lumenSecondary)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 17)
                }
            }
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
            .accessibilityElement(children: .contain)

            SettingsCaption(L("settings.webRTC.how"))
            SettingRow(L("tunnel.relay.title"), detail: L("tunnel.intro"), effect: nil) { EmptyView() }
            SettingRow(L("tunnel.limits.title"), detail: L("tunnel.limits"), effect: nil) { EmptyView() }
        }
    }

    private var statusText: String {
        switch tunnel.state {
        case .notBuilt: return L("tunnel.state.notBuilt")
        case .checking: return L("tunnel.state.checking")
        case .off: return L("tunnel.state.off")
        case .awaitingApproval: return L("tunnel.state.awaitingApproval")
        case .needsConfiguration: return L("tunnel.state.needsConfiguration")
        case .ready: return L("tunnel.state.ready")
        case .connected: return L("tunnel.state.connected")
        case let .failed(reason): return String(format: L("tunnel.state.failed"), reason)
        }
    }

    /// The state's dot (the design's): green when WebRTC can go through the proxies, amber while it
    /// cannot (it is then off in proxied profiles), red on an error; the words beside it say which.
    private var dotColor: Color {
        switch tunnel.state {
        case .ready, .connected: return Theme.running
        case .failed: return Theme.danger
        case .checking: return Theme.textTertiary
        case .notBuilt, .off, .awaitingApproval, .needsConfiguration: return Theme.warning
        }
    }
}
