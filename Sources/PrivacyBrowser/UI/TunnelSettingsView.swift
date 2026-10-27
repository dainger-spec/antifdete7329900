import AppKit
import SwiftUI

/// The network extension that carries proxied profiles' WebRTC through their SOCKS5 proxies:
/// its state, the Enable button (system prompts), where to allow it in System Settings, and what
/// happens while it is off.
struct TunnelSettingsView: View {
    @ObservedObject private var tunnel = TunnelManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L("tunnel.title"))
            Form {
                Text(L("tunnel.intro")).fixedSize(horizontal: false, vertical: true)

                Section(L("tunnel.status")) {
                    Label(statusText, systemImage: statusSymbol).foregroundStyle(statusColor)
                    if tunnel.state != .notBuilt {
                        HStack {
                            Button(L("tunnel.enable")) { tunnel.enable() }
                                .disabled(tunnel.state == .checking || tunnel.canCarryWebRTC)
                            Button(L("tunnel.openSettings")) { tunnel.openSystemSettings() }
                            Button(L("tunnel.refresh")) { tunnel.refresh() }
                        }
                        Text(L("tunnel.instructions")).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L("tunnel.notBuilt.note")).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !tunnel.canCarryWebRTC {
                    Label(L("tunnel.warning.off"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
                Text(L("tunnel.limits")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .lumenForm()
            SheetFooter {
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.lumenPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 560)
        .background(Theme.raised)
        .onAppear { tunnel.refresh() }
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

    private var statusSymbol: String {
        switch tunnel.state {
        case .ready, .connected: return "checkmark.shield.fill"
        case .awaitingApproval, .needsConfiguration, .checking: return "hourglass"
        case .failed: return "xmark.octagon.fill"
        case .notBuilt, .off: return "shield.slash"
        }
    }

    private var statusColor: Color {
        switch tunnel.state {
        case .ready, .connected: return Theme.running
        case .failed: return Theme.danger
        case .awaitingApproval, .needsConfiguration: return Theme.warning
        default: return .secondary
        }
    }
}
