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
            Text(L("tunnel.title")).font(.title3.bold()).padding([.top, .horizontal], 20)
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
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text(L("tunnel.limits")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.grouped)
        }
        .frame(width: 560)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(L("common.done")) { dismiss() } }
        }
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
        case .ready, .connected: return .green
        case .failed: return .red
        case .awaitingApproval, .needsConfiguration: return .orange
        default: return .secondary
        }
    }
}
